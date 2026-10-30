defmodule OtpDebugMcp.CallLatency do
  @moduledoc """
  How long one gen_server makes its callers wait, and why, without any
  telemetry: for a window, its calls by request, each split into the time
  it waited in the mailbox and the time the server took to handle it;
  its casts and other messages by kind, with their handling time; who
  calls it most and waits longest; and how much of the window the server
  spent busy.

  It traces the process alone: the messages it receives, its replies
  (sends of `{Tag, Reply}` to a caller), and the start and the end of its
  callbacks (handle_call/3, handle_cast/2, handle_info/2, traced with
  `arity` and `return_to`, so the server's state is never copied into a
  trace message: only a call's request and caller, and a cast's or
  message's shape). A call's wait is from its arrival to the start of
  handle_call; its handling, from there to the reply (which may be later,
  with `{:noreply, ...}` and `gen_server:reply/2`); its total, what the
  caller waited. A cast's wait is matched in order, as gen_server takes
  messages in order.

  The trace runs in its own trace session on OTP 27 and later, alongside
  any other tracing. On older nodes it uses the node's legacy session,
  and refuses when something else traces there. It stops at `max_events`
  trace messages, or if they come faster than the holder can take them.
  """

  alias OtpDebugMcp.{Checks, Format, Tracer}

  @name :otp_debug_mcp_latency
  # Durations kept per request kind, at most, for the percentiles.
  @max_samples 5_000

  @start ~S"""
  Resolve = fun(P) when is_pid(P) -> P;
               (N) when is_atom(N) -> whereis(N);
               (_) -> undefined
            end,
  case {whereis(Name), Resolve(Target)} of
    {W, _} when is_pid(W) -> already_running;
    {_, undefined} -> no_process;
    {_, Pid} ->
      Mod = case catch proc_lib:translate_initial_call(Pid) of
        {M, init, 1} -> M;
        _ -> undefined
      end,
      case Mod =/= undefined andalso erlang:function_exported(Mod, handle_call, 3) of
        false -> {not_gen_server, Mod};
        true ->
          Parent = self(),
          Ref = make_ref(),
          Shape = fun(T) when is_atom(T) -> T;
                     (T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) -> {element(1, T), tuple_size(T)};
                     (T) when is_tuple(T) -> {tuple, tuple_size(T)};
                     (T) when is_list(T) -> list;
                     (T) when is_binary(T) -> binary;
                     (T) when is_map(T) -> map;
                     (_) -> other
                  end,
          %% handle_call's request and caller, handle_cast's and
          %% handle_info's message: not the state.
          Patterns = [{{Mod, handle_call, 3}, [{['$1', '$2', '_'], [], [{message, {{call, '$1', '$2'}}}]}]},
                      {{Mod, handle_cast, 2}, [{['$1', '_'], [], [{message, {{cast, '$1'}}}]}]},
                      {{Mod, handle_info, 2}, [{['$1', '_'], [], [{message, {{info, '$1'}}}]}]}],
          Flags = ['receive', send, call, arity, return_to, monotonic_timestamp],
          %% Replies only: {Tag, Reply}, the tag a reference or [alias | ref].
          SendSpec = [{['_', {'$1', '_'}], [{'orelse', {is_reference, '$1'}, {is_list, '$1'}}], []}],
          Holder = spawn(fun() ->
            Me = self(),
            case catch register(Name, Me) of
              true ->
                Stop = case Session of
                  true ->
                    S = trace:session_create(otp_debug_mcp_latency, Me, []),
                    trace:process(S, Pid, true, Flags),
                    trace:send(S, SendSpec, []),
                    [trace:function(S, MFA, MS, [local]) || {MFA, MS} <- Patterns],
                    fun() -> trace:session_destroy(S) end;
                  false ->
                    erlang:trace(Pid, true, [{tracer, Me} | Flags]),
                    erlang:trace_pattern(send, SendSpec, []),
                    [erlang:trace_pattern(MFA, MS, [local]) || {MFA, MS} <- Patterns],
                    fun() ->
                      catch erlang:trace(Pid, false, ['receive', send, call, arity, return_to]),
                      catch erlang:trace_pattern(send, true, []),
                      [catch erlang:trace_pattern(MFA, false, [local]) || {MFA, _} <- Patterns],
                      ok
                    end
                end,
                MRef = erlang:monitor(process, Pid),
                Q0 = element(2, erlang:process_info(Pid, message_queue_len)),
                Parent ! {Ref, started},
                T0 = erlang:monotonic_time(),
                Deadline = erlang:monotonic_time(millisecond) + Duration,
                Add = fun(Key, V, Acc) ->
                  {N, L} = maps:get(Key, Acc, {0, []}),
                  Acc#{Key => {N + 1, case N < MaxSamples of true -> [V | L]; false -> L end}}
                end,
                %% St: pending calls by tag, cast arrivals in order, the
                %% callback running, samples, callers, busy time, counts.
                Init = #{pending => #{}, casts => queue:new(), running => none, samples => #{},
                         callers => #{}, busy => 0, events => 0, unreplied_by_server => 0},
                Handle = fun
                  ({trace_ts, _, 'receive', {'$gen_call', {From, Tag}, Req}, TS}, St) ->
                    P = maps:get(pending, St),
                    St#{pending := P#{Tag => #{arrived => TS, shape => Shape(Req), from => From}}};
                  ({trace_ts, _, 'receive', {'$gen_cast', Msg}, TS}, St) ->
                    St#{casts := queue:in({TS, Shape(Msg)}, maps:get(casts, St))};
                  ({trace_ts, _, 'receive', _, _}, St) -> St;
                  ({trace_ts, _, call, {_, handle_call, 3}, {call, _, {_, Tag}}, TS}, St) ->
                    P = maps:get(pending, St),
                    case maps:find(Tag, P) of
                      {ok, C} -> St#{pending := P#{Tag => C#{started => TS}}, running => {call, Tag, TS}};
                      error -> St#{running => {call, Tag, TS}}
                    end;
                  ({trace_ts, _, call, {_, handle_cast, 2}, {cast, Msg}, TS}, St) ->
                    {Arrived, Casts} = case queue:out(maps:get(casts, St)) of
                      {{value, {A, _}}, Rest} -> {A, Rest};
                      {empty, Q} -> {undefined, Q}
                    end,
                    St#{casts := Casts, running => {cast, Shape(Msg), TS, Arrived}};
                  ({trace_ts, _, call, {_, handle_info, 2}, {info, Msg}, TS}, St) ->
                    St#{running => {info, Shape(Msg), TS}};
                  ({trace_ts, _, return_to, _, TS}, St) ->
                    Samples = maps:get(samples, St),
                    case maps:get(running, St) of
                      {call, _, Start} ->
                        St#{running := none, busy := maps:get(busy, St) + (TS - Start)};
                      {cast, Sh, Start, Arrived} ->
                        S1 = Add({cast, Sh, handling}, TS - Start, Samples),
                        S2 = case Arrived of undefined -> S1; _ -> Add({cast, Sh, wait}, Start - Arrived, S1) end,
                        St#{running := none, samples := S2, busy := maps:get(busy, St) + (TS - Start)};
                      {info, Sh, Start} ->
                        St#{running := none, samples := Add({info, Sh, handling}, TS - Start, Samples),
                            busy := maps:get(busy, St) + (TS - Start)};
                      none -> St
                    end;
                  ({trace_ts, _, send, {Tag, _}, _To, TS}, St) ->
                    P = maps:get(pending, St),
                    case maps:take(Tag, P) of
                      {#{arrived := A, shape := Sh, from := From} = C, P1} ->
                        Started = maps:get(started, C, A),
                        S0 = maps:get(samples, St),
                        S1 = Add({call, Sh, wait}, Started - A, S0),
                        S2 = Add({call, Sh, handling}, TS - Started, S1),
                        S3 = Add({call, Sh, total}, TS - A, S2),
                        Cs = maps:get(callers, St),
                        {N, Sum, Max} = maps:get(From, Cs, {0, 0, 0}),
                        St#{pending := P1, samples := S3,
                            callers := Cs#{From => {N + 1, Sum + (TS - A), max(Max, TS - A)}}};
                      error -> St
                    end;
                  (_, St) -> St
                end,
                Loop = fun L(St) ->
                  Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
                  receive
                    {read, From, ReadRef} -> {read, From, ReadRef, St};
                    {'DOWN', MRef, _, _, Why} -> {down, Why, St};
                    Msg when is_tuple(Msg), element(1, Msg) =:= trace_ts ->
                      St1 = Handle(Msg, St),
                      Events = maps:get(events, St1) + 1,
                      case erlang:process_info(Me, message_queue_len) of
                        _ when Events >= MaxEvents -> {max_events, St1#{events := Events}};
                        {message_queue_len, Qn} when Qn > 5000 -> {overloaded, St1#{events := Events}};
                        _ -> L(St1#{events := Events})
                      end;
                    _ -> L(St)
                  after Left -> {duration, St}
                  end
                end,
                Result = Loop(Init),
                Stop(),
                T1 = erlang:monotonic_time(),
                Ended = element(1, Result),
                St = element(tuple_size(Result), Result),
                Q1 = case erlang:process_info(Pid, message_queue_len) of {message_queue_len, Qq} -> Qq; _ -> undefined end,
                Now = erlang:monotonic_time(),
                Pending = [{maps:get(shape, C), Now - maps:get(arrived, C), maps:get(from, C)}
                           || C <- maps:values(maps:get(pending, St))],
                Busy = maps:get(busy, St) + case maps:get(running, St) of
                  none -> 0;
                  %% Each kind of running callback has its start third.
                  Running -> T1 - element(3, Running)
                end,
                Report = #{module => Mod, pid => Pid, ended => Ended,
                           window => erlang:convert_time_unit(T1 - T0, native, microsecond),
                           busy => erlang:convert_time_unit(Busy, native, microsecond),
                           samples => maps:map(fun(_, {N, L}) -> {N, [erlang:convert_time_unit(V, native, microsecond) || V <- L]} end,
                                               maps:get(samples, St)),
                           callers => [{From, N, erlang:convert_time_unit(Sum, native, microsecond),
                                        erlang:convert_time_unit(Max, native, microsecond)}
                                       || {From, {N, Sum, Max}} <- maps:to_list(maps:get(callers, St))],
                           pending => [{Sh, erlang:convert_time_unit(Age, native, microsecond), From}
                                       || {Sh, Age, From} <- lists:sublist(Pending, 50)],
                           pending_count => length(Pending),
                           events => maps:get(events, St), mailbox => {Q0, Q1},
                           current => catch erlang:process_info(Pid, current_function)},
                case Result of
                  {read, From, ReadRef, _} -> From ! {ReadRef, Report};
                  _ -> receive {read, From, ReadRef} -> From ! {ReadRef, Report} after 30000 -> ok end
                end;
              _ ->
                Parent ! {Ref, already_running}
            end
          end),
          receive
            {Ref, started} -> {started, Holder, Mod};
            {Ref, Other} -> Other
          after 5000 -> exit(Holder, kill), timeout
          end
      end
  end.
  """

  @read ~S"""
  case whereis(Name) of
    undefined -> none;
    W ->
      Ref = make_ref(),
      MRef = erlang:monitor(process, W),
      W ! {read, self(), Ref},
      receive
        {Ref, R} -> erlang:demonitor(MRef, [flush]), {ok, R};
        {'DOWN', MRef, _, _, Why} -> {died, Why}
      after 10000 -> timeout
      end
  end.
  """

  # Who a caller is: its registered name, or the first function in its
  # stack that isn't OTP's own call machinery.
  @callers ~S"""
  Skip = [gen, gen_server, gen_statem, proc_lib, erlang, timer, lists, 'Elixir.GenServer', 'Elixir.Process',
          'Elixir.Task', 'Elixir.Enum'],
  [{P, case erlang:process_info(P, [registered_name, current_stacktrace]) of
         [{registered_name, N}, _] when is_atom(N) -> {name, N};
         [_, {current_stacktrace, St}] ->
           case [{M, F, A} || {M, F, A, _} <- St, not lists:member(M, Skip)] of
             [MFA | _] -> {at, MFA};
             [] -> gone
           end;
         _ -> gone
       end} || P <- Pids, is_pid(P), node(P) =:= node()].
  """

  @doc """
  Trace `process` (a pid as text, or a registered name) for `duration_ms`,
  at most `max_events` trace messages. Options: `force: true` to trace in
  the legacy session even though something else traces there (older
  nodes only).
  """
  def run(process, duration_ms, max_events, opts \\ []) do
    with {:ok, target} <- target(process),
         {:ok, session?} <- sessions?(),
         :ok <- legacy_ok(session?, opts[:force]) do
      bindings = [
        Name: @name,
        Target: target,
        Session: session?,
        Duration: duration_ms,
        MaxEvents: max_events,
        MaxSamples: @max_samples
      ]

      case Checks.remote_eval(@start, bindings) do
        {:ok, {:started, _holder, _mod}} ->
          Process.sleep(duration_ms)

          case Checks.remote_eval(@read, Name: @name) do
            {:ok, {:ok, report}} -> {:ok, analyze(report, session?)}
            {:ok, other} -> {:error, "the trace holder didn't answer: #{Format.inspect(other)}"}
            err -> err
          end

        {:ok, :already_running} ->
          {:error, "a call_latency trace is already running on this node"}

        {:ok, :no_process} ->
          {:error, "no process #{process} on this node"}

        {:ok, {:not_gen_server, mod}} ->
          {:error,
           "#{process} isn't a gen_server (its callback module #{Format.inspect(mod)} has no handle_call/3): call_latency reads gen_server calls"}

        {:ok, other} ->
          {:error, Format.inspect(other)}

        err ->
          err
      end
    end
  end

  defp target("<" <> _ = pid) do
    case Checks.remote_eval("list_to_pid(P).", P: String.to_charlist(pid)) do
      {:ok, p} -> {:ok, p}
      _ -> {:error, "#{pid} isn't a pid"}
    end
  end

  defp target("Elixir." <> _ = name), do: {:ok, String.to_atom(name)}

  defp target(name) when is_binary(name) do
    # An Elixir module name as written in Elixir, or an Erlang atom.
    if name =~ ~r/^[A-Z]/,
      do: {:ok, String.to_atom("Elixir." <> name)},
      else: {:ok, String.to_atom(name)}
  end

  defp sessions? do
    case Checks.remote_eval("""
         case code:ensure_loaded(trace) of
           {module, trace} -> erlang:function_exported(trace, session_create, 3);
           _ -> false
         end.
         """) do
      {:ok, b} -> {:ok, b}
      err -> err
    end
  end

  defp legacy_ok(true, _), do: :ok
  defp legacy_ok(false, true), do: :ok

  defp legacy_ok(false, _) do
    case Tracer.other_tracing() do
      {:ok, nil} ->
        :ok

      {:ok, other} ->
        {:error,
         %{
           refused:
             "This node predates OTP 27's trace sessions, and something else traces in its legacy session; call_latency would change that tracing's send pattern. Pass force: true to trace anyway.",
           active_tracing: other
         }}

      err ->
        err
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(r, session?) do
    window = max(r.window, 1)
    samples = r.samples

    calls =
      samples
      |> kinds(:call)
      |> Enum.map(fn sh ->
        {n, total} = samples[{:call, sh, :total}]

        %{
          request: shape(sh),
          calls: n,
          per_s: Float.round(n * 1_000_000 / window, 1),
          total_ms: pct(total),
          wait_ms: pct(elem(samples[{:call, sh, :wait}], 1)),
          handling_ms: pct(elem(samples[{:call, sh, :handling}], 1)),
          share_of_busy_time: share(elem(samples[{:call, sh, :handling}], 1), r.busy)
        }
      end)
      |> Enum.sort_by(&(-&1.total_ms.p95))

    casts =
      samples
      |> kinds(:cast)
      |> Enum.map(fn sh ->
        {n, handling} = samples[{:cast, sh, :handling}]

        %{
          message: shape(sh),
          casts: n,
          handling_ms: pct(handling),
          share_of_busy_time: share(handling, r.busy)
        }
        |> put(:wait_ms, samples[{:cast, sh, :wait}] && pct(elem(samples[{:cast, sh, :wait}], 1)))
      end)
      |> Enum.sort_by(&(-&1.handling_ms.p95))

    infos =
      samples
      |> kinds(:info)
      |> Enum.map(fn sh ->
        {n, handling} = samples[{:info, sh, :handling}]

        %{
          message: shape(sh),
          messages: n,
          handling_ms: pct(handling),
          share_of_busy_time: share(handling, r.busy)
        }
      end)
      |> Enum.sort_by(&(-&1.handling_ms.p95))

    callers = callers(r.callers)
    {q0, q1} = r.mailbox

    report =
      %{
        process: Format.inspect(r.pid),
        module: Format.inspect(r.module),
        window_ms: div(window, 1000),
        busy_share: Float.round(r.busy / window, 3),
        mailbox: %{at_start: q0, at_end: q1},
        trace: if(session?, do: "isolated trace session", else: "legacy trace session"),
        events: r.events,
        ended: ended(r.ended)
      }
      |> put(:calls, calls != [] && calls)
      |> put(:casts, casts != [] && casts)
      |> put(:other_messages, infos != [] && infos)
      |> put(:callers, callers != [] && callers)
      |> put(:unanswered_at_end, unanswered(r))

    notes = findings(report) |> Enum.sort_by(fn {l, _} -> rank(l) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({l, t} <- notes, do: "#{l}: #{t}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp kinds(samples, kind) do
    for {{^kind, sh, _}, _} <- samples, uniq: true, do: sh
  end

  defp pct([]), do: %{p50: 0, p95: 0, max: 0}

  defp pct(us) do
    sorted = Enum.sort(us)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, floor(q * n))) end
    ms = &Float.round(&1 / 1000, 2)
    %{p50: ms.(at.(0.5)), p95: ms.(at.(0.95)), max: ms.(List.last(sorted))}
  end

  # The share of the busy time spent on these, from the samples kept.
  defp share(us, busy) when busy > 0, do: Float.round(Enum.sum(us) / busy, 3)
  defp share(_, _), do: 0.0

  defp shape({tag, arity}) when is_atom(tag) and is_integer(arity),
    do: "{#{Format.inspect(tag)}, ...} (#{arity}-tuple)"

  defp shape(atom) when is_atom(atom), do: Format.inspect(atom)
  defp shape(other), do: Format.inspect(other)

  defp callers([]), do: []

  defp callers(rows) do
    top = rows |> Enum.sort_by(fn {_, n, sum, _} -> -sum - n end) |> Enum.take(10)

    names =
      case Checks.remote_eval(@callers, Pids: Enum.map(top, &elem(&1, 0))) do
        {:ok, list} -> Map.new(list)
        _ -> %{}
      end

    for {pid, n, sum, max} <- top do
      %{
        caller: Format.inspect(pid),
        calls: n,
        waited_ms_total: Float.round(sum / 1000, 1),
        waited_ms_max: Float.round(max / 1000, 1)
      }
      |> put(:is, who(names[pid]))
    end
  end

  defp who({:name, n}), do: Format.inspect(n)
  defp who({:at, {m, f, a}}) when is_list(a), do: who({:at, {m, f, length(a)}})

  defp who({:at, {m, f, a}}) do
    if String.starts_with?(Atom.to_string(m), "Elixir."),
      do: "in #{Format.inspect(m)}.#{f}/#{a}",
      else: "in #{m}:#{f}/#{a}"
  end

  defp who(_), do: false

  defp unanswered(%{pending_count: 0}), do: false

  defp unanswered(r) do
    oldest = r.pending |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

    %{
      calls: r.pending_count,
      oldest_ms: Float.round(oldest / 1000, 1),
      requests: r.pending |> Enum.map(&shape(elem(&1, 0))) |> Enum.frequencies()
    }
  end

  defp ended(:duration), do: "the window ended"
  defp ended(:read), do: "the window ended"
  defp ended(:max_events), do: "max_events reached: the window was cut short"
  defp ended(:overloaded), do: "stopped early: trace messages came faster than they could be read"
  defp ended(:down), do: "the process exited during the window"
  defp ended(other), do: Format.inspect(other)

  # -- Findings ------------------------------------------------------------------

  defp findings(r) do
    busy =
      cond do
        r.busy_share >= 0.95 ->
          [
            {:critical,
             "#{r.process} (#{r.module}) was busy #{round(r.busy_share * 100)}% of the window: it's at capacity, and every caller waits in its mailbox for those ahead of it"}
          ]

        r.busy_share >= 0.7 ->
          [
            {:warning,
             "#{r.process} (#{r.module}) was busy #{round(r.busy_share * 100)}% of the window: near capacity, so waits grow quickly with more load"}
          ]

        true ->
          []
      end

    queued =
      for c <- r[:calls] || [], c.wait_ms.p95 >= 10, c.wait_ms.p95 > c.handling_ms.p95 do
        {:warning,
         "#{c.request} calls waited #{c.wait_ms.p95} ms at p95 in the mailbox before the server even started on them, and took #{c.handling_ms.p95} ms to handle: the time is spent behind other messages, not on the request"}
      end
      |> Enum.take(2)

    hogs =
      (r[:calls] || []) ++ (r[:casts] || []) ++ (r[:other_messages] || [])

    hog =
      case Enum.max_by(hogs, & &1.share_of_busy_time, fn -> nil end) do
        %{share_of_busy_time: s, handling_ms: %{p95: p95}} = h when s >= 0.3 and p95 >= 50 ->
          what = h[:request] || h[:message]

          [
            {:warning,
             "#{what} takes #{p95} ms at p95 to handle and is #{round(s * 100)}% of the server's busy time: while one runs, everything else sent to the server waits. Make it faster, or move it off this process (a Task, a pool of workers, or reading the data directly, e.g. from ETS)"}
          ]

        _ ->
          []
      end

    timeouts =
      for c <- r[:calls] || [], c.total_ms.max >= 5_000 do
        {:warning,
         "a #{c.request} call waited #{c.total_ms.max} ms: past GenServer.call's default timeout of 5 s, its caller crashed with a timeout, unless it set a longer one"}
      end
      |> Enum.take(1)

    unanswered =
      case r[:unanswered_at_end] do
        %{calls: n, oldest_ms: ms} when ms >= 1_000 ->
          [{:warning, "#{n} calls were still unanswered at the end, the oldest for #{ms} ms"}]

        _ ->
          []
      end

    cut =
      if r.ended != "the window ended",
        do: [{:info, "#{r.ended}; the numbers cover the part traced"}],
        else: []

    busy ++ hog ++ queued ++ timeouts ++ unanswered ++ cut
  end

  defp rank(:critical), do: 0
  defp rank(:warning), do: 1
  defp rank(_), do: 2

  defp status(notes) do
    cond do
      Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
      Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
      true -> :ok
    end
  end

  defp put(map, _key, value) when value in [nil, false, []], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    One gen_server over a window, from tracing it alone. calls: by
    request (its first element and size), each with total_ms (what the
    caller waited: arrival to reply), wait_ms (in the mailbox, before
    handle_call started) and handling_ms (handle_call to the reply), as
    p50, p95 and max, and its share_of_busy_time. Wait much larger than
    handling means the server is the bottleneck: callers queue behind
    other work. casts and other_messages: handling time by message, a
    cast's wait too. busy_share: the share of the window the server spent
    in its callbacks; near 1, it's at capacity. callers: who waited
    longest, in all. unanswered_at_end: calls received but not replied to
    by the end (a reply may come from another process, with
    gen_server:reply/2, which this doesn't see). Next step: module_code
    on the callback that takes the time; profile on its module.
    """
  end
end
