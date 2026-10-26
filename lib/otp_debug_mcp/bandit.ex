defmodule OtpDebugMcp.Bandit do
  @moduledoc """
  Bandit, and the Thousand Island socket server under it, on a node: each
  server's listener, limits and connections now, and over a window what
  their telemetry says.

  A server is a `ThousandIsland.Server` supervisor: an acceptor pool, each
  acceptor with a supervisor of the connections it accepted, each
  connection a process. Its configuration is the start argument of its
  listener child. A connection process waits in `gen_server:loop` between
  requests (a keep-alive), in a socket receive while it reads a request,
  and anywhere else while the plug handles one: grouping the busy ones by
  where they are shows what requests wait on.

  Thousand Island refuses a connection when an acceptor's supervisor is
  full, and only says so in telemetry (`[:thousand_island, :acceptor,
  :spawn_error]`): nothing is logged. The window listens for that, for
  Bandit's requests and exceptions, and for connections' socket errors.
  """

  alias OtpDebugMcp.{Checks, Format, Target, Telemetry}

  # Connections described one by one at most, and of those, busy ones
  # whose stack is looked at.
  @max_connections 5_000
  @max_stacks 300

  @snapshot ~S"""
  Servers = [P || P <- erlang:processes(),
                  InitialCall(P) =:= {supervisor, 'Elixir.ThousandIsland.Server', 1}],
  Children = fun(S) -> case catch supervisor:which_children(S) of L when is_list(L) -> L; _ -> [] end end,
  Skip = [gen, gen_server, gen_statem, proc_lib, prim_inet, inet, ssl, ssl_gen_statem, tls_sender,
          erlang, timer, lists, maps, telemetry],
  SkipPrefixes = ["Elixir.Bandit", "Elixir.ThousandIsland", "Elixir.Plug", "Elixir.Phoenix",
                  "Elixir.Enum", "Elixir.Stream", "Elixir.Task", "Elixir.GenServer", "Elixir.Process"],
  AppFrame = fun(Stack) ->
    case [MFA || {M, F, A, _} = MFA <- Stack,
                 not lists:member(M, Skip),
                 %% A library's modules: its own name, or under it (Bandit.*, not BanditShop).
                 not lists:any(fun(Pre) -> Name = atom_to_list(M),
                                           Name =:= Pre orelse lists:prefix(Pre ++ ".", Name)
                               end, SkipPrefixes),
                 F =/= module_info, is_integer(A) orelse is_list(A)] of
      [{M, F, A, _} | _] -> {M, F, case is_list(A) of true -> length(A); false -> A end};
      [] -> undefined
    end
  end,
  Describe = fun(Sup) ->
    Kids = Children(Sup),
    Config = case catch supervisor:get_childspec(Sup, listener) of
      {ok, #{start := {_, _, [C | _]}}} -> C;
      _ -> undefined
    end,
    Listen = case catch 'Elixir.ThousandIsland':listener_info(Sup) of
      {ok, L} -> L;
      _ -> undefined
    end,
    Pool = [Pid || {acceptor_pool_supervisor, Pid, _, _} <- Kids, is_pid(Pid)],
    AcceptorSups = lists:append([[A || {_, A, supervisor, _} <- Children(P), is_pid(A)] || P <- Pool]),
    ConnSups = lists:append([[C || {_, C, supervisor, _} <- Children(A), is_pid(C)] || A <- AcceptorSups]),
    %% An acceptor whose connection supervisor is full waits, retrying,
    %% before it refuses the connection: meanwhile nothing is accepted.
    Acceptors = lists:append([[W || {_, W, worker, _} <- Children(A), is_pid(W)] || A <- AcceptorSups]),
    WaitingForRoom = length([W || W <- Acceptors,
                                  {current_stacktrace, St} <- [erlang:process_info(W, current_stacktrace)],
                                  lists:keymember(start_child_with_retry, 2, St)]),
    PerAcceptor = [N || C <- ConnSups,
                        N <- [case catch supervisor:count_children(C) of
                                L2 when is_list(L2) -> proplists:get_value(active, L2, 0);
                                _ -> 0
                              end]],
    Conns = lists:sublist(lists:append([[P || {_, P, _, _} <- Children(C), is_pid(P)] || C <- ConnSups]), MaxConns),
    Infos = [{P, I} || P <- Conns,
                       I <- [erlang:process_info(P, [current_function, message_queue_len, memory])],
                       I =/= undefined],
    Busy = [P || {P, I} <- Infos,
                 not lists:member(proplists:get_value(current_function, I),
                                  [{gen_server, loop, 7}, {gen_server, loop, 6}, {gen_server, loop, 5}])],
    Stacks = [{P, AppFrame(S)} || P <- lists:sublist(Busy, MaxStacks),
                                  {current_stacktrace, S} <- [erlang:process_info(P, current_stacktrace)]],
    {Sup, Config, Listen, length(AcceptorSups), PerAcceptor, length(Conns), Infos, Stacks, WaitingForRoom}
  end,
  [Describe(S) || S <- Servers].
  """

  # What the window listens to.
  @events [
    "bandit.request.stop",
    "bandit.request.exception",
    "bandit.websocket.stop",
    "thousand_island.acceptor.spawn_error",
    "thousand_island.connection.start",
    "thousand_island.connection.recv_error",
    "thousand_island.connection.send_error"
  ]

  @doc """
  Every Bandit (Thousand Island) server on the node, and over `duration_ms`
  what their telemetry says: requests, refused connections, socket errors.
  """
  def report(duration_ms) do
    with {:ok, servers} <-
           Checks.remote_eval(Checks.supervisor_funs() <> @snapshot,
             MaxConns: @max_connections,
             MaxStacks: @max_stacks
           ) do
      case servers do
        [] ->
          {:error,
           "no Bandit or Thousand Island server runs on this node (none of its processes " <>
             "is a ThousandIsland.Server supervisor)"}

        _ ->
          servers = Enum.map(servers, &server/1)
          window = window(duration_ms)
          {:ok, findings(servers, window)}
      end
    end
  end

  # -- A server now --------------------------------------------------------------

  defp server({sup, config, listen, acceptors, per_acceptor, conn_count, infos, stacks, waiting}) do
    # A ThousandIsland.ServerConfig struct, whose module this node lacks.
    config = if is_map(config), do: Map.delete(config, :__struct__), else: %{}
    per_acceptor_limit = config[:num_connections]
    num_acceptors = config[:num_acceptors] || acceptors

    limit =
      case per_acceptor_limit do
        n when is_integer(n) -> n * num_acceptors
        _ -> :infinity
      end

    active = Enum.sum(per_acceptor)
    busy_states = classify(infos)

    %{
      server: Format.inspect(sup),
      listening: listening(listen),
      transport: short_module(config[:transport_module]),
      serves: plug(config[:handler_options]),
      acceptors: acceptors,
      connections: %{
        active: active,
        limit: limit,
        per_acceptor_limit: per_acceptor_limit || :unknown,
        fullest_acceptor: Enum.max(per_acceptor, fn -> 0 end),
        acceptors_waiting_for_room: waiting
      },
      idle: busy_states.idle,
      reading: busy_states.reading,
      sending: busy_states.sending,
      handling: busy_states.handling,
      timeouts_ms: %{
        read: config[:read_timeout],
        handshake: config[:handshake_timeout],
        shutdown: config[:shutdown_timeout]
      }
    }
    |> put(:waiting_in, waiting_in(infos, stacks))
    |> put(:largest_connections, largest(infos))
    |> put(
      :sampled,
      conn_count >= @max_connections && "the first #{@max_connections} connections"
    )
  end

  defp listening({{_, _, _, _} = ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"
  defp listening({{_, _, _, _, _, _, _, _} = ip, port}), do: "[#{:inet.ntoa(ip)}]:#{port}"
  defp listening({:local, path}), do: "unix:#{path}"
  defp listening(nil), do: "not listening: suspended"
  defp listening(:undefined), do: "not listening: suspended"
  defp listening(other), do: Format.inspect(other)

  defp short_module(nil), do: nil
  defp short_module(mod), do: Format.inspect(mod)

  defp plug(%{plug: {mod, _opts}}), do: Format.inspect(mod)
  defp plug(%{plug: mod}) when is_atom(mod), do: Format.inspect(mod)
  defp plug(_), do: nil

  # A connection between requests waits in gen_server:loop; reading a
  # request, in a socket receive; sending a response, in a socket send.
  defp classify(infos) do
    Enum.reduce(infos, %{idle: 0, reading: 0, sending: 0, handling: 0}, fn {_pid, info}, acc ->
      Map.update!(acc, state(info[:current_function]), &(&1 + 1))
    end)
  end

  defp state({:gen_server, :loop, _}), do: :idle

  defp state({m, f, _})
       when m in [:prim_inet, :inet, :gen_tcp, :ssl, :ssl_gen_statem, :tls_sender] do
    if f |> Atom.to_string() |> String.contains?("send"), do: :sending, else: :reading
  end

  defp state(_), do: :handling

  # Busy connections grouped by where they are: the function, and the
  # first frame of the application's own code under it.
  defp waiting_in(infos, stacks) do
    frames = Map.new(stacks)

    groups =
      for {pid, info} <- infos, state(info[:current_function]) == :handling do
        {info[:current_function], Map.get(frames, pid)}
      end
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(5)

    groups != [] &&
      for {{fun, app}, n} <- groups do
        %{connections: n, current_function: mfa(fun)}
        |> put(:in_your_code, app && app != fun && mfa(app))
      end
  end

  # A function as the target's language writes it.
  defp mfa({m, f, a}) do
    case Target.syntax(Target.connected_node()) do
      :erlang -> "#{m}:#{f}/#{a}"
      _ -> "#{Format.inspect(m)}.#{f}/#{a}"
    end
  end

  defp mfa(other), do: Format.inspect(other)

  defp largest(infos) do
    big =
      infos
      |> Enum.sort_by(fn {_, i} -> -(i[:memory] || 0) end)
      |> Enum.take(3)
      |> Enum.filter(fn {_, i} -> (i[:memory] || 0) > 1_000_000 end)

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

  defp window(duration_ms) do
    case Telemetry.listen(@events, duration_ms) do
      {:ok, report} -> summarize(report, duration_ms)
      {:error, reason} -> %{not_listened: Format.inspect(reason)}
    end
  end

  defp summarize(report, duration_ms) do
    events = Map.new(report.by_event, &{&1.event, &1})
    per_s = fn n -> Float.round(n * 1000 / duration_ms, 1) end
    count = fn name -> get_in(events, [name, :count]) || 0 end

    requests = Map.get(events, "bandit.request.stop", %{groups: [], count: 0})

    {ok, failed} =
      Enum.split_with(requests.groups, &(&1[:key] && String.contains?(&1.key, " -> ")))

    # A request whose plug raised ends with an exception event, no stop.
    raised = report.exceptions |> Enum.map(& &1.count) |> Enum.sum()

    statuses =
      ok
      |> Enum.group_by(&status_class/1, & &1.count)
      |> Map.new(fn {class, counts} -> {class, Enum.sum(counts)} end)
      |> then(&if(raised > 0, do: Map.put(&1, "raised", raised), else: &1))

    refused = Map.get(events, "thousand_island.acceptor.spawn_error", %{groups: []})

    %{
      listened_ms: duration_ms,
      requests: requests.count + raised,
      requests_per_s: per_s.(requests.count + raised),
      by_status: statuses,
      new_connections_per_s: per_s.(count.("thousand_island.connection.start")),
      refused_connections: refused_count(refused.groups),
      websockets_closed: count.("bandit.websocket.stop")
    }
    |> put(:slowest_routes, slowest(ok))
    |> put(
      :failed_requests,
      failed != [] && Enum.map(failed, &%{error: &1[:key], count: &1.count})
    )
    |> put(:spawn_errors, spawn_errors(refused.groups))
    |> put(:receive_errors, reasons(events["thousand_island.connection.recv_error"]))
    |> put(:send_errors, reasons(events["thousand_island.connection.send_error"]))
    |> put(
      :exceptions,
      report.exceptions != [] &&
        Enum.map(report.exceptions, &Map.take(&1, [:count, :key, :kind, :reason]))
    )
    |> put(:dropped_events, report[:dropped])
  end

  defp status_class(%{key: key}) do
    case key |> String.split(" -> ") |> List.last() |> Integer.parse() do
      {code, _} -> "#{div(code, 100)}xx"
      :error -> "none"
    end
  end

  defp slowest(groups) do
    top =
      groups
      |> Enum.filter(& &1[:duration_ms])
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

  # A refusal at the limit carries no error; other spawn failures do.
  defp refused_count(groups),
    do: groups |> Enum.reject(& &1[:key]) |> Enum.map(& &1.count) |> Enum.sum()

  defp spawn_errors(groups) do
    errors = Enum.filter(groups, & &1[:key])
    errors != [] && Enum.map(errors, &%{error: &1.key, count: &1.count})
  end

  defp reasons(nil), do: false
  defp reasons(%{groups: groups}), do: Map.new(groups, &{&1[:key] || "unknown", &1.count})

  # -- Findings ------------------------------------------------------------------

  defp findings(servers, window) do
    notes =
      (Enum.flat_map(servers, &server_findings/1) ++ window_findings(window))
      |> Enum.sort_by(fn {level, _} -> if level == :critical, do: 0, else: 1 end)

    status =
      cond do
        Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
        Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
        true -> :ok
      end

    %{
      status: status,
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      servers: servers,
      window: window,
      interpretation: interpretation()
    }
  end

  defp server_findings(%{connections: c} = s) do
    near_limit =
      case {c.limit, c.per_acceptor_limit} do
        {limit, per} when is_integer(limit) and is_integer(per) ->
          cond do
            c.active >= 0.8 * limit ->
              [{:warning, "#{s.listening}: #{c.active} of #{limit} connections in use"}]

            per > 0 and c.fullest_acceptor >= 0.8 * per ->
              [
                {:warning,
                 "#{s.listening}: an acceptor has #{c.fullest_acceptor} of its #{per} connections"}
              ]

            true ->
              []
          end

        _ ->
          []
      end

    suspended =
      if String.starts_with?(s.listening, "not listening"),
        do: [{:warning, "#{s.server} isn't accepting connections: suspended"}],
        else: []

    stuck =
      case s[:waiting_in] do
        [%{connections: n} = top | _] when n >= 5 ->
          [
            {:warning,
             "#{s.listening}: #{n} connections busy in #{top[:in_your_code] || top.current_function}"}
          ]

        _ ->
          []
      end

    waiting =
      if c.acceptors_waiting_for_room > 0,
        do: [
          {:warning,
           "#{s.listening}: #{c.acceptors_waiting_for_room} of #{s.acceptors} acceptors are waiting for room for a new connection: meanwhile new clients wait unaccepted, and are refused if no room comes"}
        ],
        else: []

    near_limit ++ waiting ++ suspended ++ stuck
  end

  defp window_findings(%{not_listened: _}), do: []

  defp window_findings(w) do
    refused =
      if w.refused_connections > 0,
        do: [
          {:critical,
           "#{w.refused_connections} connections refused in #{w.listened_ms} ms: the connection limit was reached (nothing logs this)"}
        ],
        else: []

    server_errors = Map.get(w.by_status, "5xx", 0)
    raised = Map.get(w.by_status, "raised", 0)
    failed = server_errors + raised

    errors =
      if w.requests > 0 and failed / w.requests >= 0.05,
        do: [
          {:warning,
           "#{failed} of #{w.requests} requests failed: #{server_errors} answered 5xx, #{raised} raised (see exceptions)"}
        ],
        else: []

    refused ++ errors
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    servers are the node's Bandit (Thousand Island) servers now:
    connections.limit is acceptors × per_acceptor_limit (Thousand
    Island's num_acceptors × num_connections), and each acceptor's
    connections are capped at per_acceptor_limit, so fullest_acceptor can
    reach its cap before the total does. acceptors_waiting_for_room are
    acceptors retrying for a slot in a full acceptor (max_connections_retry_count
    times, max_connections_retry_wait apart): while they do, new clients
    wait in the listen queue, the seconds before the first byte that a
    client sees. Connections are idle (a
    keep-alive between requests), reading a request, sending a response,
    or handling one in the plug; waiting_in groups the handling ones by
    the function they're in and the first frame of your own code: many in
    one place is what requests wait on (an upstream call, a pool
    checkout, a GenServer call). window is the telemetry over the listened
    time: requests by status (raised: the plug raised, and Bandit
    answered 500 if it still could), the slowest routes, and
    refused_connections, connections Thousand Island closed at accept
    because an acceptor was full. Clients see those as connection resets,
    and nothing is logged. receive_errors by reason: timeout means a
    client too slow or idle past read_timeout, closed one that hung up.
    Next step: for waiting_in, trace_calls or profile on that function;
    for refused connections, raise num_connections (thousand_island_options
    in the endpoint's config) or find what holds connections; telemetry
    for more detail on the routes.
    """
  end
end
