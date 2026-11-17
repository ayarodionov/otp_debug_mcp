defmodule OtpDebugMcp.Capabilities do
  @moduledoc """
  What the tools can do, by situation: one text for `--help` (rendered
  into the release's env.sh when it's built) and for the `help` prompt.
  """

  @situations [
    {"Slow, stuck or timing out",
     "diagnose (mailboxes that can't keep up, deadlocks, CPU), call_latency, hot_spots, " <>
       "profile, trace_calls"},
    {"Memory that grows",
     "diagnose (binaries, ETS, fragmentation, native memory), snapshot (take, then diff), " <>
       "ets_table"},
    {"Crashes and errors", "recent_errors, supervision_tree, trace_calls with exceptions"},
    {"A node that died", "crash_dump, from its erl_crash.dump; no connection needed"},
    {"What happened before you looked",
     "record (start it before), history, wait_for_problem (watch until it happens)"},
    {"Many nodes", "cluster (compare them, find the odd one out)"},
    {"Sockets and ports", "socket_tuning, port_info, trace_port"},
    {"The code as it runs", "module_code (macros expanded), benchmark"},
    {"Your stack",
     "phoenix, bandit, cowboy, ranch, yaws, postgrex, mnesia, rabbitmq, emqx, ejabberd, " <>
       "riak_core, shackle, telemetry"},
    {"Trying a fix", "load_module (asks you first; lasts until the node restarts)"}
  ]

  @doc "The situations and the tools for each."
  def situations, do: @situations

  @doc """
  The list as text: each situation, then its tools, wrapped to `columns`
  under the first, every line indented by `indent`.
  """
  def text(indent \\ "  ", columns \\ 80) do
    width = @situations |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()
    hang = String.length(indent) + width + 2

    Enum.map_join(@situations, "\n", fn {situation, tools} ->
      [first | rest] = wrap(tools, columns - hang)
      pad = String.duplicate(" ", hang)

      Enum.join(
        [
          indent <> String.pad_trailing(situation <> ":", width + 2) <> first
          | Enum.map(rest, &(pad <> &1))
        ],
        "\n"
      )
    end)
  end

  defp wrap(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | done] ->
        if String.length(line) + 1 + String.length(word) <= width,
          do: [line <> " " <> word | done],
          else: [word, line | done]
    end)
    |> Enum.reverse()
  end
end
