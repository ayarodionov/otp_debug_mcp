defmodule OtpDebugMcp.RiakCore do
  @moduledoc """
  A riak_core cluster (Riak KV, riak_core_lite and the systems built on
  them), seen from one of its nodes: its members and whether this node
  reaches them, the claimant, ring ownership and the ownership changes
  still to be handed off, this node's vnodes (primaries, fallbacks kept
  for unreachable owners, and the busiest mailboxes, of the vnodes and of
  their proxies), handoffs in progress, and the services the node
  watcher sees up, with riak_core's own cluster-wide checks: whether the
  members' rings agree, and the transfers waiting.

  Everything is read through riak_core's own API, the same that its
  admin tools (riak admin ring-status, transfers, member-status) use.
  Nothing is changed.

  With `crdts: true`, it also measures the riak_dt sets and maps this
  node's vnodes hold, in their state or in the ETS tables they own, as
  terms or as riak_dt's binaries: their size, their actors, elements and
  deferred removes. That asks each vnode for its state (sys:get_state).
  """

  alias OtpDebugMcp.{Checks, Format}

  # Mailboxes from which a vnode, or its proxy, counts as backed up.
  @busy_queue 1_000

  @inspect ~S"""
  case whereis(riak_core_ring_manager) of
    undefined ->
      not_running;
    _ ->
      {ok, Ring} = riak_core_ring_manager:get_my_ring(),
      Q = fun(undefined) -> undefined;
             (P) -> case erlang:process_info(P, [message_queue_len, memory]) of
                      [{_, L}, {_, M}] -> {L, M};
                      _ -> undefined
                    end
          end,
      Proxy = fun(Mod, Idx) ->
        case catch riak_core_vnode_proxy:reg_name(Mod, Idx) of
          N when is_atom(N) -> whereis(N);
          _ -> undefined
        end
      end,
      %% A node's vnodes, with their mailboxes and their proxies': run here,
      %% and on each other member this node reaches.
      VnodeRows = fun() ->
        Vs = case catch riak_core_vnode_manager:all_vnodes() of L when is_list(L) -> L; _ -> [] end,
        [{Mod, Idx, Pid, Q(Pid), Q(Proxy(Mod, Idx))} || {Mod, Idx, Pid} <- Vs]
      end,
      Services = case catch riak_core_node_watcher:services() of
        S when is_list(S) -> [{Svc, catch riak_core_node_watcher:nodes(Svc)} || Svc <- S];
        _ -> []
      end,
      {ok, #{node => node(),
             connected => nodes(),
             members => riak_core_ring:all_member_status(Ring),
             claimant => riak_core_ring:claimant(Ring),
             num_partitions => riak_core_ring:num_partitions(Ring),
             owners => riak_core_ring:all_owners(Ring),
             pending => riak_core_ring:pending_changes(Ring),
             ring_ready => catch riak_core_ring:ring_ready(),
             vnode_modules => catch riak_core:vnode_modules(),
             running_apps => [A || {A, _, _} <- application:which_applications()],
             riak_dt => code:is_loaded(riak_dt_orswot) =/= false,
             vnodes => VnodeRows(),
             members_vnodes => [{N, catch rpc:call(N, erlang, apply, [VnodeRows, []], 5000)}
                                || {N, _} <- riak_core_ring:all_member_status(Ring),
                                   N =/= node(), lists:member(N, nodes())],
             overload_threshold => application:get_env(riak_core, vnode_overload_threshold, 10000),
             handoffs => catch riak_core_handoff_manager:status(),
             handoff_concurrency => catch riak_core_handoff_manager:get_concurrency(),
             services => Services,
             cluster_ringready => catch riak_core_status:ringready(),
             cluster_transfers => catch riak_core_status:transfers()}}
  end.
  """

  # Terms looked at in one vnode's state and tables, at most; and how
  # long all the vnodes may take together.
  @crdt_budget 200_000
  @crdt_deadline 10_000

  # riak_dt's sets and maps, {Clock, Entries, Deferred}, wherever they are
  # in each vnode's state, and the ETS tables it owns: as terms, or as
  # riak_dt's binaries (a type tag, then a version). Each vnode is read in
  # a process of its own, with sys:get_state; a busy one doesn't answer.
  # riak_dt's own stats/1 counts actors, elements and deferred removes.
  @crdts ~S"""
  case code:ensure_loaded(riak_dt_orswot) of
    {error, _} ->
      no_riak_dt;
    _ ->
      code:ensure_loaded(riak_dt_map),
      IsClock = fun(C) when is_list(C) ->
                       lists:all(fun({_, N}) -> is_integer(N) andalso N > 0; (_) -> false end,
                                 lists:sublist(C, 3));
                   (_) -> false
                end,
      IsDict = fun(D) -> is_list(D) orelse
                           (is_tuple(D) andalso tuple_size(D) =:= 9 andalso element(1, D) =:= dict)
               end,
      %% A map's fields are {Name, riak_dt module}.
      IsMap = fun({_, E, _}) ->
                  Keys = case E of
                           L when is_list(L) -> [K || {K, _} <- lists:sublist(L, 1)];
                           _ -> lists:sublist(dict:fetch_keys(E), 1)
                         end,
                  case Keys of
                    [{_, M}] when is_atom(M) -> lists:prefix("riak_dt_", atom_to_list(M));
                    _ -> false
                  end
              end,
      Stats = fun(V) ->
                Mod = case IsMap(V) of true -> riak_dt_map; false -> riak_dt_orswot end,
                case catch Mod:stats(V) of
                  L when is_list(L) -> {Mod, L};
                  _ -> no
                end
              end,
      Label = fun(K) -> lists:sublist(lists:flatten(io_lib:format("~0tP", [K, 8])), 120) end,
      Found = fun(Mod, St, K, Bytes, Enc) ->
                put(found, [{Mod, St, Label(K), Bytes, Enc} | get(found)])
              end,
      Walk = fun W(T, K) ->
                 case get(budget) of
                   N when N =< 0 -> ok;
                   N ->
                   put(budget, N - 1),
                   if
                     is_tuple(T), tuple_size(T) =:= 3 ->
                       {C, E, D} = T,
                       case IsClock(C) andalso IsDict(E) andalso IsDict(D) andalso Stats(T) of
                         {Mod, St} -> Found(Mod, St, K, erlang:external_size(T), false);
                         _ -> W(C, K), W(E, K), W(D, K)
                       end;
                     is_tuple(T), tuple_size(T) =:= 2 ->
                       W(element(1, T), K), W(element(2, T), element(1, T));
                     is_tuple(T) ->
                       lists:foreach(fun(X) -> W(X, K) end, tuple_to_list(T));
                     is_map(T) ->
                       maps:fold(fun(K2, V, _) -> W(V, K2) end, ok, T);
                     is_list(T) ->
                       (fun L([H | Tl]) -> W(H, K), L(Tl);
                            L([]) -> ok;
                            L(Other) -> W(Other, K)
                        end)(T);
                     is_binary(T), byte_size(T) > 2 ->
                       case T of
                         <<Tag, Vers, _/binary>> when (Tag =:= 75 orelse Tag =:= 77), (Vers =:= 1 orelse Vers =:= 2) ->
                           Mod = case Tag of 75 -> riak_dt_orswot; 77 -> riak_dt_map end,
                           case catch Mod:from_binary(T) of
                             {ok, V} ->
                               case catch Mod:stats(V) of
                                 St when is_list(St) -> Found(Mod, St, K, byte_size(T), true);
                                 _ -> ok
                               end;
                             _ -> ok
                           end;
                         _ -> ok
                       end;
                     true ->
                       ok
                   end
                 end
             end,
      Owned = lists:foldl(fun(T, Acc) ->
                            case ets:info(T, owner) of
                              undefined -> Acc;
                              O -> maps:update_with(O, fun(Ts) -> [T | Ts] end, [T], Acc)
                            end
                          end, #{}, ets:all()),
      Vs = case catch riak_core_vnode_manager:all_vnodes() of L when is_list(L) -> L; _ -> [] end,
      Scan = fun(Mod, Idx, Pid) ->
               put(budget, Budget), put(found, []),
               State = case catch sys:get_state(Pid, 2000) of
                         {'EXIT', _} -> busy;
                         S -> Walk(S, undefined), ok
                       end,
               lists:foreach(fun(T) ->
                               case catch ets:select(T, [{'_', [], ['$_']}], 500) of
                                 {Objs, _} ->
                                   lists:foreach(fun(O) when is_tuple(O), tuple_size(O) > 1 ->
                                                       Walk(O, element(1, O));
                                                    (O) -> Walk(O, undefined)
                                                 end, Objs);
                                 _ -> ok
                               end
                             end, maps:get(Pid, Owned, [])),
               {Mod, Idx, State, get(budget) =< 0, get(found)}
             end,
      Refs = [begin
                {P, R} = spawn_monitor(fun() -> exit({scanned, Scan(Mod, Idx, Pid)}) end),
                {R, P, Mod, Idx}
              end || {Mod, Idx, Pid} <- Vs],
      Deadline = erlang:monotonic_time(millisecond) + Deadline0,
      Collect = fun C([], Acc) -> Acc;
                    C([{R, P, Mod, Idx} | Rest], Acc) ->
                      Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
                      receive
                        {'DOWN', R, process, _, {scanned, Res}} -> C(Rest, [Res | Acc]);
                        {'DOWN', R, process, _, _} -> C(Rest, [{Mod, Idx, failed, false, []} | Acc])
                      after Left ->
                        exit(P, kill),
                        C(Rest, [{Mod, Idx, busy, false, []} | Acc])
                      end
                end,
      {ok, Collect(Refs, [])}
  end.
  """

  @doc "The cluster as this node sees it, with findings, worst first."
  def report(opts \\ []) do
    case Checks.remote_eval(@inspect) do
      {:ok, :not_running} ->
        {:error,
         "riak_core isn't running on this node (no riak_core_ring_manager); connect to a " <>
           "node of the cluster"}

      {:ok, {:ok, raw}} ->
        raw = Map.put(raw, :crdts, if(opts[:crdts], do: scan_crdts()))
        {:ok, analyze(raw)}

      {:error, _} = err ->
        err
    end
  end

  defp scan_crdts do
    case Checks.remote_eval(@crdts, Budget: @crdt_budget, Deadline0: @crdt_deadline) do
      {:ok, result} -> result
      {:error, reason} -> {:failed, reason}
    end
  end

  defp analyze(raw) do
    me = raw.node
    reachable = MapSet.new([me | raw.connected])
    owned = Enum.frequencies_by(raw.owners, &elem(&1, 1))
    owner_of = Map.new(raw.owners)
    future = Map.new(for {idx, _owner, next, _mods, :awaiting} <- raw.pending, do: {idx, next})

    members =
      for {node, status} <- raw.members do
        %{
          node: Atom.to_string(node),
          status: status,
          reachable: MapSet.member?(reachable, node),
          owns: Map.get(owned, node, 0),
          share: Float.round(Map.get(owned, node, 0) / max(raw.num_partitions, 1), 3)
        }
        |> put(:claimant, node == raw.claimant)
        |> put(:this_node, node == me)
      end

    vnodes = vnodes(raw.vnodes, me, owner_of, future)

    # The other members' vnodes, for the cluster's busiest mailboxes.
    elsewhere =
      for {node, rows} <- raw.members_vnodes, is_list(rows) do
        rows |> vnodes(node, owner_of, future) |> Map.put(:node, node)
      end

    cluster_busiest =
      [Map.put(vnodes, :node, me) | elsewhere]
      |> Enum.flat_map(fn v ->
        Enum.map(v.busiest, &Map.put(&1, :node, Atom.to_string(v.node)))
      end)
      |> Enum.sort_by(&(-max(&1.queue || 0, &1.proxy_queue || 0)))
      |> Enum.take(5)

    report = %{
      node: Atom.to_string(me),
      cluster: %{
        claimant: Atom.to_string(raw.claimant),
        members: members,
        num_partitions: raw.num_partitions,
        ring_ready: raw.ring_ready,
        pending_changes: pending(raw.pending)
      },
      vnodes: vnodes,
      cluster_busiest_vnodes: cluster_busiest,
      handoffs: %{
        concurrency: concurrency(raw.handoff_concurrency),
        active: handoffs(raw.handoffs)
      },
      services: services(raw.services, raw.members),
      cluster_views: %{
        ringready: Format.inspect(raw.cluster_ringready, limit: 10),
        transfers: Format.inspect(raw.cluster_transfers, limit: 10)
      }
    }

    {crdts, crdt_notes} = crdts(raw.crdts, raw.num_partitions, raw.riak_dt)

    notes =
      (registration_findings(raw) ++
         membership_findings(members, raw) ++
         ring_findings(raw, report) ++
         vnode_findings(vnodes, cluster_busiest, raw.overload_threshold) ++
         service_findings(report.services) ++ crdt_notes)
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> put(:crdts, crdts)
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  # -- This node's vnodes ----------------------------------------------------------

  # A vnode here is a primary when this node owns its partition, a future
  # owner's when an ownership change hands the partition to this node, and
  # otherwise a fallback: kept for an owner that couldn't be reached, until
  # hinted handoff returns its data.
  defp vnodes(list, me, owner_of, future) do
    rows =
      for {mod, idx, pid, vnode_q, proxy_q} <- list do
        owner = Map.get(owner_of, idx)

        role =
          cond do
            owner == me -> :primary
            Map.get(future, idx) == me -> :future_primary
            true -> :fallback
          end

        %{
          module: Format.inspect(mod),
          partition: Integer.to_string(idx),
          pid: Format.inspect(pid),
          role: role,
          owner: owner && Atom.to_string(owner),
          queue: queue(vnode_q),
          proxy_queue: queue(proxy_q),
          memory_bytes: memory(vnode_q)
        }
      end

    by_module =
      rows
      |> Enum.group_by(& &1.module)
      |> Map.new(fn {mod, vs} ->
        {mod, vs |> Enum.frequencies_by(& &1.role) |> Map.put(:total, length(vs))}
      end)

    busiest =
      rows
      |> Enum.sort_by(&(-max(&1.queue || 0, &1.proxy_queue || 0)))
      |> Enum.take(5)
      |> Enum.filter(&(max(&1.queue || 0, &1.proxy_queue || 0) > 0))

    %{
      by_module: by_module,
      fallbacks:
        for(v <- rows, v.role == :fallback, do: Map.take(v, [:module, :partition, :owner])),
      busiest: busiest,
      queued_total: rows |> Enum.map(&((&1.queue || 0) + (&1.proxy_queue || 0))) |> Enum.sum()
    }
  end

  defp queue({len, _mem}), do: len
  defp queue(_), do: nil

  defp memory({_len, mem}), do: mem
  defp memory(_), do: nil

  # -- CRDTs ---------------------------------------------------------------------

  # riak_core's own pattern (Riak KV's) uses the vnode's id as a CRDT's
  # actor, so a value has about one actor per replica: more actors than
  # the ring has partitions means something else is the actor.
  @big_crdt 1_048_576
  @many_deferred 100

  defp crdts(nil, _partitions, true),
    do:
      {nil,
       [
         {:info,
          "riak_dt is loaded here: crdts: true measures the sets and maps this node's vnodes hold"}
       ]}

  defp crdts(nil, _partitions, _riak_dt), do: {nil, []}

  defp crdts(:no_riak_dt, _partitions, _riak_dt),
    do: {%{riak_dt: "not on this node's code path: no CRDTs to measure"}, []}

  defp crdts({:failed, reason}, _partitions, _riak_dt),
    do: {%{failed: Format.inspect(reason, limit: 10)}, []}

  defp crdts({:ok, rows}, partitions, _riak_dt) do
    values =
      for {mod, idx, _state, _partial, found} <- rows,
          {type, stats, key, bytes, encoded} <- found do
        stats = Map.new(stats)

        %{
          type: type |> Atom.to_string() |> String.replace_prefix("riak_dt_", ""),
          key: to_string(key),
          vnode: Format.inspect(mod),
          partition: Integer.to_string(idx),
          bytes: bytes,
          actors: stats[:actor_count],
          deferred_removes: stats[:deferred_length]
        }
        |> put(:elements, stats[:element_count])
        |> put(:fields, stats[:field_count])
        |> put(:encoded, encoded)
      end

    unanswered =
      for {mod, idx, state, _, _} <- rows, state != :ok do
        %{vnode: Format.inspect(mod), partition: Integer.to_string(idx), state: state}
      end

    partial =
      for {mod, idx, _, true, _} <- rows,
          do: %{vnode: Format.inspect(mod), partition: Integer.to_string(idx)}

    many_actors = values |> Enum.filter(&((&1.actors || 0) > partitions)) |> top(:actors)
    deferred = values |> Enum.filter(&((&1.deferred_removes || 0) > 0)) |> top(:deferred_removes)

    by_vnode =
      values
      |> Enum.group_by(&{&1.vnode, &1.partition})
      |> Enum.map(fn {{vnode, partition}, vs} ->
        %{
          vnode: vnode,
          partition: partition,
          count: length(vs),
          bytes: vs |> Enum.map(& &1.bytes) |> Enum.sum()
        }
      end)
      |> top(:bytes)

    report =
      %{
        vnodes_scanned: length(rows),
        count: length(values),
        bytes: values |> Enum.map(& &1.bytes) |> Enum.sum(),
        largest: top(values, :bytes, 10),
        by_vnode: by_vnode
      }
      |> put(:most_actors, nonempty(many_actors))
      |> put(:deferred_removes, nonempty(deferred))
      |> put(:unanswered, nonempty(unanswered))
      |> put(:partly_scanned, nonempty(partial))

    {report, crdt_findings(values, many_actors, deferred, unanswered, partial, partitions)}
  end

  defp top(list, key, n \\ 5), do: list |> Enum.sort_by(&(-Map.fetch!(&1, key))) |> Enum.take(n)

  defp crdt_findings(values, many_actors, deferred, unanswered, partial, partitions) do
    actors =
      case many_actors do
        [] ->
          []

        [v | _] ->
          count = Enum.count(values, &((&1.actors || 0) > partitions))

          [
            {:warning,
             "#{count} CRDTs have more actors than the ring has partitions (#{partitions}); the most, the #{v.type} #{v.key} in #{v.vnode} #{v.partition}, has #{v.actors} actors for #{v.elements || v.fields} #{if v.elements, do: "elements", else: "fields"}, in #{v.bytes} bytes. Each update by a new actor adds it to the value's clock for good, so the actor is something other than the vnode (a client, a request, a process): the value grows with every update, and every merge, read repair and handoff carries it"}
          ]
      end

    big =
      case Enum.max_by(values, & &1.bytes, fn -> nil end) do
        %{bytes: b} = v when b > @big_crdt ->
          [
            {:warning,
             "the #{v.type} #{v.key} in #{v.vnode} #{v.partition} is #{b} bytes: every update merges, and every handoff ships, the whole value"}
          ]

        _ ->
          []
      end

    removes =
      case deferred do
        [] ->
          []

        [v | _] ->
          level = if v.deferred_removes > @many_deferred, do: :warning, else: :info

          [
            {level,
             "#{length(deferred)} CRDTs hold deferred removes, the most #{v.deferred_removes} in the #{v.type} #{v.key} (#{v.vnode} #{v.partition}): removes that came with a context this replica hasn't seen, kept until the adds they remove arrive"}
          ]
      end

    skipped =
      if(unanswered != [],
        do: [
          {:info,
           "#{length(unanswered)} vnodes didn't give their state within 2 s (busy): not measured"}
        ],
        else: []
      ) ++
        if partial != [],
          do: [
            {:info,
             "#{length(partial)} vnodes hold more than was looked at: only part of each was measured"}
          ],
          else: []

    actors ++ big ++ removes ++ skipped
  end

  # -- Ownership changes and handoffs --------------------------------------------

  defp pending(changes) do
    by_transfer =
      for {_idx, owner, next, _mods, status} <- changes, status == :awaiting do
        {Atom.to_string(owner), Atom.to_string(next)}
      end
      |> Enum.frequencies()
      |> Enum.map(fn {{from, to}, n} -> %{from: from, to: to, partitions: n} end)

    %{
      awaiting: Enum.count(changes, &(elem(&1, 4) == :awaiting)),
      complete: Enum.count(changes, &(elem(&1, 4) == :complete)),
      transfers: by_transfer
    }
  end

  defp concurrency(n) when is_integer(n), do: n
  defp concurrency(other), do: Format.inspect(other)

  # Each handoff is {status_v2, Proplist} in riak_core and riak_core_lite.
  defp handoffs(list) when is_list(list) do
    for item <- list do
      fields =
        case item do
          {:status_v2, props} when is_list(props) -> props
          props when is_list(props) -> props
          other -> [status: other]
        end

      Map.new(fields, fn
        {k, v} when is_atom(k) -> {k, plain(v)}
        other -> {:other, Format.inspect(other)}
      end)
    end
  end

  defp handoffs(other), do: Format.inspect(other)

  defp plain(v) when is_atom(v) or is_number(v) or is_binary(v), do: v
  defp plain(v), do: Format.inspect(v, limit: 10)

  # -- Services ------------------------------------------------------------------

  # Each service with the members it isn't up on.
  defp services(list, members) do
    valid = for {node, status} <- members, status in [:valid, :leaving], do: node

    for {svc, nodes} <- list do
      up = if is_list(nodes), do: nodes, else: []

      %{service: Format.inspect(svc), up_on: Enum.map(up, &Atom.to_string/1)}
      |> put(:down_on, Enum.map(valid -- up, &Atom.to_string/1) |> nonempty())
    end
  end

  defp nonempty([]), do: nil
  defp nonempty(l), do: l

  # -- Findings ------------------------------------------------------------------

  # riak_core waits for the application a vnode module was registered
  # under before it hands that module's vnodes off: registered outside a
  # running application (as undefined, when riak_core:register/1 is called
  # from a process of none), its ownership changes never complete.
  defp registration_findings(%{vnode_modules: mods, running_apps: apps}) when is_list(mods) do
    for {app, mod} <- mods, app not in apps do
      {:critical,
       "vnode module #{Format.inspect(mod)} is registered under the application #{Format.inspect(app)}, which isn't running: riak_core never hands its vnodes off, so its ownership changes stay pending (register it from inside its application, or with riak_core:register(App, ...))"}
    end
  end

  defp registration_findings(_raw), do: []

  defp membership_findings(members, raw) do
    unreachable =
      for m <- members, m.status in [:valid, :leaving, :joining], not m.reachable do
        {:critical,
         "#{m.node} is a #{m.status} member, owning #{m.owns} partitions, but this node isn't connected to it"}
      end

    down =
      for m <- members,
          m.status == :down,
          do:
            {:warning,
             "#{m.node} is marked down: its partitions are served by fallbacks until it's back or removed"}

    claimant =
      if Enum.any?(members, &(&1.node == Atom.to_string(raw.claimant) and not &1.reachable)),
        do: [
          {:critical,
           "the claimant, #{raw.claimant}, isn't reachable: no ownership change can be planned or committed"}
        ],
        else: []

    moving =
      for m <- members,
          m.status in [:joining, :leaving, :exiting],
          do: {:info, "#{m.node} is #{m.status}"}

    claimant ++ unreachable ++ down ++ moving
  end

  defp ring_findings(raw, report) do
    pending = report.cluster.pending_changes

    ready =
      case raw.ring_ready do
        false ->
          [{:warning, "the ring isn't ready: members haven't all seen this ring version yet"}]

        _ ->
          []
      end

    rings_differ =
      case raw.cluster_ringready do
        {:error, {:different_owners, a, b}} ->
          [{:warning, "#{a} and #{b} see different ring owners: gossip hasn't converged"}]

        {:error, {:nodes_down, down}} ->
          [
            {:critical,
             "riak_core_status:ringready can't reach #{Enum.map_join(down, ", ", &to_string/1)}"}
          ]

        _ ->
          []
      end

    transfers =
      cond do
        pending.awaiting > 0 and report.handoffs.concurrency == 0 ->
          [
            {:critical,
             "#{pending.awaiting} ownership changes await handoff, and handoff concurrency is 0: none will happen"}
          ]

        pending.awaiting > 0 ->
          [
            {:info,
             "#{pending.awaiting} ownership changes await handoff (#{length(report.handoffs.active)} handoffs running on this node)"}
          ]

        true ->
          []
      end

    ready ++ rings_differ ++ transfers ++ balance(report.cluster.members, raw.num_partitions)
  end

  # Ownership far from even among the members that should own partitions.
  defp balance(members, partitions) do
    owning = Enum.filter(members, &(&1.status == :valid))

    case owning do
      [_, _ | _] ->
        fair = partitions / length(owning)
        {lo, hi} = owning |> Enum.map(& &1.owns) |> Enum.min_max()

        if hi - lo > max(2, round(fair * 0.25)),
          do: [
            {:info,
             "ownership is uneven: members own #{lo} to #{hi} partitions, #{Float.round(fair, 1)} each would be even"}
          ],
          else: []

      _ ->
        []
    end
  end

  defp vnode_findings(vnodes, busiest, threshold) do
    fallbacks =
      case vnodes.fallbacks do
        [] ->
          []

        fbs ->
          owners = fbs |> Enum.map(& &1.owner) |> Enum.uniq() |> Enum.join(", ")

          [
            {:warning,
             "#{length(fbs)} fallback vnodes run here for partitions of #{owners}: their writes wait here for hinted handoff"}
          ]
      end

    overloaded =
      busiest
      |> Enum.map(&{&1, max(&1.queue || 0, &1.proxy_queue || 0)})
      |> Enum.filter(fn {_, q} -> q >= @busy_queue end)
      |> Enum.map(fn {v, q} ->
        level = if is_integer(threshold) and q >= threshold, do: :critical, else: :warning
        where = if (v.proxy_queue || 0) > (v.queue || 0), do: "its proxy's", else: "its"

        refused =
          cond do
            level == :critical ->
              ", past the overload threshold of #{threshold}: requests to it are refused"

            is_integer(threshold) and q >= 0.8 * threshold ->
              ", close to the overload threshold of #{threshold}, past which its proxy refuses requests to it"

            true ->
              ""
          end

        {level,
         "vnode #{v.module} #{v.partition} (#{v.role}) on #{v.node} has #{q} messages in #{where} mailbox" <>
           refused}
      end)

    fallbacks ++ overloaded
  end

  defp service_findings(services) do
    for %{down_on: down} = s <- services do
      {:warning, "#{s.service} isn't up on #{Enum.join(down, ", ")}"}
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
    cluster: the members with their status (valid owns partitions;
    joining, leaving and exiting are in an ownership change; down was
    marked down), whether this node is connected to each, and the
    partitions each owns. The claimant plans and commits ownership
    changes: unreachable, no change can be made. ring_ready false means
    some members haven't seen this ring version yet. pending_changes are
    partitions whose ownership moves, by source and target, awaiting
    their handoff: they complete as handoffs run, so a count that doesn't
    fall in a later call means handoffs are stuck (handoffs.concurrency 0
    turns them off). vnodes are this node's: primaries for the
    partitions it owns, future_primary for partitions moving to it, and
    fallbacks for partitions of members that couldn't be reached, whose
    writes wait here for hinted handoff once the owner is back. busiest
    are the vnodes with the longest mailboxes, of the vnode itself or of
    its proxy, which queues requests in front of it and refuses them past
    the overload threshold. services are what the node watcher sees up,
    and the members a service isn't up on. cluster_views are riak_core's
    own ringready and transfers, which ask every member.
    cluster_busiest_vnodes are the longest mailboxes on every member this
    node reaches, each with its node. crdts (with crdts: true) are the
    riak_dt sets (orswot) and maps this node's vnodes hold, in their state
    or their ETS tables, as terms or riak_dt binaries (encoded), with the
    key they're under: largest by bytes, most_actors (more actors than
    partitions: the actor isn't the vnode, so the clock grows with each
    new client or request), deferred_removes (removes waiting for adds
    this replica hasn't seen). Next step:
    connect to another member to see its side; process_info on a busy
    vnode's pid, and profile or trace_calls on its module for what its
    commands do.
    """
  end
end
