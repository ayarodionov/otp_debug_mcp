defmodule OtpDebugMcp.Postgrex do
  @moduledoc """
  Postgrex connection pools on a node (Ecto's repos among them), sampled
  at the start and the end of a window: each pool's connections, up or
  reconnecting, idle or checked out; who holds each checked-out one and
  where in their code; and the callers waiting for one, how long, and
  from where. With `server: true`, the server's side too, through a
  connection of its own: what each backend is doing, transactions left
  open, and queries waiting for a lock another holds.

  A pool is DBConnection's: a pool process queueing checkouts, and a
  connection process per connection. A connection's state lives in a
  public ETS table (its holder) whose heir is the pool: owned by the pool
  while idle, by the caller while checked out. So all of it is read
  without asking the pool or a connection anything. A caller holds its
  connection for a whole transaction: slow work inside one (a call out,
  a sleep, a big loop) keeps the connection from everyone else, and the
  rows it wrote locked on the server.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Waiting callers and connections described per pool, at most.
  @max_rows 500

  @snapshot ~S"""
  case whereis('Elixir.DBConnection.ConnectionPool.Supervisor') of
    undefined ->
      not_running;
    Sup ->
      Now = erlang:monotonic_time(),
      Ms = fun(Native) -> erlang:convert_time_unit(Now - Native, native, millisecond) end,
      Tables = [{T, ets:info(T, name), ets:info(T, owner), ets:info(T, heir)}
                || T <- ets:all(),
                   lists:member(ets:info(T, name), ['Elixir.DBConnection.ConnectionPool.Queue',
                                                    'Elixir.DBConnection.Holder'])],
      Skip = [gen, gen_server, gen_statem, proc_lib, erlang, lists, maps, timer, prim_inet, inet,
              gen_tcp, ssl, ets],
      Prefixes = ["Elixir.DBConnection", "Elixir.Postgrex", "Elixir.Ecto", "Elixir.Enum",
                  "Elixir.Process", "Elixir.Task", "Elixir.GenServer", "Elixir.Stream"],
      AppFrame = fun(Stack) ->
        case [MFA || {Mo, F, A, _} = MFA <- Stack,
                     not lists:member(Mo, Skip),
                     not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end, Prefixes),
                     F =/= module_info, is_integer(A) orelse is_list(A)] of
          [{Mo, F, A, _} | _] -> {Mo, F, case is_list(A) of true -> length(A); false -> A end};
          [] -> undefined
        end
      end,
      %% The current stacktrace stops at 8 frames, and a caller in a query
      %% is deep in Postgrex and DBConnection: then its backtrace, whole.
      Deep = fun(P) ->
        case erlang:process_info(P, backtrace) of
          {backtrace, Bt} ->
            Frames = case re:run(Bt, "\\('?([^':()\\s]+)'?:'?([^'/\\s]+)'?/(\\d+) \\+",
                                  [global, {capture, all_but_first, list}]) of
              {match, L} -> [{list_to_atom(M), list_to_atom(F), list_to_integer(A), []} || [M, F, A] <- L];
              nomatch -> []
            end,
            AppFrame(Frames);
          _ -> undefined
        end
      end,
      Where = fun(P) ->
        case erlang:process_info(P, [current_stacktrace, current_function]) of
          [{current_stacktrace, St}, {current_function, CF}] ->
            case AppFrame(St) of
              undefined -> {Deep(P), CF};
              App -> {App, CF}
            end;
          _ -> undefined
        end
      end,
      Safe = [hostname, port, database, username, socket_dir, pool_size, queue_target,
              queue_interval, timeout, idle_interval],
      Pool = fun(PoolSup) ->
        Kids = [{Id, C} || {Id, C, _, _} <- (catch supervisor:which_children(PoolSup)), is_pid(C)],
        Spec = case Kids of
          [{Id0, _} | _] -> catch supervisor:get_childspec(PoolSup, Id0);
          [] -> none
        end,
        case Spec of
          {ok, #{start := {_, _, [Mod, Opts, PoolPid, _Tag]}}} when is_pid(PoolPid) ->
            Name = case erlang:process_info(PoolPid, registered_name) of
              {registered_name, N} when is_atom(N) -> N;
              _ -> undefined
            end,
            Queue = [T || {T, 'Elixir.DBConnection.ConnectionPool.Queue', O, _} <- Tables, O =:= PoolPid],
            Entries = case Queue of
              [Q] -> case ets:select(Q, [{'_', [], ['$_']}], MaxRows) of {L, _} -> L; _ -> [] end;
              _ -> []
            end,
            %% A waiting caller's time is in milliseconds (DBConnection's
            %% checkout), an idle connection's in native units.
            NowMs = erlang:monotonic_time(millisecond),
            Waiting = [{Pid, NowMs - Time, Where(Pid)} || {{Time, _, {Pid, _}}} <- Entries, is_pid(Pid)],
            Idle = length([x || {{_, _}} <- Entries]),
            Holders = [begin
                         Owner = ets:info(T, owner),
                         {ConnPid, State, ConnectedAt} = case catch ets:lookup(T, conn) of
                           [C] when is_tuple(C), tuple_size(C) >= 6 -> {element(2, C), element(4, C), element(6, C)};
                           _ -> {undefined, undefined, undefined}
                         end,
                         Pg = case State of
                           #{'__struct__' := 'Elixir.Postgrex.Protocol'} = S ->
                             {maps:get(connection_id, S, undefined), maps:get(peer, S, undefined),
                              maps:get(postgres, S, undefined),
                              %% Parameters: a map, or a reference into Postgrex's table.
                              case maps:get(parameters, S, #{}) of
                                M when is_map(M) -> maps:get(<<"server_version">>, M, undefined);
                                Ref -> case catch ets:lookup_element('Elixir.Postgrex.Parameters', Ref, 2) of
                                         M2 when is_map(M2) -> maps:get(<<"server_version">>, M2, undefined);
                                         _ -> undefined
                                       end
                              end};
                           _ -> undefined
                         end,
                         Out = Owner =/= PoolPid andalso Owner =/= ConnPid,
                         {ConnPid, Out, case Out of true -> {Owner, Where(Owner)}; false -> idle end, Pg,
                          case is_integer(ConnectedAt) of true -> Ms(ConnectedAt); false -> undefined end}
                       end || {T, 'Elixir.DBConnection.Holder', _, H} <- Tables, H =:= PoolPid],
            Connected = [C || {C, _, _, _, _} <- Holders],
            Down = [C || {_, C} <- Kids, not lists:member(C, Connected)],
            {PoolPid, Name, Mod, [{K, V} || {K, V} <- Opts, lists:member(K, Safe)], length(Kids),
             lists:sublist(Waiting, MaxRows), Idle, lists:sublist(Holders, MaxRows),
             [{C, catch erlang:process_info(C, current_function)} || C <- Down],
             element(2, erlang:process_info(PoolPid, message_queue_len))};
          _ ->
            none
        end
      end,
      {ok, [P || {_, PS, _, _} <- supervisor:which_children(Sup), is_pid(PS), P <- [Pool(PS)], P =/= none]}
  end.
  """

  # The server's side, through a connection of the pool's own options
  # (opened here, used for two queries, closed): each backend of this
  # database, its state, transaction and state ages, wait, query, and the
  # backends blocking it.
  @server ~S"""
  Sup = 'Elixir.DBConnection.ConnectionPool.Supervisor',
  %% The first pool's options, from its first connection's child spec.
  Specs = [Spec || {_, PS, _, _} <- supervisor:which_children(Sup), is_pid(PS),
                   [{Id, _, _, _} | _] <- [supervisor:which_children(PS)],
                   {ok, Spec} <- [catch supervisor:get_childspec(PS, Id)]],
  case [O || #{start := {_, _, [_, O, _, _]}} <- Specs] of
    [O | _] ->
      Clean = [{K, V} || {K, V} <- O, not lists:member(K, [name, pool, pool_size, pool_index,
                                                             after_connect, configure, backoff_type])]
              ++ [{pool_size, 1}, {backoff_type, stop}],
      process_flag(trap_exit, true),
      case catch 'Elixir.Postgrex':start_link(Clean) of
        {ok, Conn} ->
          Sql = <<"SELECT pid, state, wait_event_type, wait_event, "
                  "extract(epoch from now() - xact_start)::float8, "
                  "extract(epoch from now() - state_change)::float8, "
                  "left(query, 300), pg_blocking_pids(pid) "
                  "FROM pg_stat_activity WHERE datname = current_database() "
                  "AND pid <> pg_backend_pid() AND backend_type = 'client backend'">>,
          R = (catch 'Elixir.Postgrex':query(Conn, Sql, [], [{timeout, 5000}])),
          catch gen_server:stop(Conn),
          case R of
            {ok, #{rows := Rows}} -> {ok, Rows};
            Other -> {error, Other}
          end;
        Other ->
          {error, Other}
      end;
    [] ->
      {error, no_pool}
  end.
  """

  @doc "The node's Postgrex pools, sampled `duration_ms` apart, and the server if asked."
  def report(duration_ms, opts \\ []) do
    case snapshot() do
      {:ok, :not_running} ->
        {:error,
         "no DBConnection pool runs on this node (no DBConnection.ConnectionPool.Supervisor): " <>
           "Postgrex, or Ecto's Postgres adapter, isn't started"}

      {:ok, {:ok, []}} ->
        {:error, "DBConnection runs on this node, but no pool has been started"}

      {:ok, {:ok, first}} ->
        t0 = System.monotonic_time(:millisecond)
        Process.sleep(duration_ms)

        with {:ok, {:ok, last}} <- snapshot() do
          elapsed = System.monotonic_time(:millisecond) - t0
          server = if opts[:server], do: server(), else: nil
          {:ok, analyze(first, last, server, elapsed)}
        end

      {:ok, other} ->
        {:error, Format.inspect(other)}

      {:error, _} = err ->
        err
    end
  end

  defp snapshot, do: Checks.remote_eval(@snapshot, MaxRows: @max_rows)

  defp server do
    case Checks.remote_eval(@server) do
      {:ok, {:ok, rows}} -> {:ok, rows}
      {:ok, {:error, reason}} -> {:error, Format.inspect(reason, limit: 15)}
      {:error, reason} -> {:error, Format.inspect(reason, limit: 15)}
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(first, last, server, elapsed) do
    by_pid = Map.new(last, &{elem(&1, 0), &1})
    backends = backends(server)

    pools =
      for p <- first do
        pool(p, Map.get(by_pid, elem(p, 0), p), backends)
      end

    notes =
      (Enum.flat_map(pools, &pool_findings(&1, elapsed)) ++ server_findings(backends, pools))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    %{
      status: status(notes),
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      pools: pools,
      listened_ms: elapsed
    }
    |> put(:server, server_report(server, backends))
    |> Map.put(:interpretation, interpretation())
  end

  defp pool({pid, name, mod, opts, size, waiting, idle, holders, down, mailbox}, last, backends) do
    {_, _, _, _, _, last_waiting, last_idle, last_holders, last_down, _} = last
    opts = Map.new(opts)

    held_before = MapSet.new(for {c, true, {owner, _}, _, _} <- holders, do: {c, owner})

    # Checked out at both samples, by the same caller: held through the window.
    held_through =
      for {c, true, {owner, where}, _, _} <- last_holders,
          MapSet.member?(held_before, {c, owner}),
          do: {owner, where}

    out =
      for {conn, true, {owner, where}, pg, _} <- last_holders do
        {backend, _peer, pg_status, _} = pg_parts(pg)

        %{
          connection: Format.inspect(conn),
          held_by: Format.inspect(owner),
          in_your_code: location(where)
        }
        |> put(:in_transaction, pg_status == :transaction)
        |> put(:running_a_query, running_a_query?(where))
        |> put(:backend_pid, backend)
        |> put(:server, backend && server_state(backends[backend]))
      end

    waiters = Enum.sort_by(last_waiting, &(-elem(&1, 1)))

    {_, peer, _, version} =
      holders |> Enum.map(&pg_parts(elem(&1, 3))) |> Enum.find({nil, nil, nil, nil}, & &1)

    %{
      pool: if(name != :undefined, do: Format.inspect(name), else: Format.inspect(pid)),
      module: Format.inspect(mod),
      database: opts[:database],
      server_address:
        peer_text(peer) || "#{opts[:hostname] || opts[:socket_dir]}:#{opts[:port] || 5432}",
      pool_size: size,
      connections: %{
        up: length(last_holders),
        idle: last_idle,
        checked_out: length(out),
        down: length(last_down)
      },
      callers_waiting: length(last_waiting),
      queue_target_ms: opts[:queue_target] || 50,
      queue_interval_ms: opts[:queue_interval] || 1000
    }
    |> put(:server_version, version)
    |> put(:waiting_at_start, length(waiting))
    |> put(:idle_at_start, idle)
    |> put(:longest_wait_ms, waiters != [] && elem(hd(waiters), 1))
    |> put(:waiting_in, groups(Enum.map(waiters, &location(elem(&1, 2)))))
    |> put(:checked_out, out != [] && Enum.take(out, 20))
    |> put(
      :held_through_window,
      held_through != [] && groups(Enum.map(held_through, &location(elem(&1, 1))))
    )
    |> put(
      :down,
      down != [] &&
        Enum.map(last_down, fn {c, cf} -> "#{Format.inspect(c)} in #{cf_text(cf)}" end)
    )
    |> put(:pool_mailbox, mailbox > 100 && mailbox)
  end

  defp pg_parts({backend, peer, status, version}), do: {backend, peer, status, version}
  defp pg_parts(_), do: {nil, nil, nil, nil}

  defp peer_text({{_, _, _, _} = ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"
  defp peer_text(_), do: nil

  defp cf_text({:current_function, mfa}), do: mfa(mfa)
  defp cf_text(other), do: Format.inspect(other)

  # A caller holding a connection is running a query when it's inside
  # Postgrex or DBConnection, or on the socket.
  defp running_a_query?({_app, {m, _, _}}) do
    name = Atom.to_string(m)

    String.starts_with?(name, "Elixir.Postgrex") or
      String.starts_with?(name, "Elixir.DBConnection") or
      m in [:prim_inet, :gen_tcp, :inet, :ssl]
  end

  defp running_a_query?(_), do: false

  defp groups([]), do: false

  defp groups(list) do
    list
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.map(fn {loc, n} -> "#{loc} (#{n})" end)
  end

  defp location({:undefined, cf}), do: "#{mfa(cf)} (no frame of your code)"
  defp location({app, cf}) when app == cf, do: mfa(app)
  defp location({app, cf}), do: "#{mfa(app)}, now in #{mfa(cf)}"
  defp location(_), do: "unknown"

  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- The server ----------------------------------------------------------------

  defp backends({:ok, rows}) do
    Map.new(rows, fn [pid, state, wtype, wevent, xact, since, query, blockers] ->
      {pid,
       %{
         backend_pid: pid,
         state: state,
         transaction_s: xact && Float.round(xact, 1),
         in_state_s: since && Float.round(since, 1),
         waiting_for: wtype && "#{wtype}/#{wevent}",
         query: query,
         blocked_by: blockers || []
       }}
    end)
  end

  defp backends(_), do: %{}

  defp server_state(nil), do: nil

  defp server_state(b) do
    "#{b.state}#{if b.transaction_s, do: ", transaction open #{b.transaction_s} s", else: ""}#{if b.blocked_by != [], do: ", blocked by backend #{Enum.join(b.blocked_by, ", ")}", else: ""}"
  end

  defp server_report(nil, _), do: false
  defp server_report({:error, reason}, _), do: %{not_read: reason}

  defp server_report({:ok, _}, backends) do
    %{
      backends: map_size(backends),
      idle_in_transaction:
        backends |> Map.values() |> Enum.filter(&(&1.state == "idle in transaction")) |> length(),
      blocked: backends |> Map.values() |> Enum.filter(&(&1.blocked_by != [])) |> Enum.take(10)
    }
  end

  # -- Findings ------------------------------------------------------------------

  defp pool_findings(p, elapsed) do
    where = "pool #{p.pool} (#{p.database} on #{p.server_address})"
    c = p.connections

    exhausted =
      if p.callers_waiting > 0 and c.idle == 0,
        do: [
          {if(p[:waiting_at_start] && p.waiting_at_start > 0, do: :critical, else: :warning),
           "#{where}: #{p.callers_waiting} callers waiting for a connection, the longest #{p[:longest_wait_ms]} ms, with all #{c.up} up checked out#{if p[:waiting_in], do: "; they wait in #{hd(p.waiting_in)}", else: ""}. Past queue_target (#{p.queue_target_ms} ms) for a whole queue_interval (#{p.queue_interval_ms} ms), DBConnection drops queued checkouts: \"connection not available and request was dropped from queue\""}
        ],
        else: []

    held =
      case p[:held_through_window] do
        [top | _] = list ->
          n = length(list)

          [
            {:warning,
             "#{where}: connections were held by the same caller through the whole #{elapsed} ms, most in #{top}#{if n > 1, do: " (#{n} places)", else: ""}: a connection is held for a whole transaction, and nobody else can use it meanwhile"}
          ]

        _ ->
          []
      end

    idle_in_tx =
      case Enum.filter(
             p[:checked_out] || [],
             &(&1[:in_transaction] == true and &1[:running_a_query] != true)
           ) do
        [] ->
          []

        list ->
          [
            {:warning,
             "#{where}: #{length(list)} checked-out connections are in a transaction while their callers do something else (#{list |> Enum.map(& &1.in_your_code) |> Enum.uniq() |> Enum.take(3) |> Enum.join("; ")}): the rows they wrote stay locked on the server meanwhile"}
          ]
      end

    down =
      if c.down > 0,
        do: [
          {if(c.up == 0, do: :critical, else: :warning),
           "#{where}: #{c.down} of #{p.pool_size} connections are down, reconnecting (the server unreachable, refusing, or out of connections)"}
        ],
        else: []

    exhausted ++ held ++ idle_in_tx ++ down
  end

  defp server_findings(backends, _pools) when map_size(backends) == 0, do: []

  defp server_findings(backends, pools) do
    owner_of =
      for p <- pools, o <- p[:checked_out] || [], o[:backend_pid], into: %{} do
        {o.backend_pid, "#{o.held_by} in #{o.in_your_code}"}
      end

    blocked =
      for b <- Map.values(backends), b.blocked_by != [] do
        holders =
          Enum.map_join(
            b.blocked_by,
            "; ",
            &"backend #{&1}#{if owner_of[&1], do: " (held by #{owner_of[&1]})", else: ""}"
          )

        {:warning,
         "on the server, backend #{b.backend_pid}#{if owner_of[b.backend_pid], do: " (held by #{owner_of[b.backend_pid]})", else: ""} waits (#{b.waiting_for}) for a lock held by #{holders}: #{b.query}"}
      end
      |> Enum.take(5)

    idle_tx =
      case Enum.filter(
             Map.values(backends),
             &(&1.state == "idle in transaction" and (&1.in_state_s || 0) >= 1)
           ) do
        [] ->
          []

        list ->
          [
            {:warning,
             "on the server, #{length(list)} backends are idle in a transaction for a second or more: their locks stay held"}
          ]
      end

    blocked ++ idle_tx
  end

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
    pools are the node's DBConnection pools (Postgrex, and Ecto repos on
    it): pool_size connections, each up (connected: idle or checked out
    by a caller) or down (reconnecting, with backoff). callers_waiting
    are processes waiting for a connection, the longest for
    longest_wait_ms, grouped by where they wait (waiting_in); when they
    wait past queue_target for a whole queue_interval, DBConnection drops
    queued checkouts with "connection not available and request was
    dropped from queue". checked_out are the connections held now: by
    whom, where in their code, whether in a transaction, and whether the
    caller is running a query or doing something else meanwhile.
    held_through_window are callers that held a connection at both
    samples. server (with server: true, through a connection of its own)
    is pg_stat_activity for the database: backends idle in a transaction
    (their locks held) and backends waiting for a lock another holds,
    each matched to the pool connection and caller when it's this node's.
    Ecto's queue_time (the telemetry tool, on [repo, :query]) is the
    time each query waited for a connection. Next step: module_code on
    the function holding connections, to move slow work out of the
    transaction; a larger pool_size only helps when the database has
    room for more connections.
    """
  end
end
