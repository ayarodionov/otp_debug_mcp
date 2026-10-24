defmodule OtpDebugMcp.Ports do
  @moduledoc """
  One port in detail, and port tracing.

  `info/1` is to a port what process_info is to a process: what it is (a
  socket, an external program, a driver), its owner, its I/O and queue,
  and for a socket its addresses, statistics and options.

  `trace/2` traces a port's traffic (what its owner sends it, what it
  sends back) or ports being opened and closed, rate-limited like
  `OtpDebugMcp.Tracer`. On OTP 27+ in a trace session of its own, so
  other tracing on the node is untouched; before, in the legacy trace
  session, refused while anyone else traces unless forced.
  """

  alias OtpDebugMcp.{Checks, Format, Target, Tracer}

  # A port as printed, #Port<0.42> (or without the #), parsed on the
  # target, where its numbers mean that port; or a registered name.
  @resolve ~S"""
  case Spec of
    "#Port<" ++ _ -> catch erlang:list_to_port(Spec);
    "Port<" ++ _ -> catch erlang:list_to_port("#" ++ Spec);
    "<" ++ _ -> catch erlang:list_to_port("#Port" ++ Spec);
    Name -> whereis(list_to_atom(Name))
  end.
  """

  @doc "The target's port that `spec` names: as printed, or a registered name."
  def resolve(spec) do
    case Checks.remote_eval(@resolve, Spec: String.to_charlist(String.trim(spec))) do
      {:ok, port} when is_port(port) -> {:ok, port}
      {:ok, _} -> {:error, "no port #{spec} on the target"}
      err -> err
    end
  end

  @info ~S"""
  case erlang:port_info(Port) of
    undefined -> closed;
    Info ->
      Name = proplists:get_value(name, Info),
      Owner = proplists:get_value(connected, Info),
      Extra = [{K, V} || K <- [queue_size, memory, parallelism], {_, V} <- [catch erlang:port_info(Port, K)]],
      Inet = lists:member(Name, ["tcp_inet", "udp_inet", "sctp_inet"]),
      Socket = case Inet of
        false -> [];
        true ->
          Opts = [active, mode, packet, header, recbuf, sndbuf, buffer, high_watermark, low_watermark,
                  nodelay, keepalive, send_timeout, delay_send, exit_on_close, reuseaddr],
          [{stats, catch inet:getstat(Port)}, {peer, catch inet:peername(Port)},
           {local, catch inet:sockname(Port)}, {options, catch inet:getopts(Port, Opts)}]
      end,
      OwnerInfo = case is_pid(Owner) of
        true -> {Initial(Owner), catch erlang:process_info(Owner, [registered_name, current_function, status, message_queue_len])};
        false -> undefined
      end,
      {Info ++ Extra, Socket, OwnerInfo}
  end.
  """

  @doc "Everything about one port, ready for the tool's JSON."
  def info(port) do
    case Checks.remote_eval(Checks.supervisor_funs() <> Checks.initial_call_fun() <> @info,
           Port: port
         ) do
      {:ok, :closed} ->
        {:error, "#{Format.inspect(port)} has closed"}

      {:ok, {info, socket, owner}} ->
        {:ok, describe(port, info, socket, owner)}

      err ->
        err
    end
  end

  defp describe(port, info, socket, owner) do
    name = to_string(info[:name])

    base = %{
      port: Format.inspect(port),
      kind:
        cond do
          socket != [] -> "socket"
          is_integer(info[:os_pid]) -> "external program"
          true -> "port driver"
        end,
      name: name,
      owner: Format.inspect(info[:connected]),
      links: Enum.map(info[:links] || [], &Format.inspect/1),
      input_bytes: info[:input],
      output_bytes: info[:output],
      queue_bytes: info[:queue_size],
      memory_bytes: info[:memory]
    }

    base
    |> put_some(:os_pid, info[:os_pid])
    |> put_some(
      :registered_name,
      info[:registered_name] && Format.inspect(info[:registered_name])
    )
    |> Map.merge(socket_fields(socket))
    |> Map.merge(owner_fields(owner))
  end

  defp socket_fields([]), do: %{}

  defp socket_fields(socket) do
    %{
      socket: %{
        peer: address(socket[:stats] && socket[:peer]),
        local: address(socket[:local]),
        stats: ok_map(socket[:stats]),
        options: ok_map(socket[:options])
      }
    }
  end

  defp address({:ok, {ip, port}}) when is_tuple(ip), do: "#{:inet.ntoa(ip)}:#{port}"
  defp address({:error, reason}), do: "none (#{reason})"
  defp address(_), do: nil

  defp ok_map({:ok, list}), do: Map.new(list, fn {k, v} -> {k, Format.inspect(v)} end)
  defp ok_map(_), do: nil

  defp owner_fields({initial, info}) when is_list(info) do
    %{
      owner_process:
        %{
          initial_call: Format.inspect(initial),
          current_function: Format.inspect(info[:current_function]),
          status: info[:status],
          message_queue_len: info[:message_queue_len]
        }
        |> put_some(
          :name,
          info[:registered_name] not in [nil, []] && Format.inspect(info[:registered_name])
        )
    }
  end

  defp owner_fields(_), do: %{}

  defp put_some(map, _key, value) when value in [nil, false, :undefined], do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # The holder traces Spec (a port, or new_ports for ports opened in the
  # window) and sends Collector one formatted line per event. It stops at
  # Max events, at the deadline, on `stop`, or when events queue up
  # faster than it can handle them. Session is true for a trace session of
  # its own (OTP 27+), false for the legacy session.
  @holder ~S"""
  Flags = case Spec of new_ports -> [ports, timestamp]; _ -> [send, 'receive', ports, timestamp] end,
  {Stop, N} = case Session of
    true ->
      S = trace:session_create(otp_debug_mcp_ports, self(), []),
      {fun() -> trace:session_destroy(S) end, trace:port(S, Spec, true, Flags)};
    false ->
      Me = self(),
      {fun() -> catch erlang:trace(Spec, false, Flags) end,
       erlang:trace(Spec, true, [{tracer, Me} | Flags])}
  end,
  Time = fun({_, _, Us} = TS) ->
    {_, {H, Mi, Sec}} = calendar:now_to_universal_time(TS),
    io_lib:format("~2..0w:~2..0w:~2..0w.~6..0wZ", [H, Mi, Sec, Us])
  end,
  Term = fun(T) -> io_lib:format("~9999tP", [T, 20], [{chars_limit, 300}]) end,
  Line = fun(E) when element(1, E) =:= trace_ts ->
      [trace_ts, Port, Kind | Rest] = tuple_to_list(E),
      {What, [TS]} = lists:split(length(Rest) - 1, Rest),
      io_lib:format("~s ~p ~p ~ts", [Time(TS), Port, Kind, lists:join(" ", [Term(W) || W <- What])]);
    (_) -> skip
  end,
  _ = Line({trace_ts, self(), x, x, os:timestamp()}),
  Owner ! {trace_started, self(), N},
  Deadline = erlang:monotonic_time(millisecond) + Duration,
  Loop = fun L(Count) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
      stop -> stopped;
      Msg when is_tuple(Msg), element(1, Msg) =:= trace_ts ->
        Collector ! {trace_line, self(), Line(Msg)},
        case erlang:process_info(self(), message_queue_len) of
          _ when Count + 1 >= Max -> max_events;
          {message_queue_len, Q} when Q > 1000 -> overloaded;
          _ -> L(Count + 1)
        end;
      _ -> L(Count)
    after Left -> duration
    end
  end,
  Reason = Loop(0),
  Stop(),
  case Reason of
    overloaded ->
      Collector ! {trace_line, self(), "trace stopped early: events arrived faster than they could be traced safely"};
    _ -> ok
  end.
  """

  @doc """
  Trace `spec` (a port, or `:new_ports` for ports opened in the window)
  for up to `duration_ms`, stopping after `max_events`. Options: `:force`
  on nodes without trace sessions, and `:backend` (`:legacy` to use the
  legacy session on a node with sessions, for testing).
  """
  def trace(spec, max_events, duration_ms, opts \\ []) do
    with {:ok, target} <- Target.target(),
         {:ok, session?} <- sessions?(Keyword.get(opts, :backend, :auto)),
         :ok <- check_legacy(session?, Keyword.get(opts, :force, false), target) do
      collector = Tracer.start_collector(max_events)

      bindings = [
        Spec: spec,
        Session: session?,
        Max: max_events,
        Duration: duration_ms,
        Collector: collector,
        Owner: self()
      ]

      with {:ok, events} <- Tracer.run_traced(target, @holder, bindings, collector, duration_ms) do
        {:ok,
         %{
           events: events,
           backend: if(session?, do: "isolated trace session", else: "legacy trace session")
         }}
      end
    end
  end

  @sessions_probe ~S"""
  case code:ensure_loaded(trace) of
    {module, trace} -> erlang:function_exported(trace, port, 4);
    _ -> false
  end.
  """

  defp sessions?(:legacy), do: {:ok, false}
  defp sessions?(:auto), do: Checks.remote_eval(@sessions_probe)

  defp check_legacy(true, _force, _target), do: :ok

  defp check_legacy(false, force, target) do
    case Tracer.other_tracing() do
      {:ok, nil} ->
        :ok

      {:ok, _} when force ->
        :ok

      {:ok, other} ->
        {:error,
         %{
           refused: "other tracing is active on #{target}",
           active_tracing: other,
           why:
             "This node predates OTP 27's isolated trace sessions, so trace_port uses the node's " <>
               "legacy trace session, which this tracing uses too. Tracing a port there can end it.",
           next_step:
             "Ask the user whether it is OK to stop this tracing. Only if they agree, call " <>
               "trace_port again with force: true."
         }}

      err ->
        err
    end
  end
end
