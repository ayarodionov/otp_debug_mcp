defmodule OtpDebugMcp.TelemetryHandlers do
  @moduledoc """
  The telemetry handlers attached on a node, and what they cost.

  A handler runs in the process that emits the event, inside
  `telemetry:execute/3`: a slow one (a call to a busy reporter, a write
  to a slow sink) slows every request that emits it. A handler that
  raises is detached for good, from every event it was attached to,
  with one log line: whatever it reported stops, and nothing else says
  so. A handler attached per process or per request, under a fresh id,
  and never detached, piles up and runs on every event.

  The handlers come from `telemetry:list_handlers/1`. Over a window,
  processes' stacks are sampled for the ones inside a handler: the
  average number inside, divided by the events per second the handler
  receives, is about the time it takes per event (Little's law), with
  no tracing. Failures in the window come from telemetry's own
  `[telemetry, handler, failure]` event.
  """

  alias OtpDebugMcp.{Checks, Format, Telemetry}

  # Handlers described, processes sampled, and events listened to, at most.
  @max_handlers 20_000
  @max_processes 20_000
  @max_events 60

  @handlers ~S"""
  case code:is_loaded(telemetry) of
    false ->
      not_loaded;
    _ ->
      Hs = case catch telemetry:list_handlers([]) of L when is_list(L) -> L; _ -> [] end,
      Text = fun(T) -> lists:flatten(io_lib:format("~0tP", [T, 12], [{chars_limit, 200}])) end,
      Describe = fun(F) ->
        {type, Type} = erlang:fun_info(F, type),
        {module, M} = erlang:fun_info(F, module),
        {name, N} = erlang:fun_info(F, name),
        {arity, A} = erlang:fun_info(F, arity),
        %% Without loading anything: a module that isn't loaded is looked
        %% for on the code path.
        Exists = case Type of
          local -> ok;
          external ->
            case code:is_loaded(M) of
              false -> case code:which(M) of non_existing -> missing_module; _ -> ok end;
              _ -> case erlang:function_exported(M, N, A) of true -> ok; false -> missing_function end
            end
        end,
        {Type, M, N, A, Exists}
      end,
      {ok, length([I || #{id := I} <- Hs, I =/= Mine]),
       [{Text(Id), Ev, Describe(F), erts_debug:flat_size(Cfg)}
        || #{id := Id, event_name := Ev, function := F, config := Cfg} <- lists:sublist(Hs, MaxHandlers),
           Id =/= Mine]}
  end.
  """

  # Samples of the processes inside a handler: which handler (its id, read
  # from telemetry's own frame in the process's backtrace, as the handler
  # may have tail-called on, leaving no frame of its own), the frame just
  # above telemetry's, and where the process is now. Not a span's body
  # (telemetry:span runs it), and not this tool's listener.
  @sample ~S"""
  %% Each id as ~w prints it in a backtrace, and as the handler list
  %% shows it.
  Text = fun(T) -> lists:flatten(io_lib:format("~0tP", [T, 12], [{chars_limit, 200}])) end,
  Ids = case catch telemetry:list_handlers([]) of
    L when is_list(L) -> lists:usort([{lists:flatten(io_lib:format("~w", [Id])), Text(Id)} || #{id := Id} <- L]);
    _ -> []
  end,
  Frame = fun({M, F, A, _}) -> {M, F, case is_list(A) of true -> length(A); false -> A end} end,
  %% The y registers of telemetry's frame, each value as ~w prints it.
  Running = fun(P) ->
    case erlang:process_info(P, backtrace) of
      {backtrace, Bt} ->
        Lines = string:split(binary_to_list(Bt), "\n", all),
        After = lists:dropwhile(fun(Line) -> string:find(Line, "(telemetry:") =:= nomatch end, Lines),
        Values = [string:trim(lists:nthtail(5, Y)) || Y <- lists:takewhile(fun(Line) -> lists:prefix("y(", Line) end,
                                                                           tl(After ++ [""])),
                                                      length(Y) > 5],
        case [Id || {Text, Id} <- Ids, lists:member(Text, Values)] of
          [Id | _] -> Id;
          [] -> undefined
        end;
      _ -> undefined
    end
  end,
  %% Inside telemetry:execute, either in a handler (the frames above
  %% telemetry's do_execute) or in telemetry's own dispatch: looking the
  %% handlers up, or going through them.
  Own = fun(M) -> lists:member(M, [telemetry, telemetry_handler_table, telemetry_ets, telemetry_pt]) end,
  InHandler = fun(P, St) ->
    case lists:any(fun({telemetry, F, _, _}) -> lists:member(F, [execute, do_execute]); (_) -> false end, St) of
      false -> none;
      true ->
        case lists:splitwith(fun({M, _, _, _}) -> not Own(M) end, St) of
          {[_ | _] = Above, [{telemetry, TF, _, _} | _]} when TF =:= execute; TF =:= do_execute ->
            {HM, _, _} = H = Frame(lists:last(Above)),
            case HM of
              erl_eval -> none;
              _ -> {Running(P), H, Frame(hd(Above))}
            end;
          {_, [TelFrame | _]} ->
            {dispatch, Frame(TelFrame)};
          _ ->
            none
        end
    end
  end,
  Sample = fun() ->
    [Found || P <- lists:sublist(erlang:processes(), MaxProcs), P =/= self(),
              {current_stacktrace, St} <- [erlang:process_info(P, current_stacktrace)],
              Found <- [InHandler(P, St)], Found =/= none]
  end,
  Loop = fun L(0, Acc) -> lists:reverse(Acc);
             L(N, Acc) -> S = Sample(), timer:sleep(Interval), L(N - 1, [S | Acc])
         end,
  %% In a process of its own, while the window's listener runs; read
  %% back afterwards, or gone a minute later.
  case whereis(Name) of
    undefined ->
      Parent = self(),
      spawn(fun() ->
        register(Name, self()),
        Parent ! {Name, started},
        Result = Loop(Samples, []),
        receive {read, From, Ref} -> From ! {Ref, Result} after 60000 -> ok end
      end),
      receive {Name, started} -> started after 5000 -> timeout end;
    _ ->
      already_running
  end.
  """

  @read_samples ~S"""
  case whereis(Name) of
    undefined -> none;
    Pid ->
      Ref = make_ref(),
      Pid ! {read, self(), Ref},
      receive {Ref, Result} -> {ok, Result} after Wait -> timeout end
  end.
  """

  @sampler :otp_debug_mcp_telemetry_sampler

  @doc "The node's handlers, and over `duration_ms` what they cost."
  def report(duration_ms) do
    case handlers() do
      {:ok, :not_loaded} ->
        {:error, "telemetry isn't loaded on this node: no handlers"}

      {:ok, {:ok, total, first}} ->
        events =
          first
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq()
          |> Enum.take(@max_events)
          |> Enum.map(&Telemetry.event_name/1)

        samples = max(5, min(25, div(duration_ms, 200)))
        interval = div(duration_ms, samples)

        started =
          Checks.remote_eval(@sample,
            Samples: samples,
            Interval: interval,
            MaxProcs: @max_processes,
            Name: @sampler
          )

        listened = Telemetry.listen(["telemetry.handler.failure" | events], duration_ms)

        sampled =
          case started do
            {:ok, :started} ->
              case Checks.remote_eval(@read_samples, Name: @sampler, Wait: 10_000) do
                {:ok, {:ok, result}} -> {:ok, result}
                other -> other
              end

            other ->
              other
          end

        {last_total, last} =
          case handlers() do
            {:ok, {:ok, n, rows}} -> {n, rows}
            _ -> {total, first}
          end

        {:ok,
         analyze({total, first}, {last_total, last}, listened, sampled, samples, duration_ms)}

      {:error, _} = err ->
        err
    end
  end

  # Ids as text, from the node's charlists.
  defp handlers do
    case Checks.remote_eval(@handlers, MaxHandlers: @max_handlers, Mine: :otp_debug_mcp_telemetry) do
      {:ok, {:ok, total, rows}} ->
        {:ok, {:ok, total, for({id, e, f, w} <- rows, do: {to_string(id), e, f, w})}}

      other ->
        other
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze({total, first}, {last_total, last}, listened, sampled, samples, duration_ms) do
    rates = rates(listened, duration_ms)
    failures = failures(listened)

    handlers =
      first
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {id, rows} ->
        {_, _, fun, words} = hd(rows)
        events = Enum.map(rows, &Telemetry.event_name(elem(&1, 1)))

        %{
          id: id,
          events: events,
          function: function(fun),
          events_per_s:
            events
            |> Enum.map(&Map.get(rates, &1, 0.0))
            |> Enum.sum()
            |> Kernel.*(1.0)
            |> Float.round(1)
        }
        |> put(:local_fun, elem(fun, 0) == :local)
        |> put(:missing, missing(fun))
        |> put(:config_words, words > 10_000 && words)
      end)
      |> Enum.sort_by(&(-&1.events_per_s))

    {dispatch, sampled} = split_dispatch(sampled, samples)
    inside = inside(sampled, samples, handlers, first)

    report =
      %{
        handlers: last_total,
        handlers_at_start: total,
        attachments: length(first),
        events_with_handlers: first |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length(),
        listened_ms: duration_ms,
        busiest: Enum.take(handlers, 15)
      }
      |> put(:inside_handlers, inside != [] && inside)
      |> put(:in_telemetry_dispatch, dispatch)
      |> put(:handlers_described, total > length(handlers) && length(handlers))
      |> put(:failures, failures != [] && failures)
      |> put(:duplicates, duplicates(first))
      |> put(:id_patterns, id_patterns(first, last, total, last_total))
      |> put(:not_sampled, sample_error(sampled))

    notes =
      (failure_findings(failures) ++
         missing_findings(handlers) ++
         slow_findings(inside) ++
         dispatch_findings(dispatch, last_total) ++
         duplicate_findings(report[:duplicates]) ++
         pattern_findings(report[:id_patterns]) ++ local_findings(handlers))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp rates({:ok, report}, duration_ms) do
    Map.new(report.by_event, fn e -> {e.event, Float.round(e.count * 1000 / duration_ms, 1)} end)
  end

  defp rates(_, _), do: %{}

  defp failures({:ok, report}) do
    for %{event: "telemetry.handler.failure", groups: groups} <- report.by_event,
        g <- groups,
        do: %{count: g.count, handler: g[:key]}
  end

  defp failures(_), do: []

  defp function({:external, m, f, a, _}), do: mfa({m, f, a})
  defp function({:local, m, f, a, _}), do: "a local fun in #{module(m)} (#{f}/#{a})"

  defp missing({:external, m, _, _, :missing_module}), do: "module #{module(m)} doesn't exist"

  defp missing({:external, m, f, a, :missing_function}),
    do: "#{module(m)} doesn't export #{f}/#{a}"

  defp missing(_), do: nil

  # Processes inside each handler, on average over the samples; per event,
  # that over the events per second the handler gets.
  defp inside({:ok, samples}, count, handlers, first) when is_list(samples) do
    by_fun = Map.new(first, fn {id, _, {_, m, f, a, _}, _} -> {{m, f, a}, id} end)
    by_id = Map.new(handlers, &{&1.id, &1})

    samples
    |> List.flatten()
    |> Enum.group_by(
      fn {running, frame, _now} ->
        # The handler's id, from the backtrace or, failing that, from its
        # function's frame.
        id = running && to_string(running)
        if id && by_id[id], do: id, else: Map.get(by_fun, frame, {:frame, frame})
      end,
      &elem(&1, 2)
    )
    |> Enum.map(fn {key, nows} ->
      avg = Float.round(length(nows) / count, 2)
      h = by_id[key]
      rate = h && h.events_per_s

      %{
        handler: if(h, do: key, else: "unknown, in #{mfa(elem(key, 1))}"),
        function: if(h, do: h.function, else: mfa(elem(key, 1))),
        processes_inside_on_average: avg
      }
      |> put(:events_per_s, rate)
      |> put(:ms_per_event, rate && rate > 0 && Float.round(avg / rate * 1000, 2))
      |> put(
        :waiting_in,
        nows
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, n} -> -n end)
        |> Enum.take(3)
        |> Enum.map(fn {now, n} -> "#{mfa(now)} (#{n})" end)
      )
    end)
    |> Enum.sort_by(&(-&1.processes_inside_on_average))
    |> Enum.take(10)
  end

  defp inside(_, _, _, _), do: []

  defp sample_error({:ok, _}), do: false
  defp sample_error(other), do: Format.inspect(other, limit: 10)

  # The same function attached to the same event under several ids: it
  # runs once per id, and what it counts, it counts that many times.
  defp duplicates(rows) do
    dups =
      rows
      |> Enum.group_by(fn {_, event, {_, m, f, a, _}, _} -> {event, {m, f, a}} end, &elem(&1, 0))
      # Ten or more is a pile-up, which id_patterns reports.
      |> Enum.filter(fn {_, ids} -> length(Enum.uniq(ids)) in 2..9 end)
      |> Enum.map(fn {{event, frame}, ids} ->
        %{
          event: Telemetry.event_name(event),
          function: mfa(frame),
          ids: Enum.take(Enum.uniq(ids), 5),
          count: length(Enum.uniq(ids))
        }
      end)

    dups != [] && dups
  end

  # Ids alike but for a number, a reference or a pid: attached per process
  # or per request. With their count at the start and the end.
  defp id_patterns(first, last, total, last_total) do
    shape = fn id ->
      id
      |> String.replace(~r/#(Ref|PID|Port)<[^>]*>/, "#\\1<...>")
      |> String.replace(~r/<\d+\.\d+\.\d+>/, "<pid>")
      |> String.replace(~r/\d+/, "N")
    end

    count = fn rows ->
      rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.frequencies_by(shape)
    end

    before = count.(first)
    later = count.(last)
    # Past the handlers described, the totals say whether they grew.
    capped = length(first) < total or length(last) < last_total

    many =
      for {pattern, n} <- later, n >= 10 do
        if capped,
          do: %{
            pattern: pattern,
            handlers_described: n,
            all_handlers: last_total,
            all_at_start: total
          },
          else: %{pattern: pattern, handlers: n, at_start: Map.get(before, pattern, 0)}
      end
      |> Enum.sort_by(&(-(&1[:handlers] || &1[:handlers_described])))

    many != [] && many
  end

  # Samples in telemetry's own dispatch, apart from those in a handler:
  # how many processes on average, and in which of its functions.
  defp split_dispatch({:ok, samples}, count) when is_list(samples) do
    {dispatch, handlers} =
      Enum.map(samples, fn sample -> Enum.split_with(sample, &match?({:dispatch, _}, &1)) end)
      |> Enum.unzip()

    flat = List.flatten(dispatch)

    summary =
      flat != [] &&
        %{
          processes_on_average: Float.round(length(flat) / count, 2),
          in:
            flat
            |> Enum.frequencies_by(&mfa(elem(&1, 1)))
            |> Enum.sort_by(fn {_, n} -> -n end)
            |> Enum.take(3)
            |> Enum.map(fn {f, n} -> "#{f} (#{n})" end)
        }

    {summary, {:ok, handlers}}
  end

  defp split_dispatch(other, _count), do: {false, other}

  # -- Findings ------------------------------------------------------------------

  defp failure_findings(failures) do
    for f <- failures do
      {:critical,
       "handler #{f.handler} raised, and telemetry detached it from all its events: what it reported (metrics, logs, traces) has stopped, and nothing reattaches it"}
    end
  end

  defp missing_findings(handlers) do
    for h <- handlers, h[:missing] do
      {:warning,
       "handler #{h.id} (#{Enum.join(h.events, ", ")}) calls #{h.function}, but #{h.missing}: on its first event it will raise and be detached"}
    end
  end

  defp slow_findings(inside) do
    for i <- inside, i.processes_inside_on_average >= 0.5 do
      per =
        if i[:ms_per_event],
          do: ", about #{i.ms_per_event} ms per event (#{i.events_per_s} a second)",
          else: ""

      where = if i[:waiting_in], do: "; most in #{hd(i.waiting_in)}", else: ""

      {:warning,
       "handler #{i.handler}: on average #{i.processes_inside_on_average} processes are inside it#{per}#{where}. Handlers run in the process that emits the event, so every emitter waits for it"}
    end
  end

  defp dispatch_findings(%{processes_on_average: avg} = d, handlers) when avg >= 0.5 do
    [
      {:warning,
       "on average #{avg} processes are in telemetry's own dispatch, not in any one handler (#{Enum.join(d.in, ", ")}): with #{handlers} handlers attached, every event spends its time looking them up and going through them"}
    ]
  end

  defp dispatch_findings(_, _), do: []

  defp duplicate_findings(false), do: []
  defp duplicate_findings(nil), do: []

  defp duplicate_findings(dups) do
    for d <- dups do
      {:warning,
       "#{d.function} is attached to #{d.event} under #{d.count} ids (#{Enum.join(d.ids, ", ")}): it runs #{d.count} times per event, and what it counts is counted #{d.count} times"}
    end
  end

  defp pattern_findings(false), do: []
  defp pattern_findings(nil), do: []

  defp pattern_findings(patterns) do
    for p <- patterns do
      {n, start} =
        if p[:handlers], do: {p.handlers, p.at_start}, else: {p.all_handlers, p.all_at_start}

      growing = n > start

      many =
        if p[:handlers], do: "#{n}", else: "#{p.handlers_described} of the first #{@max_handlers}"

      {if(growing, do: :warning, else: :info),
       "#{many} handlers with ids like #{p.pattern}#{if growing, do: " (all handlers: #{start} at the start of the window, #{n} at its end)", else: ""}: attached per process or per request, and not detached; each runs on every event it's attached to"}
    end
  end

  defp local_findings(handlers) do
    case Enum.count(handlers, & &1[:local_fun]) do
      0 ->
        []

      n ->
        [
          {:info,
           "#{n} handlers are local or anonymous functions: telemetry recommends function captures (fun mod:fun/4, &Mod.fun/4), which are faster to call, and survive a reload of their module"}
        ]
    end
  end

  # -- Formatting ----------------------------------------------------------------

  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  defp level_rank(:critical), do: 0
  defp level_rank(:warning), do: 1
  defp level_rank(_), do: 2

  defp status(notes) do
    cond do
      Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
      Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
      true -> :ok
    end
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    handlers counts the handler ids attached at the end of the window
    (handlers_at_start at its start), attachments the (handler, event)
    pairs described (handlers_described when there were more than
    that). busiest are the handlers by the events a
    second they got in the window, each with its function: missing means
    it can't run (its module or function doesn't exist), so it will be
    detached on its first event; local_fun, an anonymous or local
    function. inside_handlers comes from sampling the processes' stacks
    through the window: processes_inside_on_average is how many were
    inside that handler at any moment, ms_per_event that over its events
    a second (a handler runs in the emitting process, so this is time
    every emitter spends in it), and waiting_in where they were (a
    gen_server call: the handler waits on a process; an ETS or a
    logger call: it does its work there). in_telemetry_dispatch is the
    same for processes in telemetry's own code instead, looking the
    handlers up and going through them: high when there are many
    handlers on the events. failures are handlers that
    raised in the window, now detached (earlier ones show only in the
    logs: recent_errors). duplicates are a function attached to one
    event under several ids, id_patterns ids alike but for a number, a
    ref or a pid, with their count at the start of the window: growing,
    a handler attached per process or request and never detached. Next
    step: module_code on a slow or failing handler's function;
    trace_calls on it for what it's given; telemetry on its events.
    """
  end
end
