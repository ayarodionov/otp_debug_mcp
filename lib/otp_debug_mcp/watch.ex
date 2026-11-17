defmodule OtpDebugMcp.Watch do
  @moduledoc """
  Watch mode: wait until the flight recorder's samples show a problem that
  wasn't there when watching began.

  A problem is what `Recorder.problems/2` finds in the samples since then
  (a series rising or falling past its threshold, a mailbox past 1,000, a
  process's or a table's memory growing), still so in the latest sample.
  The first wait on a recorder takes what is wrong already as known, and
  says so; each problem is reported once. The state, per node, is kept
  here between calls, so each call can wait a short while and the next
  carries on: an MCP call has to finish within the server's request
  timeout.
  """

  use Agent

  alias OtpDebugMcp.{Recorder, Target}

  @poll_ms 2_000

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc """
  Wait up to `wait_ms` for a new problem. With `restart`, what is wrong
  now becomes the new starting point. Returns `{:ok, result}`, `:none`
  when no recorder runs, or an error.
  """
  def wait(wait_ms, restart \\ false) do
    node = Target.connected_node()
    deadline = System.monotonic_time(:millisecond) + wait_ms
    state = if restart, do: nil, else: Agent.get(__MODULE__, &Map.get(&1, node))

    with {:ok, report} <- Recorder.read_since(if(state, do: state.last_at, else: 0)) do
      {state, present} =
        cond do
          state == nil -> baseline(report)
          state.started != report.started -> baseline_fresh(report)
          true -> {add(state, report), nil}
        end

      loop(node, state, report, present, deadline)
    end
  catch
    other -> other
  end

  # A recorder seen for the first time, or again after restart: all its
  # samples are read, and what they show is known.
  defp baseline_fresh(_report) do
    case Recorder.read(false) do
      {:ok, report} -> baseline(report)
      other -> throw(other)
    end
  end

  defp baseline(report) do
    samples = valid(report.samples)
    found = if length(samples) >= 2, do: Recorder.problems(samples, report.read_at), else: []
    last = List.last(samples)

    state = %{
      started: report.started,
      since: if(last, do: last.at, else: report.read_at),
      known: MapSet.new(found, & &1.key),
      # The trends since watching began start from the latest sample.
      samples: if(last, do: [last], else: []),
      last_at: if(last, do: last.at, else: 0),
      keep: report.keep
    }

    {state, for(p <- found, p.ongoing, do: p.text)}
  end

  defp add(state, report) do
    new = valid(report.samples)

    case new do
      [] ->
        state

      _ ->
        %{
          state
          | samples: Enum.take(state.samples ++ new, -state.keep),
            last_at: List.last(new).at
        }
    end
  end

  defp loop(node, state, report, present, deadline) do
    found =
      if length(state.samples) >= 2,
        do:
          state.samples
          |> Recorder.problems(report.read_at)
          |> Enum.filter(&(&1.ongoing and not MapSet.member?(state.known, &1.key))),
        else: []

    cond do
      found != [] ->
        state = %{state | known: MapSet.union(state.known, MapSet.new(found, & &1.key))}
        save(node, state)
        {:ok, result(:found, state, report, present, Enum.map(found, & &1.text))}

      not report.recording ->
        save(node, state)
        {:ok, result(:stopped, state, report, present, [])}

      System.monotonic_time(:millisecond) + @poll_ms > deadline ->
        save(node, state)
        {:ok, result(:nothing, state, report, present, [])}

      true ->
        Process.sleep(@poll_ms)

        case Recorder.read_since(state.last_at) do
          {:ok, report} -> loop(node, add(state, report), report, present, deadline)
          other -> other
        end
    end
  catch
    other -> other
  end

  defp save(node, state), do: Agent.update(__MODULE__, &Map.put(&1, node, state))

  defp valid(samples), do: Enum.reject(samples, &Map.has_key?(&1, :error))

  defp result(outcome, state, report, present, texts) do
    now = report.read_at

    %{
      new_problems: texts,
      watching_since: Recorder.time(state.since, now),
      latest_sample: if(state.last_at > 0, do: Recorder.time(state.last_at, now)),
      samples_since: max(length(state.samples) - 1, 0)
    }
    |> Map.merge(
      case outcome do
        :found ->
          %{
            hint:
              "history gives the whole recording around it. Calling wait_for_problem again " <>
                "keeps watching; these won't be reported again."
          }

        :nothing ->
          %{hint: "Nothing new yet. Call wait_for_problem again to keep waiting."}

        :stopped ->
          %{
            hint:
              "The recorder has stopped recording, so nothing new will come: record starts " <>
                "another (after record with stop: true)."
          }
      end
    )
    |> Map.merge(
      if present,
        do: %{
          already_present: present,
          note:
            "Watching starts now: these were already wrong, and aren't reported as new. " <>
              "history says when they began."
        },
        else: %{}
    )
  end
end
