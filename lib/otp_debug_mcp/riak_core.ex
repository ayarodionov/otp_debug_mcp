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

  @doc "The cluster as this node sees it, with findings, worst first."
  def report do
    case Checks.remote_eval(@inspect) do
      {:ok, :not_running} ->
        {:error,
         "riak_core isn't running on this node (no riak_core_ring_manager); connect to a " <>
           "node of the cluster"}

      {:ok, {:ok, raw}} ->
        {:ok, analyze(raw)}

      {:error, _} = err ->
        err
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

    notes =
      (registration_findings(raw) ++
         membership_findings(members, raw) ++
         ring_findings(raw, report) ++
         vnode_findings(vnodes, cluster_busiest, raw.overload_threshold) ++
         service_findings(report.services))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
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
    node reaches, each with its node. Next step:
    connect to another member to see its side; process_info on a busy
    vnode's pid, and profile or trace_calls on its module for what its
    commands do.
    """
  end
end
