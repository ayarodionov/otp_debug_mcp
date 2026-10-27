defmodule OtpDebugMcp.Cowboy do
  @moduledoc """
  Cowboy, and the Ranch listeners under it, on a node: each listener's
  limits and connections now, the requests in flight and where they wait,
  and over a window what Ranch's counters and Cowboy's telemetry say.

  A listener is Ranch's: acceptors, and connection supervisors (one per
  acceptor unless `num_conns_sups` says otherwise), each holding its
  share of the connections. `max_connections` caps each connection
  supervisor, not the listener: past it, the supervisor stops answering
  the acceptor that brought the connection, so the acceptor waits, and
  new clients wait in the listen backlog, unaccepted. Ranch refuses
  nothing and logs nothing meanwhile.

  Cowboy runs each request in a process of its own
  (`cowboy_stream_h:request_process/3`), linked to its connection's
  process: those are the requests in flight. Grouping them by the first
  frame of the application's code shows what they wait on; those still
  there at the end of the window have run at least that long.
  """

  alias OtpDebugMcp.{Checks, Format, Telemetry}

  # Connections looked at, and requests whose stack is looked at, at most.
  @max_connections 5_000
  @max_requests 500

  @snapshot ~S"""
  case whereis(ranch_server) of
    undefined ->
      not_running;
    _ ->
      Infos = case catch ranch:info() of
        M when is_map(M) -> maps:to_list(M);
        L when is_list(L) -> [{R, maps:from_list(I)} || {R, I} <- L];
        _ -> []
      end,
      Skip = [gen, gen_server, gen_statem, proc_lib, prim_inet, inet, ssl, ssl_gen_statem, tls_sender,
              erlang, timer, lists, maps, telemetry],
      SkipPrefixes = ["cowboy", "cow_", "ranch", "Elixir.Plug", "Elixir.Phoenix", "Elixir.Enum",
                      "Elixir.Stream", "Elixir.Task", "Elixir.GenServer", "Elixir.Process"],
      AppFrame = fun(Stack) ->
        case [MFA || {Mo, F, A, _} = MFA <- Stack,
                     not lists:member(Mo, Skip),
                     not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end, SkipPrefixes),
                     F =/= module_info, is_integer(A) orelse is_list(A)] of
          [{Mo, F, A, _} | _] -> {Mo, F, case is_list(A) of true -> length(A); false -> A end};
          [] -> undefined
        end
      end,
      IsRequest = fun(P) ->
        case erlang:process_info(P, dictionary) of
          {dictionary, D} -> proplists:get_value('$initial_call', D) =:= {cowboy_stream_h, request_process, 3};
          _ -> false
        end
      end,
      Children = fun(S) -> case catch supervisor:which_children(S) of L2 when is_list(L2) -> L2; _ -> [] end end,
      %% Each connection supervisor's connections.
      PerSup = fun(Sup) ->
        case [S || {ranch_conns_sup_sup, S, _, _} <- Children(Sup)] of
          [SS] -> [proplists:get_value(active, C, 0)
                   || {_, CS, _, _} <- Children(SS),
                      C <- [catch supervisor:count_children(CS)], is_list(C)];
          _ -> []
        end
      end,
      %% Dispatch rules, compiled: [{Host, _, [{Path, _, Handler, _}]}].
      Routes = fun(Opts) ->
        D = case maps:get(env, Opts, #{}) of
          #{dispatch := {persistent_term, K}} -> persistent_term:get(K, []);
          #{dispatch := D0} -> D0;
          _ -> []
        end,
        case catch [{H, P, Hd} || {H, _, Paths} <- D, {P, _, Hd, _} <- Paths] of
          Rs when is_list(Rs) -> lists:sublist(Rs, 50);
          _ -> []
        end
      end,
      Describe = fun({Ref, I}) ->
        Conns = case catch ranch:procs(Ref, connections) of
          Cs when is_list(Cs) -> lists:sublist(Cs, MaxConns);
          _ -> []
        end,
        Acceptors = case catch ranch:procs(Ref, acceptors) of As when is_list(As) -> As; _ -> [] end,
        %% An acceptor whose connection supervisor is at max_connections
        %% waits in start_protocol for it to answer.
        Waiting = [A || A <- Acceptors,
                        erlang:process_info(A, current_function) =:= {current_function, {ranch_conns_sup, start_protocol, 3}}],
        ConnInfos = [{P, CI} || P <- Conns,
                                CI <- [erlang:process_info(P, [current_function, message_queue_len, memory, links])],
                                CI =/= undefined],
        %% Each connection with its requests: the processes linked to it
        %% that run one.
        ConnReqs = [{P, CI, [R || R <- proplists:get_value(links, CI), is_pid(R), IsRequest(R)]}
                    || {P, CI} <- ConnInfos],
        Requests = lists:sublist(lists:append([Rs || {_, _, Rs} <- ConnReqs]), MaxReqs),
        ReqInfos = [{R, proplists:delete(current_stacktrace, RI), AppFrame(proplists:get_value(current_stacktrace, RI))}
                    || R <- Requests,
                       RI <- [erlang:process_info(R, [current_function, message_queue_len, memory, current_stacktrace])],
                       RI =/= undefined],
        Opts = maps:get(protocol_options, I, #{}),
        Trans = maps:get(transport_options, I, #{}),
        {Ref,
         maps:with([status, ip, port, max_connections, active_connections, all_connections, transport,
                    protocol, metrics], I),
         case is_map(Trans) of
           true -> maps:with([num_acceptors, num_conns_sups, max_connections, handshake_timeout], Trans);
           false -> maps:from_list([{K, V} || {K, V} <- Trans, lists:member(K, [num_acceptors, max_connections])])
         end,
         case is_map(Opts) of
           true -> maps:with([idle_timeout, request_timeout, inactivity_timeout, max_keepalive,
                              stream_handlers, middlewares], Opts);
           false -> #{}
         end,
         Routes(case is_map(Opts) of true -> Opts; false -> #{} end),
         PerSup(maps:get(pid, I, undefined)),
         length(Acceptors), Waiting,
         [{P, [{requests, length(Rs)} | proplists:delete(links, CI)]} || {P, CI, Rs} <- ConnReqs],
         ReqInfos}
      end,
      {ok, [Describe(L) || L <- Infos]}
  end.
  """

  # What the window listens to: cowboy_telemetry's events.
  @events [
    "cowboy.request.stop",
    "cowboy.request.exception",
    "cowboy.request.early_error"
  ]

  @doc """
  Every Cowboy (Ranch) listener on the node, sampled at the start and the
  end of `duration_ms`, and what cowboy_telemetry says meanwhile.
  """
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_running ->
          {:error, "Ranch isn't running on this node (no ranch_server): no Cowboy listener here"}

        [] ->
          {:error, "Ranch runs on this node, but no listener has been started"}

        _ ->
          t0 = System.monotonic_time(:millisecond)
          telemetry = Telemetry.listen(@events, duration_ms)
          # Without telemetry on the node, the window is still the samples'.
          if match?({:error, _}, telemetry), do: Process.sleep(duration_ms)
          elapsed = max(System.monotonic_time(:millisecond) - t0, 1)

          with {:ok, last} <- snapshot() do
            last = if is_list(last), do: last, else: []
            listeners = Enum.map(first, &listener(&1, find(last, &1), elapsed))
            {:ok, findings(listeners, window(telemetry, elapsed, listeners), elapsed)}
          end
      end
    end
  end

  defp snapshot do
    case Checks.remote_eval(@snapshot, MaxConns: @max_connections, MaxReqs: @max_requests) do
      {:ok, {:ok, listeners}} -> {:ok, listeners}
      {:ok, :not_running} -> {:ok, :not_running}
      {:error, _} = err -> err
    end
  end

  defp find(listeners, first), do: Enum.find(listeners, &(elem(&1, 0) == elem(first, 0)))

  # -- A listener ----------------------------------------------------------------

  defp listener(first, last, elapsed) do
    {ref, info, trans, opts, routes, per_sup, acceptors, waiting, conns, requests} = first
    max = info[:max_connections]
    sups = trans[:num_conns_sups] || trans[:num_acceptors] || max(length(per_sup), 1)

    # Ranch 2 caps each connection supervisor; Ranch 1 has just one.
    limit =
      cond do
        not is_integer(max) -> :infinity
        per_sup == [] -> max
        true -> max * sups
      end

    # Still there at the end: the acceptors waited, and the requests ran,
    # through the whole window.
    {waiting_still, long_requests, rates} =
      case last do
        {_, last_info, _, _, _, _, _, last_waiting, _, last_requests} ->
          still = Enum.count(waiting, &(&1 in last_waiting))
          before = MapSet.new(requests, &elem(&1, 0))
          long = Enum.filter(last_requests, &MapSet.member?(before, elem(&1, 0)))
          {still, long, rates(info[:metrics], last_info[:metrics], elapsed)}

        nil ->
          {0, [], %{}}
      end

    %{
      listener: Format.inspect(ref),
      listening: listening(info),
      status: info[:status] || :running,
      transport: info[:transport] && Format.inspect(info[:transport]),
      protocol: info[:protocol] && Format.inspect(info[:protocol]),
      acceptors: acceptors,
      connections: %{
        active: info[:active_connections],
        all: info[:all_connections],
        limit: limit,
        max_connections: max || :unknown,
        connection_supervisors: if(per_sup == [], do: 1, else: sups),
        fullest_supervisor: Enum.max(per_sup, fn -> info[:active_connections] end),
        acceptors_waiting_for_room: length(waiting),
        acceptors_waiting_through_window: waiting_still
      },
      # Between requests: in the protocol's loop, with no request running.
      idle: Enum.count(conns, fn {_, i} -> idle?(i[:current_function]) and i[:requests] == 0 end),
      websocket: Enum.count(conns, fn {_, i} -> websocket?(i[:current_function]) end),
      requests_in_flight: length(requests),
      timeouts_ms: %{
        idle: opts[:idle_timeout] || 60_000,
        request: opts[:request_timeout] || 5_000,
        handshake: trans[:handshake_timeout] || 5_000
      },
      max_keepalive: opts[:max_keepalive] || 1_000,
      telemetry: telemetry_handler?(opts[:stream_handlers])
    }
    |> Map.merge(rates)
    |> put(:waiting_in, waiting_in(requests))
    |> put(:running_through_window, nonempty(waiting_in(long_requests), long_requests))
    |> put(:routes, routes(routes))
    |> put(:largest_connections, largest(conns))
    |> put(
      :sampled,
      length(conns) >= @max_connections && "the first #{@max_connections} connections"
    )
  end

  defp nonempty(_groups, []), do: false
  defp nonempty(groups, list), do: %{requests: length(list), in: groups || []}

  defp listening(%{ip: {:local, path}}), do: "unix:#{path}"
  defp listening(%{ip: {_, _, _, _} = ip, port: port}), do: "#{:inet.ntoa(ip)}:#{port}"

  defp listening(%{ip: {_, _, _, _, _, _, _, _} = ip, port: port}),
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp listening(%{port: port}) when is_integer(port), do: "port #{port}"
  defp listening(_), do: "not listening"

  defp idle?({m, :loop, _}) when m in [:cowboy_http, :cowboy_http2, :cowboy_http3], do: true
  defp idle?(_), do: false

  defp websocket?({:cowboy_websocket, _, _}), do: true
  defp websocket?(_), do: false

  defp telemetry_handler?(handlers) when is_list(handlers) do
    if :cowboy_telemetry_h in handlers,
      do: "cowboy_telemetry_h",
      else: "off: cowboy_telemetry_h isn't in stream_handlers, so no per-request telemetry"
  end

  defp telemetry_handler?(_), do: "off: no stream_handlers set, so no per-request telemetry"

  # Ranch 2.1+ counts each connection supervisor's accepted and
  # terminated connections.
  defp rates(before, later, elapsed) when is_map(before) and is_map(later) do
    sum = fn m, kind ->
      m |> Enum.filter(&match?({{_, _, ^kind}, _}, &1)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    end

    per_s = fn kind ->
      Float.round((sum.(later, kind) - sum.(before, kind)) * 1000 / elapsed, 1)
    end

    %{accepted_per_s: per_s.(:accept), closed_per_s: per_s.(:terminate)}
  end

  defp rates(_, _, _), do: %{}

  # Requests grouped by the function they're in and the first frame of
  # the application's code.
  defp waiting_in(requests) do
    groups =
      requests
      |> Enum.map(fn {_, info, app} -> {info[:current_function], app} end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(5)

    groups != [] &&
      for {{fun, app}, n} <- groups do
        %{requests: n, current_function: mfa(fun)}
        |> put(:in_your_code, app && app != fun && mfa(app))
      end
  end

  # Each module in its own language's syntax: Cowboy handlers are often
  # Erlang modules on an Elixir node.
  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m), do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))
  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  defp routes([]), do: false

  defp routes(routes) do
    for {host, path, handler} <- routes do
      "#{segments(host, ".")}#{segments(path, "/")} -> #{module(handler)}"
    end
  end

  defp segments(:_, _), do: "*"

  defp segments(list, sep) when is_list(list) do
    joined =
      Enum.map_join(list, sep, fn
        s when is_binary(s) -> s
        :_ -> "*"
        :... -> "..."
        a when is_atom(a) -> ":#{a}"
        other -> Format.inspect(other)
      end)

    if sep == "/", do: "/" <> joined, else: joined
  end

  defp segments(other, _), do: Format.inspect(other)

  defp largest(conns) do
    big =
      conns
      |> Enum.sort_by(fn {_, i} ->
        -max(i[:message_queue_len] || 0, div(i[:memory] || 0, 1000))
      end)
      |> Enum.take(3)
      |> Enum.filter(fn {_, i} ->
        (i[:memory] || 0) > 1_000_000 or (i[:message_queue_len] || 0) > 100
      end)

    big != [] &&
      for {pid, i} <- big do
        %{
          pid: Format.inspect(pid),
          memory_bytes: i[:memory],
          message_queue_len: i[:message_queue_len]
        }
      end
  end

  # -- The window ----------------------------------------------------------------

  defp window({:error, reason}, _elapsed, _listeners), do: %{not_listened: Format.inspect(reason)}

  defp window({:ok, report}, elapsed, _listeners) do
    events = Map.new(report.by_event, &{&1.event, &1})
    per_s = fn n -> Float.round(n * 1000 / elapsed, 1) end
    requests = Map.get(events, "cowboy.request.stop", %{groups: [], count: 0})
    early = Map.get(events, "cowboy.request.early_error", %{groups: [], count: 0})
    raised = report.exceptions |> Enum.map(& &1.count) |> Enum.sum()

    statuses =
      requests.groups
      |> Enum.group_by(&status_class/1, & &1.count)
      |> Map.new(fn {class, counts} -> {class, Enum.sum(counts)} end)
      |> then(&if(raised > 0, do: Map.put(&1, "raised", raised), else: &1))

    %{
      listened_ms: elapsed,
      requests: requests.count + raised,
      requests_per_s: per_s.(requests.count + raised),
      by_status: statuses
    }
    |> put(:slowest_routes, slowest(requests.groups))
    |> put(:early_errors, early.count > 0 && Map.new(early.groups, &{&1[:key], &1.count}))
    |> put(
      :exceptions,
      report.exceptions != [] &&
        Enum.map(report.exceptions, &Map.take(&1, [:count, :key, :kind, :reason]))
    )
    |> put(:dropped_events, report[:dropped])
  end

  defp status_class(%{key: key}) when is_binary(key) do
    case key |> String.split(" -> ") |> List.last() |> Integer.parse() do
      {code, _} -> "#{div(code, 100)}xx"
      :error -> "none"
    end
  end

  defp status_class(_), do: "none"

  defp slowest(groups) do
    top =
      groups
      |> Enum.filter(&(&1[:duration_ms] && &1[:key]))
      |> Enum.sort_by(&(-&1.duration_ms.p95))
      |> Enum.take(5)

    top != [] &&
      for g <- top do
        %{
          route: g.key,
          count: g.count,
          p50_ms: g.duration_ms.p50,
          p95_ms: g.duration_ms.p95,
          max_ms: g.duration_ms.max
        }
      end
  end

  # -- Findings ------------------------------------------------------------------

  defp findings(listeners, window, elapsed) do
    notes =
      (Enum.flat_map(listeners, &listener_findings(&1, elapsed)) ++
         window_findings(window, listeners))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    status =
      cond do
        Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
        Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
        true -> :ok
      end

    %{
      status: status,
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      listeners: listeners,
      window: window,
      interpretation: interpretation()
    }
  end

  defp level_rank(:critical), do: 0
  defp level_rank(:warning), do: 1
  defp level_rank(_), do: 2

  defp listener_findings(%{connections: c} = l, elapsed) do
    where = "#{l.listener} (#{l.listening})"
    per_sup = c.max_connections

    full =
      cond do
        c.acceptors_waiting_through_window > 0 ->
          [
            {:critical,
             "#{where}: #{c.acceptors_waiting_through_window} of #{l.acceptors} acceptors waited the whole #{elapsed} ms for room under max_connections (#{per_sup} per connection supervisor, #{c.connection_supervisors} supervisors, #{c.active} connections active): new clients wait in the listen backlog, unaccepted, until a connection closes; Ranch refuses none and logs nothing"}
          ]

        c.acceptors_waiting_for_room > 0 ->
          [
            {:warning,
             "#{where}: #{c.acceptors_waiting_for_room} of #{l.acceptors} acceptors are waiting for room under max_connections: new clients wait unaccepted meanwhile"}
          ]

        is_integer(c.limit) and is_integer(c.active) and c.active >= 0.8 * c.limit ->
          [{:warning, "#{where}: #{c.active} of #{c.limit} connections in use"}]

        is_integer(per_sup) and is_integer(c.fullest_supervisor) and
            c.fullest_supervisor >= 0.8 * per_sup ->
          [
            {:warning,
             "#{where}: a connection supervisor holds #{c.fullest_supervisor} of its #{per_sup} connections (max_connections counts per supervisor)"}
          ]

        true ->
          []
      end

    suspended =
      if l.status == :suspended,
        do: [{:warning, "#{where} is suspended: it accepts no connections"}],
        else: []

    long =
      case l[:running_through_window] do
        %{requests: n, in: [top | _]} when n > 0 ->
          [
            {:warning,
             "#{where}: #{n} requests ran through the whole #{elapsed} ms, most in #{top[:in_your_code] || top.current_function}"}
          ]

        _ ->
          []
      end

    stuck =
      case l[:waiting_in] do
        [%{requests: n} = top | _] when n >= 5 and long == [] ->
          [
            {:warning,
             "#{where}: #{n} requests in flight in #{top[:in_your_code] || top.current_function}"}
          ]

        _ ->
          []
      end

    full ++ suspended ++ long ++ stuck
  end

  defp window_findings(%{not_listened: _}, _), do: []

  defp window_findings(w, listeners) do
    server_errors = Map.get(w.by_status, "5xx", 0)
    raised = Map.get(w.by_status, "raised", 0)
    failed = server_errors + raised

    errors =
      if w.requests > 0 and failed / w.requests >= 0.05,
        do: [
          {:warning,
           "#{failed} of #{w.requests} requests failed: #{server_errors} answered 5xx, #{raised} raised in their handler (see exceptions)"}
        ],
        else: []

    early =
      case w[:early_errors] do
        m when is_map(m) ->
          [
            {:info,
             "#{m |> Map.values() |> Enum.sum()} requests answered by Cowboy before any handler (early errors: a malformed request, headers too large, a request timeout)"}
          ]

        _ ->
          []
      end

    blind =
      if w.requests == 0 and Enum.any?(listeners, &String.starts_with?(&1.telemetry, "off")),
        do: [
          {:info,
           "cowboy_telemetry_h isn't in the listeners' stream_handlers: no requests seen by status or route (recent_errors still shows handler crashes)"}
        ],
        else: []

    errors ++ early ++ blind
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    listeners are the node's Ranch listeners, sampled at the start and the
    end of the window. connections.max_connections caps each connection
    supervisor, and there are connection_supervisors of them (Ranch's
    num_conns_sups, by default one per acceptor), so limit is their
    product, and one supervisor can be full before the listener is:
    fullest_supervisor. At the cap the supervisor stops answering the
    acceptor that brought the connection: acceptors_waiting_for_room,
    and ..._through_window if they still waited at the end. Meanwhile new
    clients wait in the listen backlog, unaccepted: they see a slow
    connect or a timeout, and Ranch logs nothing. idle connections wait
    for a request (up to timeouts_ms.idle, max_keepalive requests each),
    websocket ones run a WebSocket handler. timeouts_ms.request is how
    long Cowboy waits to receive a request's headers, not a limit on the
    handler: nothing in Cowboy stops a slow handler. Each request runs in a
    process of its own: requests_in_flight, waiting_in groups them by the
    function they're in and the first frame of your own code, and
    running_through_window are those still running at the end, older than
    the window. accepted_per_s and closed_per_s are Ranch's counters
    (Ranch 2.1+). window is cowboy_telemetry's events, when
    cowboy_telemetry_h is in stream_handlers: requests by status
    (raised: the handler crashed, and Cowboy answered 500), the slowest
    routes, and early_errors, requests Cowboy answered itself before any
    handler (400 malformed, 408 request timeout, 431 headers too large).
    Next step: for waiting_in, trace_calls or profile on that function;
    for a full listener, raise max_connections (ranch:set_max_connections/2
    works live) or find what holds connections open; recent_errors for
    handler crashes.
    """
  end
end
