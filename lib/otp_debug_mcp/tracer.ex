defmodule OtpDebugMcp.Tracer do
  @moduledoc """
  Safe tracing on the target node via recon_trace.

  recon_trace is the right foundation for AI-driven tracing because it is
  rate-limited by construction: it stops after N messages or when its internal
  queue backs up, so an over-eager agent can't melt a production node the way
  raw `dbg`/`erlang:trace` can. We add a hard wall-clock timeout on top.

  Trace output goes to the target's group leader by default; here we collect
  it on our side by passing an io_server we own (see `collect/2`) — for the
  skeleton this is simplified to formatting via recon_trace's return and the
  remote shell's output. TODO: replace with a proper remote io relay.
  """

  alias OtpDebugMcp.Target

  @spec trace(String.t(), String.t() | nil, pos_integer(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def trace(module_str, function_str, max_events, duration_ms) do
    mod = resolve_module(module_str)
    fun = if function_str, do: String.to_atom(function_str), else: :_

    # {Mod, Fun, return_trace} — match all arities, capture return values.
    tspec = {mod, fun, [{:_, [], [{:return_trace}]}]}
    opts = [{:scope, :local}, {:io_server, io_collector()}]

    with {:ok, matched} <- Target.rpc(:recon_trace, :calls, [tspec, max_events, opts]),
         true <- matched > 0 || {:error, {:no_functions_matched, module_str}} do
      events = collect_events(max_events, duration_ms)
      Target.rpc(:recon_trace, :clear, [])
      {:ok, events}
    else
      err ->
        Target.rpc(:recon_trace, :clear, [])
        err
    end
  end

  # Modules arrive as "Elixir.MyApp.Worker", "MyApp.Worker" (Elixir) or "ets" (Erlang).
  defp resolve_module("Elixir." <> _ = m), do: String.to_atom(m)

  defp resolve_module(m) do
    if m =~ ~r/^[A-Z]/, do: Module.concat([m]), else: String.to_atom(m)
  end

  # A local process acting as an io server: recon_trace on the target writes
  # its formatted trace lines to it across the distribution link, and we
  # accumulate them for the tool response.
  defp io_collector do
    case Process.whereis(__MODULE__.Collector) do
      nil ->
        pid = spawn(fn -> collector_loop([]) end)
        Process.register(pid, __MODULE__.Collector)
        pid

      pid ->
        pid
    end
  end

  defp collector_loop(acc) do
    receive do
      {:io_request, from, reply_as, {:put_chars, _enc, chars}} ->
        send(from, {:io_reply, reply_as, :ok})
        collector_loop([IO.chardata_to_string(chars) | acc])

      {:io_request, from, reply_as, _other} ->
        send(from, {:io_reply, reply_as, :ok})
        collector_loop(acc)

      {:drain, from} ->
        send(from, {:events, Enum.reverse(acc)})
        collector_loop([])
    end
  end

  defp collect_events(_max_events, duration_ms) do
    # Simple strategy for the skeleton: wait out the window, then drain.
    # TODO: return early once max_events lines have arrived.
    Process.sleep(duration_ms)
    send(Process.whereis(__MODULE__.Collector), {:drain, self()})

    receive do
      {:events, events} -> events
    after
      1_000 -> []
    end
  end
end
