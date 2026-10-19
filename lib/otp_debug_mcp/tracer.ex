defmodule OtpDebugMcp.Tracer do
  @moduledoc """
  Safe tracing on the target node via recon_trace.

  recon_trace is the right foundation for AI-driven tracing because it is
  rate-limited by construction: it stops after N messages or when its internal
  queue backs up, so an over-eager agent can't melt a production node the way
  raw `dbg`/`erlang:trace` can. We add a hard wall-clock timeout on top.

  recon_trace links its tracer to the calling process and stops when that
  process exits, so the trace can't be started from a plain rpc call (the rpc
  worker exits immediately). Instead we spawn a holder process on the target,
  using only erl_eval so no code of ours has to exist there. It starts the
  trace, keeps it alive for the window, then clears it.

  Formatted trace lines are written to an io server on our node (the
  collector), which counts them so we can return as soon as `max_events`
  lines have arrived.
  """

  alias OtpDebugMcp.Target

  # The holder's group leader is set to the collector first, so recon_trace's
  # own messages (e.g. "rate limit tripped") land in the results instead of
  # being forwarded to our stdout, which is the MCP protocol stream.
  @holder """
  group_leader(Collector, self()),
  recon_trace:calls(Spec, Max, Opts),
  receive stop -> ok after Duration -> ok end,
  recon_trace:clear().
  """

  @spec trace(String.t(), String.t() | nil, pos_integer(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def trace(module_str, function_str, max_events, duration_ms) do
    mod = resolve_module(module_str)
    fun = if function_str, do: String.to_atom(function_str), else: :_

    with {:ok, true} <- Target.rpc(:code, :is_loaded, [mod]) |> loaded?(module_str),
         target when not is_nil(target) <- Target.target_node() || {:error, :not_connected} do
      owner = self()
      collector = spawn(fn -> collector_loop(owner, max_events, []) end)

      # A list of bindings is an orddict to erl_eval, so it must be sorted.
      bindings =
        Enum.sort(
          Spec: {mod, fun, [{:_, [], [{:return_trace}]}]},
          Max: max_events,
          Opts: [scope: :local, io_server: collector],
          Duration: duration_ms,
          Collector: collector
        )

      holder =
        Target.with_stderr_group_leader(fn ->
          Node.spawn(target, :erl_eval, :exprs, [parse!(@holder), bindings])
        end)

      events = await_events(collector, duration_ms)
      send(holder, :stop)
      {:ok, events}
    end
  end

  defp loaded?({:ok, {:file, _}}, _), do: {:ok, true}
  defp loaded?({:ok, false}, m), do: {:error, {:module_not_loaded_on_target, m}}
  defp loaded?(err, _), do: err

  defp parse!(code) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(code))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    exprs
  end

  # Modules arrive as "Elixir.MyApp.Worker", "MyApp.Worker" (Elixir) or "ets" (Erlang).
  defp resolve_module("Elixir." <> _ = m), do: String.to_atom(m)

  defp resolve_module(m) do
    if m =~ ~r/^[A-Z]/, do: Module.concat([m]), else: String.to_atom(m)
  end

  defp await_events(collector, duration_ms) do
    receive do
      {:events, ^collector, events} -> events
    after
      duration_ms ->
        send(collector, :drain)

        receive do
          {:events, ^collector, events} -> events
        after
          1_000 -> []
        end
    end
  end

  # An io server: recon_trace on the target writes formatted trace lines to
  # it across the distribution link. Replies to the owner with all lines once
  # max_events have arrived, or when asked to drain at the deadline.
  defp collector_loop(owner, max, acc) do
    receive do
      {:io_request, from, reply_as, request} ->
        send(from, {:io_reply, reply_as, :ok})

        case chars(request) do
          nil ->
            collector_loop(owner, max, acc)

          line when length(acc) + 1 >= max ->
            send(owner, {:events, self(), Enum.reverse([line | acc])})
            discard_loop()

          line ->
            collector_loop(owner, max, [line | acc])
        end

      :drain ->
        send(owner, {:events, self(), Enum.reverse(acc)})
        discard_loop()
    after
      120_000 -> :ok
    end
  end

  # Once results are delivered, keep acknowledging writes until the trace is
  # gone: recon_trace's formatter crashes on the *target* (polluting its
  # logs) if its io server disappears before its final messages.
  defp discard_loop do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        discard_loop()
    after
      5_000 -> :ok
    end
  end

  # Trace lines include full arguments, so a GenServer callback prints the
  # whole state on every event; cap each line to keep tool results usable.
  @max_line 600

  defp chars({:put_chars, _enc, chars}), do: chars |> IO.chardata_to_string() |> truncate()

  defp chars({:put_chars, _enc, m, f, a}),
    do: apply(m, f, a) |> IO.chardata_to_string() |> truncate()

  defp chars(_other), do: nil

  defp truncate(line) do
    line = String.trim(line)

    if String.length(line) > @max_line do
      String.slice(line, 0, @max_line) <> " …(truncated)"
    else
      line
    end
  end
end
