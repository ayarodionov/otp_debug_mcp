defmodule OtpDebugMcp.Mnesia do
  @moduledoc """
  Mnesia on a node, sampled at the start and the end of a window: its
  nodes, its tables (storage, size, memory, where their copies are and
  whether any is reachable), the locks held and the transactions queued
  for them, the transactions running, its commit, failure and restart
  counts, its own processes' mailboxes, and the system events it reports
  meanwhile (overload, a partitioned network, a node down).

  Everything is read through Mnesia's own `system_info/1` and
  `table_info/2`; the system events, by subscribing for the window.

  A transaction takes its locks as it reads and writes, and holds them
  until it ends. One that does slow work inside (a call to another
  service, a big computation) holds every lock it took meanwhile, and
  every transaction that needs one of them waits in the lock queue, or is
  restarted: Mnesia restarts the younger of two transactions that would
  otherwise wait for each other.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Tables, locks, queued and running transactions described, at most.
  @max_tables 200
  @max_locks 500

  @snapshot ~S"""
  case catch mnesia:system_info(is_running) of
    yes ->
      Info = [{K, catch mnesia:system_info(K)}
              || K <- [db_nodes, running_db_nodes, use_dir, directory, dump_log_write_threshold,
                       dump_log_time_threshold, transaction_commits, transaction_failures,
                       transaction_restarts, transaction_log_writes, version, master_node_tables]],
      Tabs = lists:sublist([T || T <- mnesia:system_info(tables), T =/= schema], MaxTables),
      Tables = [{T, [{K, catch mnesia:table_info(T, K)}
                     || K <- [storage_type, size, memory, type, ram_copies, disc_copies,
                              disc_only_copies, where_to_read, active_replicas]]}
                || T <- Tabs],
      Held = case catch mnesia:system_info(held_locks) of L when is_list(L) -> lists:sublist(L, MaxLocks); _ -> [] end,
      Queue = case catch mnesia:system_info(lock_queue) of Q when is_list(Q) -> lists:sublist(Q, MaxLocks); _ -> [] end,
      Trans = case catch mnesia:system_info(transactions) of Tr when is_list(Tr) -> lists:sublist(Tr, MaxLocks); _ -> [] end,
      %% Where each process in a transaction is: the first frame of the
      %% application's code, and the function it's in.
      Skip = [gen, gen_server, proc_lib, erlang, lists, maps, timer, ets, dets, prim_inet],
      AppFrame = fun(Stack) ->
        case [MFA || {Mo, F, A, _} = MFA <- Stack,
                     not lists:member(Mo, Skip),
                     not lists:prefix("mnesia", atom_to_list(Mo)),
                     not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end,
                                   ["Elixir.Enum", "Elixir.Process", "Elixir.Task", "Elixir.GenServer",
                                    "Elixir.Stream", "Elixir.Agent", "Elixir.Kernel"]),
                     F =/= module_info, is_integer(A) orelse is_list(A)] of
          [{Mo, F, A, _} | _] -> {Mo, F, case is_list(A) of true -> length(A); false -> A end};
          [] -> undefined
        end
      end,
      Pids = lists:usort([P || {_, _, {tid, _, P}} <- Held, is_pid(P)] ++
                         [P || {_, _, P, _, _} <- Queue, is_pid(P)] ++
                         [P || {_, P, _} <- Trans, is_pid(P)]),
      Where = [{P, AppFrame(St), CF}
               || P <- lists:sublist(Pids, 200), node(P) =:= node(),
                  [{current_stacktrace, St}, {current_function, CF}]
                    <- [erlang:process_info(P, [current_stacktrace, current_function])]],
      Mailboxes = [{N, Len} || N <- [mnesia_tm, mnesia_locker, mnesia_controller, mnesia_recover,
                                     mnesia_monitor, mnesia_subscr, mnesia_late_loader],
                               P <- [whereis(N)], is_pid(P),
                               {message_queue_len, Len} <- [erlang:process_info(P, message_queue_len)]],
      {ok, Info, Tables, Held, Queue, Trans, Where, Mailboxes, erlang:system_info(wordsize)};
    {'EXIT', _} -> not_loaded;
    Other -> {not_running, Other}
  end.
  """

  # For the window, in a process of its own: Mnesia's system events, by
  # subscribing, and the lock queue, sampled every Interval ms (a hot
  # record is often between waiters at any one moment, its transactions
  # restarting). Given back when asked, or ended a minute later.
  @subscribe ~S"""
  case whereis(Name) of
    undefined ->
      Parent = self(),
      Skip = [gen, gen_server, proc_lib, erlang, lists, maps, timer, ets, dets, prim_inet],
      AppFrame = fun(P) ->
        case erlang:process_info(P, current_stacktrace) of
          {current_stacktrace, Stack} ->
            case [MFA || {Mo, F, A, _} = MFA <- Stack,
                         not lists:member(Mo, Skip),
                         not lists:prefix("mnesia", atom_to_list(Mo)),
                         not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end,
                                       ["Elixir.Enum", "Elixir.Process", "Elixir.Task", "Elixir.GenServer",
                                        "Elixir.Stream", "Elixir.Agent", "Elixir.Kernel"]),
                         F =/= module_info, is_integer(A) orelse is_list(A)] of
              [{Mo, F, A, _} | _] -> {Mo, F, case is_list(A) of true -> length(A); false -> A end};
              [] -> undefined
            end;
          _ -> undefined
        end
      end,
      %% Per record waited for: samples it was waited for in, waiters
      %% summed, the most at once, the locks asked for, and its holders'
      %% places in the code.
      Sample = fun(Stats) ->
        Queue = case catch mnesia:system_info(lock_queue) of Q when is_list(Q) -> lists:sublist(Q, 500); _ -> [] end,
        case Queue of
          [] -> Stats;
          _ ->
            Held = case catch mnesia:system_info(held_locks) of H when is_list(H) -> H; _ -> [] end,
            Waited = lists:foldl(fun({Oid, Op, _, _, _}, Acc) ->
                                   maps:update_with(Oid, fun({N, Ops}) -> {N + 1, [Op | Ops]} end, {1, [Op]}, Acc)
                                 end, #{}, Queue),
            maps:fold(fun(Oid, {N, Ops}, Acc) ->
                        Holders = [AppFrame(HP) || {O, _, {tid, _, HP}} <- Held, O =:= Oid, is_pid(HP),
                                                   node(HP) =:= node()],
                        {S0, W0, M0, Ops0, H0} = maps:get(Oid, Acc, {0, 0, 0, [], []}),
                        Acc#{Oid => {S0 + 1, W0 + N, max(M0, N), lists:usort(Ops ++ Ops0),
                                     lists:sublist(Holders ++ H0, 50)}}
                      end, Stats, Waited)
        end
      end,
      spawn(fun() ->
        register(Name, self()),
        R = (catch mnesia:subscribe(system)),
        Parent ! {Name, R},
        Loop = fun L(Acc, N, Stats, Samples) ->
          receive
            {mnesia_system_event, E} when N < 100 -> L([E | Acc], N + 1, Stats, Samples);
            {mnesia_system_event, _} -> L(Acc, N + 1, Stats, Samples);
            {read, From, Ref} ->
              From ! {Ref, {lists:reverse(Acc), N,
                            lists:sublist(lists:reverse(lists:keysort(2, [{Oid, element(2, V), V} || {Oid, V} <- maps:to_list(Stats)])), 20),
                            Samples}}
          after Interval ->
            case Samples < 600 of
              true -> L(Acc, N, Sample(Stats), Samples + 1);
              false -> L(Acc, N, Stats, Samples)
            end
          end
        end,
        Loop([], 0, #{}, 0)
      end),
      receive {Name, Reply} -> Reply after 5000 -> timeout end;
    _ ->
      already_running
  end.
  """

  @read_events ~S"""
  case whereis(Name) of
    undefined -> none;
    Pid ->
      Ref = make_ref(),
      Pid ! {read, self(), Ref},
      receive {Ref, Events} -> {ok, Events} after 5000 -> timeout end
  end.
  """

  @events :otp_debug_mcp_mnesia_events

  @doc "Mnesia on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    case snapshot() do
      {:ok, :not_loaded} ->
        {:error, "Mnesia isn't loaded on this node"}

      {:ok, {:not_running, state}} ->
        {:error,
         "Mnesia isn't running on this node (mnesia:system_info(is_running) is #{Format.inspect(state)})"}

      {:ok, {:ok, _, _, _, _, _, _, _, _} = first} ->
        subscribed = Checks.remote_eval(@subscribe, Name: @events, Interval: 100)
        t0 = System.monotonic_time(:millisecond)
        Process.sleep(duration_ms)

        events =
          case subscribed do
            {:ok, {:ok, _}} -> Checks.remote_eval(@read_events, Name: @events)
            other -> {:not_subscribed, other}
          end

        with {:ok, last} <- snapshot() do
          elapsed = max(System.monotonic_time(:millisecond) - t0, 1)
          {:ok, analyze(first, last, events, elapsed)}
        end

      {:error, _} = err ->
        err
    end
  end

  defp snapshot,
    do: Checks.remote_eval(@snapshot, MaxTables: @max_tables, MaxLocks: @max_locks)

  # -- Analysis ------------------------------------------------------------------

  defp analyze(
         {:ok, info, tables, held, queue, trans, where, mailboxes, wordsize},
         last,
         events,
         elapsed
       ) do
    info = Map.new(info)

    {last_info, last_tables, last_held, last_queue, last_trans, last_where} =
      case last do
        {:ok, li, lt, lh, lq, ltr, lw, _, _} -> {Map.new(li), Map.new(lt), lh, lq, ltr, lw}
        _ -> {info, Map.new(tables), held, queue, trans, where}
      end

    where = Map.new(where ++ last_where, fn {pid, app, cf} -> {pid, {app, cf}} end)
    per_s = fn key -> rate(info[key], last_info[key], elapsed) end
    down = nodes_list(info[:db_nodes]) -- nodes_list(last_info[:running_db_nodes])

    tables =
      for {t, props} <- tables, do: table(t, Map.new(props), last_tables[t], wordsize, elapsed)

    report =
      %{
        nodes:
          %{
            db_nodes: Enum.map(nodes_list(info[:db_nodes]), &to_string/1),
            running: Enum.map(nodes_list(last_info[:running_db_nodes]), &to_string/1)
          }
          |> put(:down, down != [] && Enum.map(down, &to_string/1)),
        tables: Enum.sort_by(tables, &(-(&1[:memory_bytes] || 0))),
        transactions: %{
          running: length(last_trans),
          commits_per_s: per_s.(:transaction_commits),
          failures_per_s: per_s.(:transaction_failures),
          restarts_per_s: per_s.(:transaction_restarts),
          log_writes_per_s: per_s.(:transaction_log_writes)
        },
        locks: %{held: length(last_held), queued: length(last_queue)},
        listened_ms: elapsed,
        dump_log_write_threshold: info[:dump_log_write_threshold],
        version: plain(info[:version])
      }
      |> put(:contended, contended(events))
      |> put(:long_transactions, long_transactions(trans, last_trans, where))
      |> put(:mailboxes, mailboxes(mailboxes))
      |> put(:system_events, system_events(events))

    notes =
      (table_findings(report.tables) ++
         node_findings(down, report.tables) ++
         event_findings(report[:system_events]) ++
         lock_findings(report[:contended]) ++
         transaction_findings(report.transactions, report[:long_transactions]) ++
         mailbox_findings(report[:mailboxes]))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp nodes_list(l) when is_list(l), do: l
  defp nodes_list(_), do: []

  defp rate(a, b, elapsed) when is_integer(a) and is_integer(b),
    do: Float.round((b - a) * 1000 / elapsed, 1)

  defp rate(_, _, _), do: nil

  defp plain(v) when is_list(v), do: List.to_string(v)
  defp plain(v), do: Format.inspect(v)

  defp table(t, p, later, wordsize, elapsed) do
    later = if is_list(later), do: Map.new(later), else: p
    storage = p[:storage_type]

    # ETS-backed tables count memory in words; dets ones in bytes.
    memory =
      case {storage, later[:memory]} do
        {:disc_only_copies, m} when is_integer(m) -> m
        {_, m} when is_integer(m) -> m * wordsize
        _ -> nil
      end

    unreachable = p[:where_to_read] == :nowhere or later[:where_to_read] == :nowhere

    %{
      table: Format.inspect(t),
      storage: Format.inspect(storage),
      size: later[:size],
      memory_bytes: memory,
      copies:
        %{}
        |> put(:ram, copies(p[:ram_copies]))
        |> put(:disc, copies(p[:disc_copies]))
        |> put(:disc_only, copies(p[:disc_only_copies])),
      where_to_read: plain_atom(later[:where_to_read])
    }
    |> put(:growing_per_s, growth(p[:size], later[:size], elapsed))
    |> put(:unreachable, unreachable)
  end

  defp plain_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp plain_atom(other), do: Format.inspect(other)

  defp copies(l) when is_list(l) and l != [], do: Enum.map(l, &to_string/1)
  defp copies(_), do: false

  defp growth(a, b, elapsed) when is_integer(a) and is_integer(b) and b > a,
    do: Float.round((b - a) * 1000 / elapsed, 1)

  defp growth(_, _, _), do: false

  # Records waited for, from the lock queue sampled through the window:
  # how often they had waiters, how many on average and at most, the
  # locks asked for, and where in your code their holders were.
  defp contended({:ok, {:ok, {_events, _n, stats, samples}}}) when samples > 0 do
    rows =
      for {oid, _waiters, {seen, waiters, most, ops, holders}} <- stats do
        %{
          record: Format.inspect(oid),
          waited_for_in: "#{seen} of #{samples} samples",
          waiting_on_average: Float.round(waiters / samples, 2),
          waiting_at_most: most,
          for: Enum.map(ops, &plain_atom/1)
        }
        |> put(
          :held_by_code,
          holders != [] &&
            holders
            |> Enum.frequencies()
            |> Enum.sort_by(fn {_, n} -> -n end)
            |> Enum.take(3)
            |> Enum.map(fn {frame, n} -> "#{location({frame, frame})} (#{n})" end)
        )
        |> Map.put(:seen_share, Float.round(seen / samples, 2))
      end
      |> Enum.sort_by(&(-&1.waiting_on_average))
      |> Enum.take(10)

    rows != [] && rows
  end

  defp contended(_), do: false

  # Transactions running at both samples: older than the window.
  defp long_transactions(trans, last_trans, where) do
    before = MapSet.new(trans, &elem(&1, 0))
    long = Enum.filter(last_trans, &MapSet.member?(before, elem(&1, 0)))

    long != [] &&
      long
      |> Enum.map(fn {_counter, pid, _} -> location(where[pid]) || "unknown" end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(5)
      |> Enum.map(fn {loc, n} -> %{transactions: n, in_your_code: loc} end)
  end

  defp location({:undefined, :undefined}), do: "no frame of your code"

  defp location({app, cf}) do
    case {app, cf} do
      {nil, _} -> "#{mfa(cf)} (no frame of your code)"
      {:undefined, _} -> "#{mfa(cf)} (no frame of your code)"
      {app, cf} when app == cf -> mfa(app)
      {app, cf} -> "#{mfa(app)}, now in #{mfa(cf)}"
    end
  end

  defp location(_), do: nil

  defp mailboxes(list) do
    big =
      for {name, n} <- list, n > 100, do: %{process: Format.inspect(name), message_queue_len: n}

    big != [] && big
  end

  defp system_events({:ok, {:ok, {events, total, _stats, _samples}}}) do
    by =
      events
      |> Enum.map(&event_kind/1)
      |> Enum.frequencies()
      |> Enum.map(fn {kind, n} -> %{event: kind, count: n} end)

    by != [] &&
      %{
        total: total,
        by_kind: by,
        first: events |> Enum.take(5) |> Enum.map(&Format.inspect(&1, limit: 15))
      }
  end

  defp system_events(_), do: false

  defp event_kind({:mnesia_overload, details}), do: "mnesia_overload #{Format.inspect(details)}"
  defp event_kind({:inconsistent_database, kind, _node}), do: "inconsistent_database #{kind}"
  defp event_kind({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp event_kind(tuple) when is_tuple(tuple), do: Format.inspect(elem(tuple, 0))
  defp event_kind(other), do: Format.inspect(other)

  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- Findings ------------------------------------------------------------------

  defp table_findings(tables) do
    unreachable =
      for t <- tables, t[:unreachable] do
        {:critical,
         "table #{t.table} has no copy this node can reach (where_to_read: nowhere; copies on #{t.copies |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.join(", ")}): reads and writes of it fail, or wait in wait_for_tables"}
      end

    dets =
      for t <- tables,
          t.storage == ":disc_only_copies",
          (t[:memory_bytes] || 0) > 1_500_000_000 do
        {:warning,
         "table #{t.table} is disc_only_copies (dets) at #{div(t.memory_bytes, 1_000_000)} MB: dets files stop at 2 GB"}
      end

    unreachable ++ dets
  end

  defp node_findings([], _tables), do: []

  defp node_findings(down, tables) do
    names = Enum.map(down, &to_string/1)

    affected =
      for t <- tables,
          nodes = t.copies |> Map.values() |> List.flatten(),
          Enum.any?(nodes, &(&1 in names)),
          do: t.table

    [
      {:warning,
       "Mnesia isn't running on #{Enum.join(names, ", ")}, of its db_nodes#{if affected != [], do: ": tables with copies there have fewer now (#{Enum.join(Enum.take(affected, 10), ", ")})", else: ""}"}
    ]
  end

  defp event_findings(%{by_kind: kinds}) do
    for %{event: kind, count: n} <- kinds do
      cond do
        String.starts_with?(kind, "inconsistent_database") ->
          {:critical,
           "Mnesia reported #{kind} (#{n} times) in the window: the nodes were partitioned and their tables may now differ; Mnesia doesn't merge them by itself (set_master_nodes, or restart the losing side)"}

        String.starts_with?(kind, "mnesia_overload") ->
          {:warning,
           "Mnesia reported #{kind} #{n} times in the window: it can't keep up (dump_log write_threshold: more writes between log dumps than dump_log_write_threshold allows; mnesia_tm or mnesia_controller: their queues)"}

        kind in ["mnesia_down", "mnesia_fatal", "mnesia_error"] ->
          {:warning, "Mnesia reported #{kind} #{n} times in the window"}

        true ->
          {:info, "Mnesia reported #{kind} #{n} times in the window"}
      end
    end
  end

  defp event_findings(_), do: []

  defp lock_findings(false), do: []
  defp lock_findings(nil), do: []

  defp lock_findings(rows) do
    for r <- rows, r.waiting_at_most >= 2, r.seen_share >= 0.25 do
      holder =
        case r[:held_by_code] do
          [h | _] -> ", its lock held mostly in #{h}"
          _ -> ""
        end

      {:warning,
       "transactions waited for a #{Enum.join(r.for, "/")} lock on #{r.record} in #{r.waited_for_in}, #{r.waiting_on_average} on average and #{r.waiting_at_most} at most#{holder}: a transaction holds its locks until it ends, so what it does meanwhile, every transaction after that record waits for"}
    end
  end

  defp transaction_findings(t, long) do
    restarts =
      if is_number(t.restarts_per_s) and t.restarts_per_s >= 1 and
           t.restarts_per_s >= 0.1 * max(t.commits_per_s || 0, 1),
         do: [
           {:warning,
            "#{t.restarts_per_s} transactions restarted a second, against #{t.commits_per_s} commits: they conflict on locks, and Mnesia restarts the younger of two that would wait for each other, running its fun again"}
         ],
         else: []

    failures =
      if is_number(t.failures_per_s) and t.failures_per_s > 0,
        do: [{:warning, "#{t.failures_per_s} transactions a second aborted"}],
        else: []

    long_running =
      case long do
        [top | _] = list ->
          n = list |> Enum.map(& &1.transactions) |> Enum.sum()

          [
            {:warning,
             "#{n} transactions were running at both ends of the window, most in #{top.in_your_code}: long transactions hold their locks all that time"}
          ]

        _ ->
          []
      end

    restarts ++ failures ++ long_running
  end

  defp mailbox_findings(false), do: []
  defp mailbox_findings(nil), do: []

  defp mailbox_findings(list) do
    for m <- list, m.message_queue_len > 1_000 do
      {:warning,
       "Mnesia's #{m.process} has #{m.message_queue_len} messages queued: it can't keep up"}
    end
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
    nodes are Mnesia's db_nodes and those it runs on now; down, those it
    doesn't. tables, largest first: storage, size (records), memory,
    where their copies are (ram, disc, disc_only per node), where_to_read
    (nowhere: no copy reachable, so the table can't be used), and
    growing_per_s. transactions: running now, and commits, failures
    (aborted), restarts (retried after a lock conflict) and log writes a
    second over the window. locks: held and queued now. contended are the
    records transactions wait for a lock on, with who holds it and where
    in your code that transaction is: a transaction holds its locks until
    it ends, so slow work inside one (a call out, a sleep, a big loop)
    holds everyone after the same records. long_transactions ran through
    the whole window. mailboxes are Mnesia's own processes with long
    queues; system_events, what Mnesia reported in the window:
    mnesia_overload (dump_log write_threshold: raise
    dump_log_write_threshold, or write less), inconsistent_database (a
    partition healed with tables that differ), mnesia_down. Next step:
    module_code on the transaction's function, to move the slow work out
    of it, or to split a hot record; ets_table on a ram or disc table for
    what's in it.
    """
  end
end
