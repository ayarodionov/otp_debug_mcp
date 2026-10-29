defmodule OtpDebugMcp.Telemetry do
  @moduledoc """
  What the node's `:telemetry` events say, over a short window: Phoenix
  requests by route, Ecto queries by table and query, Oban jobs by
  worker, HTTP client requests, each with its count, its durations
  (p50, p95, max) and its slowest example, and the errors of `exception`
  events.

  A collector process is spawned on the target from evaluated code, and
  a handler attached for the events: a fun that keeps only the small
  parts of the metadata (a conn's method, path and status, a query's SQL)
  and sends them to the collector, unless too many have been sent or the
  collector falls behind. It runs in the processes emitting the events,
  and can't fail there. The collector groups the events, and detaches the
  handler when the window ends; a janitor does if the collector is
  killed. Nothing is loaded onto the node.

  Without events given, it listens to those the node's own handlers
  listen to (Phoenix's logger, metrics reporters) and to the known events
  of the applications running there.
  """

  alias OtpDebugMcp.{Checks, Format}

  @name :otp_debug_mcp_telemetry
  @max_events 100_000

  @discover ~S"""
  case code:is_loaded(telemetry) of
    false -> not_loaded;
    _ ->
      Handlers = case catch telemetry:list_handlers([]) of L when is_list(L) -> L; _ -> [] end,
      Watched = [{E, handlers} || #{event_name := E, id := Id} <- Handlers, Id =/= Name],
      Running = [A || {A, _, _} <- application:which_applications()],
      Underscore = fun(Part) ->
        string:lowercase(re:replace(Part, "([a-z0-9])([A-Z])", "\\1_\\2", [global, {return, list}]))
      end,
      Prefix = fun(Repo) ->
        Default = [list_to_atom(Underscore(P))
                   || P <- tl(string:split(atom_to_list(Repo), ".", all))],
        case catch Repo:config() of
          C when is_list(C) -> proplists:get_value(telemetry_prefix, C, Default);
          _ -> Default
        end
      end,
      Repos = [{Prefix(M) ++ [query], ecto}
               || {M, _} <- code:all_loaded(), is_atom(M),
                  lists:prefix("Elixir.", atom_to_list(M)),
                  erlang:function_exported(M, '__adapter__', 0),
                  erlang:function_exported(M, config, 0)],
      Known = [{phoenix, [[phoenix, endpoint, stop], [phoenix, router_dispatch, stop],
                          [phoenix, router_dispatch, exception]]},
               {phoenix_live_view, [[phoenix, live_view, mount, stop], [phoenix, live_view, mount, exception],
                                    [phoenix, live_view, handle_params, stop],
                                    [phoenix, live_view, handle_event, stop],
                                    [phoenix, live_view, handle_event, exception]]},
               {oban, [[oban, job, stop], [oban, job, exception]]},
               {finch, [[finch, request, stop], [finch, request, exception]]},
               {tesla, [[tesla, request, stop], [tesla, request, exception]]},
               {absinthe, [[absinthe, execute, operation, stop]]},
               {broadway, [[broadway, processor, message, stop], [broadway, processor, message, exception]]},
               {bandit, [[bandit, request, stop], [bandit, request, exception]]},
               {cowboy_telemetry, [[cowboy, request, stop], [cowboy, request, exception]]}],
      Libraries = [{E, App} || {App, Es} <- Known, lists:member(App, Running), E <- Es],
      {ok, Watched ++ Repos ++ Libraries}
  end.
  """

  @start ~S"""
  case whereis(Name) of
    W when is_pid(W) -> already_running;
    undefined ->
      Parent = self(),
      Ref = make_ref(),
      Short = fun(B) when byte_size(B) > 400 -> <<(binary:part(B, 0, 400))/binary, "...">>;
                 (B) -> B
              end,
      Text = fun(T) -> unicode:characters_to_binary(io_lib:format("~0tP", [T, 10], [{chars_limit, 400}])) end,
      SlimValue = fun
        (_, #{'__struct__' := 'Elixir.Plug.Conn'} = C) -> {ok, maps:with([method, request_path, status, host], C)};
        (_, #{'__struct__' := 'Elixir.Oban.Job'} = J) -> {ok, maps:with([worker, queue, attempt, state], J)};
        (_, #{'__struct__' := 'Elixir.Finch.Request'} = Rq) -> {ok, maps:with([method, host, path], Rq)};
        %% A LiveView's socket, and a channel's: which view, which channel.
        (socket, #{'__struct__' := 'Elixir.Phoenix.LiveView.Socket', view := V}) -> {ok, #{view => V}};
        (socket, #{'__struct__' := 'Elixir.Phoenix.Socket'} = So) -> {ok, maps:with([channel, topic], So)};
        %% Cowboy's request.
        (K, #{method := _, path := _} = Rq) when K =:= req; K =:= partial_req ->
          {ok, maps:with([method, host, path], Rq)};
        (_, #{'__exception__' := true, '__struct__' := Mod} = E) ->
          {ok, #{exception => Mod, message => case maps:get(message, E, undefined) of
                                                  Msg when is_binary(Msg) -> Short(Msg);
                                                  _ -> undefined
                                                end}};
        (result, {ok, _}) -> {ok, ok};
        (result, {error, E}) -> {ok, {error, Text(E)}};
        (reason, V) -> {ok, Text(V)};
        %% A failed handler's id and event, as text: they're tuples and lists.
        (handler_id, V) when not is_binary(V) -> {ok, Text(V)};
        (event_name, V) when is_list(V) -> {ok, Text(V)};
        (_, V) when is_atom(V); is_number(V) -> {ok, V};
        (_, V) when is_binary(V) -> {ok, Short(V)};
        (_, _) -> skip
      end,
      Slim = fun(Md) ->
        maps:fold(fun(K, V, Acc) ->
                    case SlimValue(K, V) of {ok, S} -> Acc#{K => S}; skip -> Acc end
                  end, #{}, Md)
      end,
      Handler = fun(Event, Measurements, Metadata, {Collector, Counter, Limit}) ->
        try
          case counters:get(Counter, 1) < Limit of
            true ->
              counters:add(Counter, 1, 1),
              case erlang:process_info(Collector, message_queue_len) of
                {message_queue_len, Q} when Q < 2000 ->
                  Collector ! {event, Event, Measurements, Slim(Metadata)};
                {message_queue_len, _} -> counters:add(Counter, 2, 1);
                undefined -> ok
              end;
            false -> counters:add(Counter, 2, 1)
          end
        catch _:_ -> ok
        end
      end,
      %% What groups events: a route, a query, a worker, a controller action.
      Str = fun(V) when is_binary(V) -> V; (V) when is_atom(V) -> atom_to_binary(V); (V) -> Text(V) end,
      Mod = fun(A) -> case atom_to_binary(A) of <<"Elixir.", R/binary>> -> R; B -> B end end,
      Path = fun(P) -> re:replace(P, "/[0-9]+(?=/|$)", "/:id", [global, {return, binary}]) end,
      Key0 = fun(Md) ->
        Conn = maps:get(conn, Md, #{}),
        Method = Str(maps:get(method, Conn, <<>>)),
        case Md of
          #{route := R} when is_binary(R) -> <<Method/binary, " ", R/binary>>;
          #{source := S, query := Qr} when is_binary(Qr) ->
            Q1 = re:replace(Qr, "\\s+", " ", [global, {return, binary}]),
            <<(Str(S))/binary, ": ", (binary:part(Q1, 0, min(160, byte_size(Q1))))/binary>>;
          #{query := Qr} when is_binary(Qr) -> binary:part(Qr, 0, min(160, byte_size(Qr)));
          #{job := #{worker := Wk}} -> Str(Wk);
          #{plug := Pl, plug_opts := Op} when is_atom(Pl), is_atom(Op) ->
            <<(Str(Pl))/binary, ".", (Str(Op))/binary>>;
          #{request := #{host := H} = Rq} -> <<(Str(maps:get(method, Rq, <<>>)))/binary, " ", (Str(H))/binary>>;
          #{conn := #{request_path := P}} -> <<Method/binary, " ", (Path(P))/binary>>;
          _ -> <<>>
        end
      end,
      %% Bandit's and Cowboy's requests by path and status, failed ones by
      %% their error, Thousand Island's errors by reason; Cowboy's early
      %% errors (a request it answered before any handler) by status;
      %% shackle's events by client module; handler failures by handler.
      Key = fun([bandit, request | _], #{conn := #{request_path := P} = C}) ->
                  <<(Str(maps:get(method, C, <<>>)))/binary, " ", (Path(P))/binary, " -> ",
                    (Str(maps:get(status, C, <<"no status">>)))/binary>>;
               ([bandit | _], #{error := E}) -> <<"error: ", (Str(E))/binary>>;
               ([thousand_island | _], #{error := E}) -> Str(E);
               ([shackle | _], #{client := C}) -> Str(C);
               %% A handler that failed, and was detached: which, on what, why.
               ([telemetry, handler, failure], #{handler_id := H} = Md) ->
                  <<(Str(H))/binary, " on ", (Str(maps:get(event_name, Md, <<"?">>)))/binary, ": ",
                    (Text(maps:get(kind, Md, error)))/binary, " ", (Str(maps:get(reason, Md, <<>>)))/binary>>;
               ([cowboy, request, early_error], Md) ->
                  <<"early error -> ", (Str(maps:get(resp_status, Md, <<"no status">>)))/binary>>;
               ([cowboy, request | _], #{req := #{method := M, path := P}} = Md) ->
                  <<(Str(M))/binary, " ", (Path(P))/binary, " -> ",
                    (Str(maps:get(resp_status, Md, <<"no status">>)))/binary>>;
               %% LiveView callbacks by view (and event), channel messages by
               %% channel and event.
               ([phoenix, live_view | _], #{socket := #{view := V}} = Md) when is_atom(V) ->
                  case Md of
                    #{event := E} when is_binary(E) -> <<(Mod(V))/binary, " ", E/binary>>;
                    _ -> Mod(V)
                  end;
               ([phoenix, live_component | _], #{component := C} = Md) when is_atom(C) ->
                  case Md of
                    #{event := E} when is_binary(E) -> <<(Mod(C))/binary, " ", E/binary>>;
                    _ -> Mod(C)
                  end;
               ([phoenix, channel_handled_in], #{event := E, socket := #{channel := C}}) when is_atom(C) ->
                  <<(Mod(C))/binary, " ", (Str(E))/binary>>;
               (_, Md) -> Key0(Md)
            end,
      Times = [duration, total_time, query_time, queue_time, decode_time, idle_time],
      Add = fun({event, Event, Ms, Md}, Groups) ->
        G = maps:get({Event, Key(Event, Md)}, Groups, #{count => 0, samples => #{}, slowest => none, error => none}),
        %% Times are in native units, but shackle's reply duration is in
        %% microseconds already.
        Unit = case Event of [shackle, reply] -> microsecond; _ -> native end,
        Us = maps:from_list([{T, erlang:convert_time_unit(V, Unit, microsecond)}
                             || T <- Times, V <- [maps:get(T, Ms, none)], is_integer(V)]),
        Samples = maps:fold(fun(T, V, Acc) ->
                              {N, L} = maps:get(T, Acc, {0, []}),
                              Acc#{T => case N < 2000 of true -> {N + 1, [V | L]}; false -> {N, L} end}
                            end, maps:get(samples, G), Us),
        Main = maps:get(duration, Us, maps:get(total_time, Us, none)),
        Slowest = case {Main, maps:get(slowest, G)} of
          {none, S0} -> S0;
          {_, none} -> {Main, Md};
          {_, {Old, _}} when Main > Old -> {Main, Md};
          {_, S0} -> S0
        end,
        Error = case lists:last(Event) of
          %% Bandit's carries the error as exception, not reason.
          exception -> #{kind => maps:get(kind, Md, undefined),
                         reason => maps:get(reason, Md, maps:get(exception, Md, undefined))};
          _ -> maps:get(error, G)
        end,
        Groups#{{Event, Key(Event, Md)} => G#{count := maps:get(count, G) + 1, samples := Samples,
                                       slowest := Slowest, error := Error}}
      end,
      Collect = fun() ->
        case catch register(Name, self()) of
          true ->
            Me = self(),
            Counter = counters:new(2, []),
            Quiet = fun(#{msg := {report, #{handler_id := HId}}}, Id) when HId =:= Id -> stop;
                       (_, _) -> ignore
                    end,
            _ = logger:add_primary_filter(otp_debug_mcp_quiet, {Quiet, Name}),
            Attached = telemetry:attach_many(Name, Events, Handler, {Me, Counter, Limit}),
            _ = logger:remove_primary_filter(otp_debug_mcp_quiet),
            case Attached of
              ok ->
                spawn(fun() ->
                  MRef = erlang:monitor(process, Me),
                  receive {'DOWN', MRef, _, _, _} -> telemetry:detach(Name) end
                end),
                Parent ! {Ref, started},
                Deadline = erlang:monotonic_time(millisecond) + Duration,
                Loop = fun LoopF(Groups) ->
                  Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
                  receive
                    {event, _, _, _} = Ev -> LoopF(Add(Ev, Groups));
                    {read, From, ReadRef} ->
                      telemetry:detach(Name),
                      From ! {ReadRef, {[{E, K, G} || {{E, K}, G} <- maps:to_list(Groups)],
                                        counters:get(Counter, 1), counters:get(Counter, 2)}},
                      done;
                    _ -> LoopF(Groups)
                  after Left -> telemetry:detach(Name), expired
                  end
                end,
                Loop(#{});
              {error, Why} ->
                Parent ! {Ref, {error, Why}}
            end;
          _ ->
            Parent ! {Ref, already_running}
        end
      end,
      spawn(Collect),
      receive {Ref, Result} -> Result after 5000 -> timeout end
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
        {'DOWN', MRef, _, _, _} -> none
      after 10000 -> timeout
      end
  end.
  """

  @doc "The events worth listening to on the node, with where each comes from."
  def discover do
    case Checks.remote_eval(@discover, Name: @name) do
      {:ok, :not_loaded} -> {:error, not_loaded()}
      {:ok, {:ok, events}} -> {:ok, events |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort()}
      err -> err
    end
  end

  @doc "Listen to `events` (or the discovered ones) for `duration_ms`."
  def listen(events, duration_ms) do
    with {:ok, events} <- events_to_listen(events),
         {:ok, :started} <- start(events, duration_ms + 10_000) do
      Process.sleep(duration_ms)

      case Checks.remote_eval(@read, Name: @name) do
        {:ok, {:ok, {groups, seen, dropped}}} ->
          {:ok, report(events, groups, seen, dropped, duration_ms)}

        {:ok, :none} ->
          {:error, "the listener on the node ended early"}

        {:ok, :timeout} ->
          {:error, "the listener on the node didn't answer"}

        err ->
          err
      end
    end
  end

  defp events_to_listen(nil) do
    case discover() do
      {:ok, []} ->
        {:error,
         "no telemetry events to listen to: the node has no handlers attached and none of " <>
           "the libraries known here (Phoenix, Ecto, Oban, Finch, Tesla, Absinthe, Broadway, " <>
           "Bandit, Cowboy) running. Give the events to listen to."}

      {:ok, found} ->
        {:ok, Enum.map(found, &elem(&1, 0))}

      err ->
        err
    end
  end

  defp events_to_listen(names) do
    with {:ok, _} <- loaded() do
      {:ok, Enum.map(names, &parse_event/1)}
    end
  end

  defp loaded do
    case Checks.remote_eval("code:is_loaded(telemetry).") do
      {:ok, false} -> {:error, not_loaded()}
      {:ok, _} -> {:ok, true}
      err -> err
    end
  end

  defp not_loaded,
    do: "telemetry isn't loaded on this node, so nothing on it emits telemetry events"

  defp start(events, duration_ms) do
    bindings = [Name: @name, Events: events, Duration: duration_ms, Limit: @max_events]

    case Checks.remote_eval(@start, bindings) do
      {:ok, :started} -> {:ok, :started}
      {:ok, :already_running} -> {:error, "telemetry is already being listened to on this node"}
      {:ok, {:error, reason}} -> {:error, "couldn't attach: #{Format.inspect(reason)}"}
      {:ok, :timeout} -> {:error, "the listener didn't start within 5s"}
      err -> err
    end
  end

  @doc ~S|An event as "phoenix.router_dispatch.stop" or "[:phoenix, :router_dispatch, :stop]".|
  def parse_event(text) do
    text
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(~r/[.,\s]+/, trim: true)
    |> Enum.map(&(&1 |> String.trim_leading(":") |> String.to_atom()))
  end

  @doc "An event's name as the tool shows it: phoenix.router_dispatch.stop."
  def event_name(event), do: Enum.map_join(event, ".", &Atom.to_string/1)

  @max_groups 10

  defp report(events, groups, seen, dropped, duration_ms) do
    by_event = Enum.group_by(groups, &elem(&1, 0))

    rows =
      for {event, list} <- by_event do
        described = list |> Enum.map(&group/1) |> Enum.sort_by(&(-(&1[:total_ms] || 0)))
        total = Enum.sum(Enum.map(described, &(&1[:total_ms] || 0)))

        %{
          event: event_name(event),
          count: Enum.sum(Enum.map(described, & &1.count)),
          total_ms: Float.round(total * 1.0, 1),
          groups: Enum.take(described, @max_groups)
        }
        |> put(:more_groups, length(described) > @max_groups && length(described) - @max_groups)
      end

    {errors, rows} = Enum.split_with(rows, &String.ends_with?(&1.event, ".exception"))

    %{
      listened_ms: duration_ms,
      listened_to: Enum.map(events, &event_name/1),
      events_seen: seen,
      by_event: Enum.sort_by(rows, &(-&1.total_ms)),
      exceptions:
        for row <- errors, g <- row.groups do
          %{event: row.event, count: g.count}
          |> put(:key, g[:key])
          |> Map.merge(g[:error] || %{})
        end,
      not_seen: Enum.map(events -- Map.keys(by_event), &event_name/1)
    }
    |> put(:dropped, dropped > 0 && dropped)
    |> Map.put(:interpretation, interpretation())
  end

  defp group({_event, key, g}) do
    timings =
      Map.new(g.samples, fn {measurement, {_n, samples}} ->
        {:"#{measurement}_ms", percentiles(samples)}
      end)

    main = timings[:duration_ms] || timings[:total_time_ms]

    %{count: g.count}
    |> put(:key, key != "" && key)
    |> Map.merge(timings)
    |> put(:total_ms, main && Float.round(main.mean * g.count, 1))
    |> put(:slowest, slowest(g.slowest))
    |> put(:error, error(g.error))
  end

  defp percentiles(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(n - 1, floor(p * n))) end

    %{
      p50: ms(at.(0.5)),
      p95: ms(at.(0.95)),
      max: ms(List.last(sorted)),
      mean: Float.round(Enum.sum(sorted) / n / 1000, 2)
    }
  end

  defp ms(us), do: Float.round(us / 1000, 2)

  defp slowest(:none), do: nil
  defp slowest({us, metadata}), do: %{ms: ms(us), metadata: Format.inspect(metadata, limit: 20)}

  defp error(:none), do: nil

  defp error(%{kind: kind, reason: reason}),
    do: %{kind: Format.inspect(kind), reason: reason_text(reason)}

  defp reason_text(text) when is_binary(text), do: text

  defp reason_text(%{exception: mod, message: message}) when is_binary(message),
    do: "#{Format.inspect(mod)}: #{message}"

  defp reason_text(other), do: Format.inspect(other, limit: 10)

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    by_event is the events seen while listening, the most total time first. \
    Each event's groups split it by what it was about: a route (Phoenix), a \
    table and query (Ecto), a worker (Oban), a controller action or a host, \
    the most total time first. Times are in ms: duration_ms for spans, \
    total_time_ms for Ecto queries, which also have queue_time_ms (waiting \
    for a connection from the pool: high means the pool is too small or \
    connections are held too long), query_time_ms (in the database) and \
    decode_time_ms. p95 far above p50 means some calls are much slower \
    than most: slowest has the metadata of the slowest one. exceptions are \
    the exception events, with their kind and reason. not_seen are events \
    listened to that didn't happen in the window. Next step: trace_calls or \
    profile on the controller, worker or function behind the slowest group; \
    for Ecto, the query's indexes, or the code that runs it in a loop \
    (many fast queries from one request add up).\
    """
  end
end
