defmodule OtpDebugMcp.Rabbitmq do
  @moduledoc """
  RabbitMQ, from a node of its cluster, through its own APIs, sampled at
  the start and the end of a window: version, cluster members running
  and down, partitions; its resource alarms (memory, disk), with memory
  and disk free against their limits; queues, by messages, ready and
  unacknowledged, consumers, memory and growth over the window;
  channels with the most unacknowledged messages and their prefetch;
  connections by state: running, in flow control (credit flow is
  slowing their publishing), blocked by an alarm.

  When an alarm is set, RabbitMQ stops reading from every connection
  that publishes: publishers hang, with nothing logged on their side. A
  consumer with no prefetch limit (`basic.qos` 0, the default) is sent
  every message as it arrives; what it hasn't acked waits in RabbitMQ's
  memory, and in its own, and is redelivered to someone else if it
  dies. A queue with no consumers keeps every message until someone
  removes it.

  Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Format}

  @max_queues 5_000
  @max_channels 5_000
  @max_connections 5_000

  @snapshot ~S"""
  case catch rabbit:product_info() of
    {'EXIT', _} -> not_rabbitmq;
    Product ->
      Info = fun(F) -> case catch F() of {'EXIT', _} -> undefined; V -> V end end,
      Prop = fun(K, L) -> case lists:keyfind(K, 1, L) of {K, V} -> V; false -> undefined end end,
      VHosts = case Info(fun() -> rabbit_vhost:list_names() end) of L when is_list(L) -> L; _ -> [] end,
      QKeys = [name, type, durable, messages, messages_ready, messages_unacknowledged, consumers,
               consumer_capacity, memory, state, message_bytes, leader, members, arguments, policy],
      Queues = lists:sublist(lists:append([case catch rabbit_amqqueue:info_all(V, QKeys) of
                                             Qs when is_list(Qs) -> Qs;
                                             _ -> []
                                           end || V <- VHosts]), MaxQueues),
      CKeys = [pid, name, connection, user, vhost, consumer_count, messages_unacknowledged,
               messages_unconfirmed, prefetch_count, state],
      Channels = case catch rabbit_channel:info_all(CKeys) of
        Cs when is_list(Cs) -> lists:sublist(Cs, MaxChannels);
        _ -> []
      end,
      NKeys = [name, user, vhost, peer_host, state, channels, recv_oct, send_oct, connected_at],
      Conns = case catch rabbit_networking:connection_info_all(NKeys) of
        Ns when is_list(Ns) -> lists:sublist(Ns, MaxConns);
        _ -> []
      end,
      %% Counters per channel and queue, and per channel and exchange
      %% (rabbit_core_metrics): delivered and acked, and published.
      QM = case catch ets:tab2list(channel_queue_metrics) of
        QRows when is_list(QRows) ->
          [{Ch, {VH, N}, element(2, R) + element(3, R) + element(4, R) + element(5, R), element(7, R)}
           || R <- QRows, tuple_size(R) >= 7, {Ch, {resource, VH, queue, N}} <- [element(1, R)]];
        _ -> []
      end,
      Published = case catch ets:tab2list(channel_exchange_metrics) of
        XRows when is_list(XRows) -> lists:sum([element(2, R) || R <- XRows, tuple_size(R) >= 2, is_integer(element(2, R))]);
        _ -> undefined
      end,
      {ok, Product, Info(fun() -> rabbit_nodes:list_members() end), Info(fun() -> rabbit_nodes:list_running() end),
       Info(fun() -> rabbit_node_monitor:partitions() end),
       Info(fun() -> rabbit_alarm:get_alarms() end),
       {Info(fun() -> vm_memory_monitor:get_process_memory() end), Info(fun() -> vm_memory_monitor:get_memory_limit() end)},
       {Info(fun() -> rabbit_disk_monitor:get_disk_free() end), Info(fun() -> rabbit_disk_monitor:get_disk_free_limit() end)},
       [[{K, case V of
               %% Resource names: {resource, VHost, Kind, Name}.
               {resource, VH, _, N} -> {VH, N};
               _ when is_pid(V) -> V;
               _ -> V
             end} || {K, V} <- Q, K =/= arguments] ++
          [{arguments, [K || {K, _, _} <- Prop(arguments, Q)]}] || Q <- Queues],
       length(Queues), Channels, Conns, {QM, Published}, erlang:monotonic_time(millisecond)}
  end.
  """

  @doc "RabbitMQ on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_rabbitmq ->
          {:error, "this node doesn't run RabbitMQ (no rabbit application)"}

        _ ->
          Process.sleep(duration_ms)

          with {:ok, last} <- snapshot() do
            {:ok, analyze(first, last)}
          end
      end
    end
  end

  defp snapshot do
    Checks.remote_eval(@snapshot,
      MaxQueues: @max_queues,
      MaxChannels: @max_channels,
      MaxConns: @max_connections
    )
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(first, last) do
    {:ok, _, _, _, _, _, _, _, queues0, _, _, conns0, {qm0, published0}, t0} = first

    {:ok, product, members, running, partitions, alarms, {mem, mem_limit}, {disk, disk_limit},
     queues, queue_count, channels, conns, {qm, published}, t1} = last

    elapsed = max(t1 - t0, 1)
    members = list(members)
    running = list(running)

    report =
      %{
        version: version(product),
        cluster:
          %{running: Enum.map(running, &to_string/1)} |> put(:down, down(members, running)),
        memory: %{used_bytes: mem, limit_bytes: mem_limit} |> put(:share, share(mem, mem_limit)),
        disk: %{free_bytes: disk, limit_bytes: disk_limit},
        window_ms: elapsed,
        queues: queue_count
      }
      |> put(:alarms, alarms(alarms))
      |> put(:partitions, list(partitions) != [] && Enum.map(list(partitions), &to_string/1))
      |> put(:published_per_s, rate(published0, published, elapsed))
      |> put(
        :busiest_queues,
        busiest(queues0, queues, elapsed, rates(qm0, qm, elapsed, &elem(&1, 1)))
      )
      |> put(:channels_holding_unacked, unacked(channels, rates(qm0, qm, elapsed, &elem(&1, 0))))
      |> put(:connections, connections(conns0, conns))

    notes = findings(report) |> Enum.sort_by(fn {l, _} -> rank(l) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({l, t} <- notes, do: "#{l}: #{t}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp list(l) when is_list(l), do: l
  defp list(_), do: []

  defp version(product) when is_map(product),
    do: "#{product[:product_base_name] || "RabbitMQ"} #{product[:product_base_version]}"

  defp version(other), do: Format.inspect(other)

  defp down(members, running) do
    d = members -- running
    d != [] && Enum.map(d, &to_string/1)
  end

  defp share(used, limit) when is_integer(used) and is_integer(limit) and limit > 0,
    do: Float.round(used / limit, 3)

  defp share(_, _), do: false

  # Alarms: {{resource_limit, memory | disk, Node}, []}.
  defp alarms(alarms) do
    rows =
      for a <- list(alarms) do
        case a do
          {{:resource_limit, resource, node}, _} -> %{resource: resource, node: to_string(node)}
          other -> %{alarm: Format.inspect(other)}
        end
      end

    rows != [] && rows
  end

  defp prop(q, key) do
    case List.keyfind(q, key, 0) do
      {^key, v} -> if v == :undefined, do: nil, else: v
      nil -> nil
    end
  end

  defp qname(q) do
    case prop(q, :name) do
      {"/", name} -> name
      {vhost, name} -> "#{vhost}/#{name}"
      other -> Format.inspect(other)
    end
  end

  # Queues by messages, with how fast they grew over the window.
  defp rate(a, b, elapsed) when is_integer(a) and is_integer(b) and b >= a,
    do: Float.round((b - a) * 1000 / elapsed, 1)

  defp rate(_, _, _), do: false

  # Delivered and acked a second, by queue or by channel (`key` picks
  # it), from the counters' growth. A channel that closed takes its
  # counters with it, so only those in both samples count.
  defp rates(qm0, qm, elapsed, key) do
    sum = fn rows ->
      rows
      |> Enum.group_by(fn {ch, q, _, _} -> {ch, q} end)
      |> Map.new(fn {k, [{_, _, d, a} | _]} -> {k, {d, a}} end)
    end

    before = sum.(qm0)

    qm
    |> sum.()
    |> Enum.flat_map(fn {k, {d, a}} ->
      case before[k] do
        {d0, a0} when d >= d0 and a >= a0 -> [{key.(k), {d - d0, a - a0}}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, counts} ->
      {k,
       %{
         delivered_per_s:
           Float.round(Enum.sum(Enum.map(counts, &elem(&1, 0))) * 1000 / elapsed, 1),
         acked_per_s: Float.round(Enum.sum(Enum.map(counts, &elem(&1, 1))) * 1000 / elapsed, 1)
       }}
    end)
  end

  defp busiest(queues0, queues, elapsed, rates) do
    before = Map.new(queues0, &{qname(&1), prop(&1, :messages)})

    rows =
      queues
      |> Enum.sort_by(&(-(prop(&1, :messages) || 0)))
      |> Enum.take(10)
      |> Enum.filter(&((prop(&1, :messages) || 0) > 0))
      |> Enum.map(fn q ->
        name = qname(q)
        m = prop(q, :messages) || 0
        m0 = before[name]

        %{
          queue: name,
          type: prop(q, :type),
          messages: m,
          ready: prop(q, :messages_ready),
          unacknowledged: prop(q, :messages_unacknowledged),
          consumers: prop(q, :consumers),
          memory_bytes: prop(q, :memory)
        }
        |> put(:growth_per_s, is_integer(m0) && Float.round((m - m0) * 1000 / elapsed, 1))
        |> Map.merge(rates[prop(q, :name)] || %{})
        |> put(:message_bytes, prop(q, :message_bytes))
        |> put(
          :consumer_capacity,
          is_number(prop(q, :consumer_capacity)) && prop(q, :consumer_capacity)
        )
        |> put(:state, prop(q, :state) not in [nil, :running] && Format.inspect(prop(q, :state)))
        |> put(:policy, prop(q, :policy) not in [nil, "", :""] && to_string(prop(q, :policy)))
        |> put(:arguments, prop(q, :arguments) not in [nil, []] && prop(q, :arguments))
      end)

    rows != [] && rows
  end

  # Channels holding the most unacknowledged messages, with their
  # prefetch (0: no limit).
  defp unacked(channels, rates) do
    rows =
      channels
      |> Enum.filter(&((prop(&1, :messages_unacknowledged) || 0) > 0))
      |> Enum.sort_by(&(-prop(&1, :messages_unacknowledged)))
      |> Enum.take(5)
      |> Enum.map(fn c ->
        %{
          channel: to_string(prop(c, :name) || "?"),
          user: prop(c, :user),
          unacknowledged: prop(c, :messages_unacknowledged),
          prefetch: prop(c, :prefetch_count),
          consumers: prop(c, :consumer_count)
        }
        |> put(:acked_per_s, rates[prop(c, :pid)] && rates[prop(c, :pid)].acked_per_s)
        |> put(
          :unconfirmed,
          (prop(c, :messages_unconfirmed) || 0) > 0 && prop(c, :messages_unconfirmed)
        )
      end)

    rows != [] && rows
  end

  # Connections by state, and those blocked or in flow through the window.
  defp connections(conns0, conns) do
    state = fn c -> prop(c, :state) end
    name = fn c -> to_string(prop(c, :name) || "?") end
    before = Map.new(conns0, &{name.(&1), state.(&1)})

    by_state =
      conns
      |> Enum.map(state)
      |> Enum.frequencies()
      |> Map.new(fn {s, n} -> {Format.inspect(s), n} end)

    stuck =
      for c <- conns,
          state.(c) in [:blocked, :blocking, :flow],
          before[name.(c)] in [:blocked, :blocking, :flow] do
        %{connection: name.(c), user: prop(c, :user), state: state.(c)}
      end

    %{total: length(conns), by_state: by_state}
    |> put(:held_through_window, stuck != [] && Enum.take(stuck, 10))
    |> put(:held_through_window_count, stuck != [] && length(stuck))
  end

  # -- Findings ------------------------------------------------------------------

  defp findings(r) do
    alarms =
      for a <- r[:alarms] || [] do
        what =
          case a[:resource] do
            :memory ->
              "memory: the node uses #{mb(r.memory.used_bytes)} MB of its #{mb(r.memory.limit_bytes)} MB high watermark"

            :disk ->
              "disk: #{mb(r.disk.free_bytes)} MB free, under its #{mb(r.disk.limit_bytes)} MB limit"

            _ ->
              Format.inspect(a)
          end

        {:critical,
         "a #{a[:resource] || "resource"} alarm is set on #{a[:node] || "a node"} (#{what}): RabbitMQ stops reading from every connection that publishes until it clears, so publishers hang, and their clients log nothing"}
      end

    near =
      case r.memory[:share] do
        s when is_float(s) and s >= 0.8 and s < 1.0 and alarms == [] ->
          [
            {:warning,
             "the node uses #{round(s * 100)}% of its memory high watermark (#{mb(r.memory.limit_bytes)} MB): at the watermark a memory alarm blocks every publisher"}
          ]

        _ ->
          []
      end

    cluster =
      ((r.cluster[:down] &&
          [{:warning, "cluster members not running: #{Enum.join(r.cluster.down, ", ")}"}]) || []) ++
        ((r[:partitions] && [{:critical, "a network partition: #{Enum.join(r.partitions, ", ")}"}]) ||
           [])

    queues =
      for q <- r[:busiest_queues] || [], (q[:consumers] || 0) == 0, (q[:messages] || 0) >= 1000 do
        {:warning,
         "queue #{q.queue} has #{q.messages} messages and no consumers#{grow(q)}: they're kept, in memory or on disk, until something consumes or removes them. A queue nobody reads any more wants deleting (or a max-length or TTL policy), and its publishers stopping"}
      end

    slow =
      for q <- r[:busiest_queues] || [], (q[:consumers] || 0) > 0, (q[:growth_per_s] || 0) > 1 do
        {:warning,
         "queue #{q.queue} grew #{q.growth_per_s} messages a second with #{q.consumers} #{if q.consumers == 1, do: "consumer", else: "consumers"}#{if q[:acked_per_s], do: ", which acked #{q.acked_per_s} a second (#{q.delivered_per_s} delivered)", else: ""}: they take less than is published#{if q[:unacknowledged] && q.unacknowledged > q[:ready], do: "; most of it (#{q.unacknowledged}) is delivered but unacknowledged", else: ""}"}
      end

    prefetch =
      for c <- r[:channels_holding_unacked] || [], c.prefetch == 0, c.unacknowledged >= 1000 do
        {:warning,
         "channel #{c.channel} (#{c.user}) holds #{c.unacknowledged} unacknowledged messages, with no prefetch limit#{if c[:acked_per_s], do: ", acking #{c.acked_per_s} a second", else: ""}: RabbitMQ sends a consumer without basic.qos everything as it arrives, and keeps each until it's acked, in its memory; set a prefetch (e.g. 50) so the rest wait in the queue, cheaply, or for another consumer"}
      end

    flow =
      case r.connections[:held_through_window_count] do
        n when is_integer(n) and n > 0 ->
          states = r.connections.held_through_window |> Enum.map(& &1.state) |> Enum.uniq()

          [
            {if(Enum.any?(states, &(&1 in [:blocked, :blocking])), do: :critical, else: :warning),
             "#{n} connections were #{Enum.map_join(states, " or ", &state_text/1)} through the whole window: #{if :flow in states, do: "credit flow slows a publisher when the queues it publishes to can't keep up; ", else: ""}their publishing is held up"}
          ]

        _ ->
          []
      end

    alarms ++ cluster ++ near ++ flow ++ prefetch ++ slow ++ queues
  end

  defp state_text(:flow), do: "in flow control"
  defp state_text(:blocked), do: "blocked (by an alarm)"
  defp state_text(:blocking), do: "blocking (an alarm, on their next publish)"
  defp state_text(s), do: Format.inspect(s)

  defp grow(%{growth_per_s: g}) when g > 0, do: ", #{g} more a second"
  defp grow(_), do: ""

  defp mb(n) when is_integer(n), do: div(n, 1_000_000)
  defp mb(_), do: "?"

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

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    alarms: RabbitMQ's resource alarms (memory, disk); while one is set,
    every publishing connection is blocked. memory: the node's memory
    against its high watermark; disk: free space against its limit.
    published_per_s: messages published, all channels. busiest_queues: by
    messages, ready (waiting for a consumer) and unacknowledged
    (delivered, not yet acked), consumers, memory, growth over the
    window, and delivered_per_s and acked_per_s from RabbitMQ's own
    counters; consumer_capacity below 1 means consumers
    can't take messages as fast as they come. channels_holding_unacked:
    the channels with most unacked messages, with their prefetch (0: no
    limit, everything is sent at once). connections: by state; flow
    means credit flow is slowing that publisher, blocked an alarm; those
    so through the whole window are listed. Next step: process_info on
    a queue's or channel's process; the consumer's own code for its
    prefetch and acks.
    """
  end
end
