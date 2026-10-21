defmodule OtpDebugMcp.Tracer do
  @moduledoc """
  Safe, rate-limited call tracing on the target node.

  Every trace is capped on event count and wall-clock duration, and stops
  early if trace messages arrive faster than they can be handled, so an
  over-eager agent can't melt a production node the way raw
  `dbg`/`erlang:trace` can.

  Tracing runs in a holder process spawned on the target, using only
  erl_eval so no code of ours has to exist there. It starts the trace, keeps
  it alive for the window, then stops it. Formatted trace lines go to a
  collector on our node, which counts them so we can return as soon as
  `max_events` lines have arrived.

  There are two backends, chosen by what the target supports:

    * **OTP 27+: an isolated trace session.** The holder creates its own
      session with `trace:session_create/3` and is the session's tracer.
      Tracing in other sessions, including the legacy one used by
      recon_trace, `dbg` and `erlang:trace/3`, is never touched, and the
      session is destroyed with the holder however it exits.

    * **Older nodes: recon_trace.** recon_trace links its tracer to the
      calling process, which the holder keeps alive. It allows one trace per
      node, and its `clear/0` (run when a trace starts and stops) turns off
      *all* tracing in the node's legacy trace session, whoever set it up.
      So before tracing we look for such tracing and refuse unless forced.
  """

  alias OtpDebugMcp.{Checks, Format, Target}

  # Whether the target has OTP 27+ trace sessions.
  @sessions_probe """
  case code:ensure_loaded(trace) of
    {module, trace} -> erlang:function_exported(trace, session_create, 3);
    _ -> false
  end.
  """

  # The isolated-session holder, which is also the session's tracer. It
  # formats each trace message on one line (~9999tP sets the line length),
  # depth- and length-limited so a GenServer callback's huge state can't
  # produce a huge line. It stops at Max lines,
  # at the deadline, on `stop`, or when trace messages queue up faster than
  # it can handle them. Its own calls aren't traced.
  @session_holder """
  group_leader(Collector, self()),
  {M, F, MatchSpec} = Spec,
  S = trace:session_create(otp_debug_mcp, self(), []),
  trace:process(S, all, true, [call, timestamp]),
  trace:process(S, self(), false, [call, timestamp]),
  N = trace:function(S, {M, F, '_'}, MatchSpec, [local]),
  Time = fun({_, _, Us} = TS) ->
    {_, {H, Mi, Sec}} = calendar:now_to_universal_time(TS),
    io_lib:format("~2..0w:~2..0w:~2..0w.~6..0wZ", [H, Mi, Sec, Us])
  end,
  Fmt = fun(Format, Args) -> io_lib:format(Format, Args, [{chars_limit, 1000}]) end,
  Line = fun
    ({trace_ts, P, call, {Mod, Fun, Args}, TS}) ->
      Fmt("~s ~p ~tp:~tp(~ts)",
          [Time(TS), P, Mod, Fun, lists:join(", ", [io_lib:format("~9999tP", [A, 20]) || A <- Args])]);
    ({trace_ts, P, return_from, {Mod, Fun, Arity}, R, TS}) ->
      Fmt("~s ~p ~tp:~tp/~p --> ~9999tP", [Time(TS), P, Mod, Fun, Arity, R, 20]);
    ({trace_ts, P, exception_from, {Mod, Fun, Arity}, {Class, Reason}, TS}) ->
      Fmt("~s ~p ~tp:~tp/~p raised ~p:~9999tP", [Time(TS), P, Mod, Fun, Arity, Class, Reason, 20]);
    (_) ->
      skip
  end,
  %% Format one event of each kind now, so whatever formatting loads
  %% (calendar, io_lib_pretty, epp...) loads while the start still counts
  %% toward this tool's footprint, not on the first real event.
  _ = [Line(E) || E <- [{trace_ts, self(), call, {M, F, [x]}, os:timestamp()},
                        {trace_ts, self(), return_from, {M, F, 1}, x, os:timestamp()},
                        {trace_ts, self(), exception_from, {M, F, 1}, {error, x}, os:timestamp()}]],
  Owner ! {trace_started, self(), N},
  Deadline = erlang:monotonic_time(millisecond) + Duration,
  Loop = fun L(Count) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
      stop ->
        stopped;
      Msg when is_tuple(Msg), element(1, Msg) =:= trace_ts ->
        case Line(Msg) of
          skip ->
            L(Count);
          Text ->
            Collector ! {trace_line, self(), Text},
            case erlang:process_info(self(), message_queue_len) of
              _ when Count + 1 >= Max -> max_events;
              {message_queue_len, Q} when Q > 1000 -> overloaded;
              _ -> L(Count + 1)
            end
        end;
      _ ->
        L(Count)
    after Left ->
      duration
    end
  end,
  Reason = Loop(0),
  trace:session_destroy(S),
  case Reason of
    overloaded ->
      Collector ! {trace_line, self(),
        "trace stopped early: calls arrived faster than they could be traced safely. "
        "Trace a specific function instead of the whole module."};
    _ ->
      ok
  end.
  """

  # The holder's group leader is set to the collector first, so recon_trace's
  # own messages (e.g. "rate limit tripped") land in the results instead of
  # being forwarded to our stdout, which is the MCP protocol stream.
  @recon_holder """
  group_leader(Collector, self()),
  N = recon_trace:calls(Spec, Max, Opts),
  %% As in the session holder: let formatting load what it needs now.
  {M, F, _} = Spec,
  _ = [catch recon_trace:format(E) || E <- [{trace, self(), call, {M, F, [x]}},
                                            {trace, self(), return_from, {M, F, 1}, x}]],
  Owner ! {trace_started, self(), N},
  receive stop -> ok after Duration -> ok end,
  recon_trace:clear().
  """

  # Active tracing in the legacy session: a registered recon_trace tracer,
  # tracing inherited by new processes, and every process that has a tracer.
  # trace_info/2 returns `undefined` for processes that exit mid-scan, which
  # the generator pattern skips.
  @probe """
  Recon = case whereis(recon_trace_tracer) of undefined -> []; R -> [R] end,
  New = case erlang:trace_info(new, tracer) of {tracer, []} -> []; {tracer, NT} -> [NT]; _ -> [] end,
  Traced = [T || P <- erlang:processes(), {tracer, T} <- [erlang:trace_info(P, tracer)], T =/= []],
  Tracers = lists:usort(Recon ++ New ++ Traced),
  {Recon =/= [], New =/= [], length(Traced),
   [{T, catch erlang:process_info(T, [registered_name, initial_call, current_function])}
    || T <- Tracers, is_pid(T)] ++ [{T, other} || T <- Tracers, not is_pid(T)]}.
  """

  @type result :: %{
          events: [String.t()],
          backend: String.t(),
          stopped_other_tracing: term()
        }

  @doc """
  Trace calls to `module_str` (and `function_str`, or all its functions).

  Options:

    * `:force` - on the recon_trace backend, trace even though other
      tracing is active, ending it (default `false`)
    * `:backend` - `:auto` (default) picks an isolated trace session when
      the target supports it, else recon_trace; `:recon_trace` forces the
      latter, for testing it on newer nodes
  """
  @spec trace(String.t(), String.t() | nil, pos_integer(), pos_integer(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def trace(module_str, function_str, max_events, duration_ms, opts \\ []) do
    mod = resolve_module(module_str)
    fun = if function_str, do: String.to_atom(function_str), else: :_
    # exception_trace reports returns, like return_trace, and exceptions too.
    spec = {mod, fun, [{:_, [], [{:exception_trace}]}]}

    with {:ok, true} <- Target.rpc(:code, :is_loaded, [mod]) |> loaded?(module_str),
         {:ok, target} <- Target.target(),
         {:ok, backend} <- backend(Keyword.get(opts, :backend, :auto)) do
      case backend do
        :session ->
          session_trace(target, spec, max_events, duration_ms)

        :recon_trace ->
          recon_trace(target, spec, max_events, duration_ms, Keyword.get(opts, :force, false))
      end
    end
  end

  defp backend(:recon_trace), do: {:ok, :recon_trace}

  defp backend(:auto) do
    with {:ok, sessions?} <- Checks.remote_eval(@sessions_probe) do
      {:ok, if(sessions?, do: :session, else: :recon_trace)}
    end
  end

  defp session_trace(target, spec, max_events, duration_ms) do
    collector = start_collector(max_events)

    bindings = [
      Spec: spec,
      Max: max_events,
      Duration: duration_ms,
      Collector: collector,
      Owner: self()
    ]

    with {:ok, events} <-
           run_holder(target, @session_holder, bindings, collector, spec, duration_ms) do
      {:ok, %{events: events, backend: "isolated trace session", stopped_other_tracing: nil}}
    end
  end

  defp recon_trace(target, spec, max_events, duration_ms, force) do
    with {:ok, other} <- other_tracing(),
         :ok <- refuse_unless_forced(other, force, target) do
      collector = start_collector(max_events)

      bindings = [
        Spec: spec,
        Max: max_events,
        Opts: [scope: :local, io_server: collector],
        Duration: duration_ms,
        Collector: collector,
        Owner: self()
      ]

      with {:ok, events} <-
             run_holder(target, @recon_holder, bindings, collector, spec, duration_ms) do
        {:ok, %{events: events, backend: "recon_trace", stopped_other_tracing: other}}
      end
    end
  end

  # Spawns the holder, waits for it to report how many functions it traces,
  # then collects events. The holder is stopped, and we wait for it to exit,
  # before returning: for recon_trace, that means its clear() has run, so our
  # own trace is gone before the next call probes for other tracing.
  defp run_holder(target, code, bindings, collector, {mod, fun, _}, duration_ms) do
    case start_holder(target, code, bindings) do
      {:started, holder, ref, 0} ->
        stop_and_wait(holder, ref)

        {:error,
         "no function in #{Format.inspect(mod)} matches #{fun}. The module is loaded on the " <>
           "target, so check the function name."}

      {:started, holder, ref, _matched} ->
        events = await_events(collector, ref, duration_ms)
        stop_and_wait(holder, ref)
        {:ok, events}

      {:down, {:undef, [{:recon_trace = m, f, a, _} | _]}} ->
        {:error, Target.missing_recon_message(m, f, length(a))}

      {:down, reason} ->
        {:error, {:trace_failed, reason}}

      {:timeout, holder, ref} ->
        stop_and_wait(holder, ref)
        {:error, "the trace did not start within 5s"}
    end
  end

  # Spawning the holder sends its code and bindings, whose atoms (variable
  # names, the traced function) the target may not have yet, and starting
  # the trace may load modules there, so it counts toward the footprint.
  defp start_holder(target, code, bindings) do
    exprs = parse!(code)
    # A list of bindings is an orddict to erl_eval, so it must be sorted.
    bindings = Enum.sort(bindings)

    Target.with_footprint(target, {:trace_holder, :erlang.phash2(code)}, [exprs, bindings], fn ->
      # The holder; recon_trace spawns its tracer and formatter too.
      Target.note_spawns(target, if(code == @recon_holder, do: 3, else: 1))

      {holder, ref} =
        Target.with_stderr_group_leader(fn ->
          Node.spawn_monitor(target, :erl_eval, :exprs, [exprs, bindings])
        end)

      receive do
        {:trace_started, ^holder, matched} -> {:started, holder, ref, matched}
        {:DOWN, ^ref, :process, _, reason} -> {:down, reason}
      after
        5_000 -> {:timeout, holder, ref}
      end
    end)
  end

  defp stop_and_wait(holder, ref) do
    send(holder, :stop)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end
  end

  # Returns once max_events lines have arrived, the holder has finished on
  # its own, or the duration has passed.
  defp await_events(collector, ref, duration_ms) do
    receive do
      {:events, ^collector, events} ->
        events

      {:DOWN, ^ref, :process, _, _} = down ->
        # Put it back for stop_and_wait.
        send(self(), down)
        drain(collector)
    after
      duration_ms -> drain(collector)
    end
  end

  defp drain(collector) do
    send(collector, :drain)

    receive do
      {:events, ^collector, events} -> events
    after
      1_000 -> []
    end
  end

  defp other_tracing do
    with {:ok, {recon?, new?, traced_count, tracers}} <- Checks.remote_eval(@probe) do
      if recon? or new? or traced_count > 0 do
        {:ok,
         %{
           recon_trace_session: recon?,
           traces_new_processes: new?,
           traced_processes: traced_count,
           tracers: Enum.map(tracers, &describe_tracer/1)
         }}
      else
        {:ok, nil}
      end
    end
  end

  defp describe_tracer({tracer, info}) when is_list(info) do
    %{
      tracer: Format.inspect(tracer),
      registered_name: Format.inspect(info[:registered_name]),
      initial_call: Format.inspect(info[:initial_call]),
      current_function: Format.inspect(info[:current_function])
    }
  end

  defp describe_tracer({tracer, _}), do: %{tracer: Format.inspect(tracer)}

  defp refuse_unless_forced(nil, _force, _target), do: :ok
  defp refuse_unless_forced(_other, true, _target), do: :ok

  defp refuse_unless_forced(other, false, target) do
    {:error,
     %{
       refused: "other tracing is active on #{target}",
       active_tracing: other,
       why:
         "This node predates OTP 27's isolated trace sessions, so trace_calls uses " <>
           "recon_trace, which turns off all tracing in the node's legacy trace " <>
           "session when it starts and stops. This tracing would end. Someone may " <>
           "be debugging this node right now.",
       next_step:
         "Ask the user whether it is OK to stop this tracing. Only if they agree, " <>
           "call trace_calls again with force: true."
     }}
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

  defp start_collector(max_events) do
    owner = self()
    spawn(fn -> collector_loop(owner, max_events, []) end)
  end

  # Receives trace lines: as io requests from recon_trace's formatter, or as
  # plain messages from the session holder. Replies to the owner with all
  # lines once max_events have arrived, or when asked to drain.
  defp collector_loop(owner, max, acc) do
    receive do
      {:io_request, from, reply_as, request} ->
        send(from, {:io_reply, reply_as, :ok})
        collect(chars(request), owner, max, acc)

      {:trace_line, _holder, text} ->
        collect(text |> IO.chardata_to_string() |> truncate(), owner, max, acc)

      :drain ->
        send(owner, {:events, self(), Enum.reverse(acc)})
        discard_loop()
    after
      120_000 -> :ok
    end
  end

  defp collect(nil, owner, max, acc), do: collector_loop(owner, max, acc)

  defp collect(line, owner, max, acc) when length(acc) + 1 >= max do
    send(owner, {:events, self(), Enum.reverse([line | acc])})
    discard_loop()
  end

  defp collect(line, owner, max, acc), do: collector_loop(owner, max, [line | acc])

  # Once results are delivered, keep acknowledging writes until the trace is
  # gone: recon_trace's formatter crashes on the *target* (polluting its
  # logs) if its io server disappears before its final messages.
  defp discard_loop do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        discard_loop()

      {:trace_line, _holder, _text} ->
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

  # recon_trace pretty-prints terms over several indented lines.
  defp truncate(line) do
    line = line |> String.trim() |> String.replace(~r/\s*\n\s*/, " ")

    if String.length(line) > @max_line do
      String.slice(line, 0, @max_line) <> " …(truncated)"
    else
      line
    end
  end
end
