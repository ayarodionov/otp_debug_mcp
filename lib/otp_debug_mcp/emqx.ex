defmodule OtpDebugMcp.Emqx do
  @moduledoc """
  EMQX, the MQTT broker, on a node of its cluster, sampled at the start
  and the end of a window, through its own APIs and tables: its version,
  cluster and overload protection, its own alarms, its listeners and how
  full they are, its clients, sessions and subscriptions, what its
  message counters did over the window (received, delivered, dropped and
  why, sessions taken over or discarded, authentication failures), the
  clients that can't keep up (from the channel table: messages in flight
  unacknowledged, queued, dropped), the clients reconnecting during the
  window, and its rules and actions with their failures.

  Nothing is changed. EMQX 5 is the version this reads; older ones answer
  what they have.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Channels read from the channel table, at most.
  @max_channels 20_000

  @snapshot ~S"""
  case catch emqx_release:version() of
    {'EXIT', _} -> not_emqx;
    Vsn ->
      Listeners = case catch emqx_listeners:list() of
        Ls when is_list(Ls) ->
          [begin
             Bind = maps:get(bind, Conf, undefined),
             {Id, maps:get(running, Conf, undefined), Bind,
              catch emqx_listeners:current_conns(Id, Bind),
              catch emqx_listeners:max_conns(Id, Bind)}
           end || {Id, Conf} <- Ls, is_map(Conf)];
        _ -> []
      end,
      Alarms = case catch emqx_alarm:get_alarms(activated) of
        As when is_list(As) ->
          [maps:with([name, message, activate_at, details], A) || A <- lists:sublist(As, 50), is_map(A)];
        _ -> []
      end,
      %% Each channel: client id, pid, its connection's state and start,
      %% and the stats that show a slow consumer.
      Keep = [inflight_cnt, inflight_max, mqueue_len, mqueue_max, mqueue_dropped, mailbox_len,
              memory, recv_msg, send_msg, 'send_msg.dropped'],
      Chans = case ets:info(emqx_channel_info, size) of
        undefined -> {0, []};
        Size ->
          Rows = case ets:select(emqx_channel_info, [{'$1', [], ['$1']}], MaxChannels) of
            {L, _} -> L;
            _ -> []
          end,
          {Size,
           [{Id, Pid, maps:get(conn_state, Info, undefined),
             maps:get(connected_at, maps:get(conninfo, Info, #{}), undefined),
             maps:get(clean_start, maps:get(conninfo, Info, #{}), undefined),
             maps:get(proto_ver, maps:get(conninfo, Info, #{}), undefined),
             [{K, V} || {K, V} <- Stats, lists:member(K, Keep)]}
            || {{Id, Pid}, Info, Stats} <- Rows, is_map(Info), is_list(Stats)]}
      end,
      Rules = case catch emqx_rule_engine:get_rules() of
        Rs when is_list(Rs) ->
          [{maps:get(id, R, undefined), maps:get(enable, R, undefined), maps:get(sql, R, undefined),
            case catch emqx_metrics_worker:get_metrics(rule_metrics, maps:get(id, R, undefined)) of
              #{counters := C} -> C;
              _ -> #{}
            end} || R <- lists:sublist(Rs, 200), is_map(R)];
        _ -> []
      end,
      Actions = case catch emqx_bridge_v2:list() of
        Bs when is_list(Bs) ->
          [{maps:get(type, B, undefined), maps:get(name, B, undefined),
            maps:get(enable, maps:get(raw_config, B, B), undefined),
            maps:get(status, maps:get(resource_data, B, B), undefined),
            maps:get(error, maps:get(resource_data, B, B), undefined),
            case catch emqx_bridge_v2:get_metrics(maps:get(type, B, undefined), maps:get(name, B, undefined)) of
              #{counters := C} -> C;
              M when is_map(M) -> M;
              _ -> #{}
            end} || B <- lists:sublist(Bs, 200), is_map(B)];
        _ -> []
      end,
      {ok, Vsn, catch emqx_metrics:all(), catch emqx_stats:getstats(), Listeners, Alarms,
       catch mria:running_nodes(), catch mria:cluster_nodes(all), catch emqx_olp:is_overloaded(),
       Chans, Rules, Actions, erlang:system_time(millisecond)}
  end.
  """

  @doc "EMQX on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_emqx ->
          {:error, "this node doesn't run EMQX (no emqx_release module)"}

        _ ->
          t0 = System.monotonic_time(:millisecond)
          Process.sleep(duration_ms)

          with {:ok, last} <- snapshot() do
            elapsed = max(System.monotonic_time(:millisecond) - t0, 1)
            {:ok, analyze(first, last, elapsed)}
          end
      end
    end
  end

  defp snapshot, do: Checks.remote_eval(@snapshot, MaxChannels: @max_channels)

  # -- Analysis ------------------------------------------------------------------

  defp analyze(
         {:ok, vsn, metrics, stats, _listeners, alarms, running, all, olp, {chan_count, chans},
          rules, actions, _now},
         {:ok, _, last_metrics, last_stats, last_listeners, _, _, _, _, {_, last_chans},
          last_rules, last_actions, now},
         elapsed
       ) do
    m0 = Map.new(list(metrics))
    m1 = Map.new(list(last_metrics))
    rate = fn key -> Float.round(((m1[key] || 0) - (m0[key] || 0)) * 1000 / elapsed, 1) end
    stats = Map.new(list(last_stats || stats))

    running = list(running)
    stopped = list(all) -- running

    window =
      %{
        connects_per_s: rate.(:"packets.connect.received"),
        disconnects_per_s: rate.(:"client.disconnected"),
        messages_received_per_s: rate.(:"messages.received"),
        messages_delivered_per_s: rate.(:"messages.delivered"),
        dropped_per_s:
          %{
            queue_full: rate.(:"delivery.dropped.queue_full"),
            expired: rate.(:"delivery.dropped.expired"),
            too_large: rate.(:"delivery.dropped.too_large"),
            qos0_queue_full: rate.(:"delivery.dropped.qos0_msg"),
            no_subscribers: rate.(:"messages.dropped.no_subscribers"),
            await_pubrel_timeout: rate.(:"messages.dropped.await_pubrel_timeout")
          }
          |> Enum.reject(fn {_, v} -> v == 0 end)
          |> Map.new(),
        sessions_taken_over_per_s: rate.(:"session.takenover"),
        sessions_discarded_per_s: rate.(:"session.discarded"),
        authentication_failures_per_s: rate.(:"authentication.failure"),
        authorization_denied_per_s: rate.(:"authorization.deny")
      }

    report =
      %{
        version: to_string(vsn),
        cluster:
          %{running: Enum.map(running, &to_string/1)}
          |> put(:stopped, stopped != [] && Enum.map(stopped, &to_string/1)),
        overloaded: olp == true,
        listeners: Enum.map(last_listeners, &listener/1),
        clients: %{
          connections: stats[:"connections.count"],
          live_connections: stats[:"live_connections.count"],
          sessions: stats[:"sessions.count"],
          subscriptions: stats[:"subscriptions.count"],
          topics: stats[:"topics.count"],
          retained: stats[:"retained.count"],
          channels_read: length(last_chans),
          channels: chan_count
        },
        window: Map.put(window, :ms, elapsed)
      }
      |> put(:alarms, alarms != [] && Enum.map(alarms, &alarm/1))
      |> put(:slow_consumers, slow_consumers(last_chans))
      |> put(:reconnecting, reconnecting(chans, last_chans, now, elapsed))
      |> put(:rules, rules(rules, last_rules))
      |> put(:actions, actions(actions, last_actions))

    notes = findings(report) |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp list(l) when is_list(l), do: l
  defp list(_), do: []

  defp listener({id, running, bind, current, max}) do
    %{
      listener: to_string(id),
      bind: bind_text(bind),
      running: running == true,
      connections: if(is_integer(current), do: current),
      max_connections: if(is_integer(max) or max == :infinity, do: max)
    }
  end

  defp bind_text({ip, port}) when is_tuple(ip), do: "#{:inet.ntoa(ip)}:#{port}"
  defp bind_text(port) when is_integer(port), do: ":#{port}"
  defp bind_text(other), do: Format.inspect(other)

  defp alarm(a) do
    %{name: Format.inspect(a[:name] || :unknown), message: text(a[:message])}
    |> put(:details, a[:details] && Format.inspect(a[:details], limit: 10))
  end

  defp text(b) when is_binary(b), do: b
  defp text(nil), do: nil
  defp text(other), do: Format.inspect(other, limit: 10)

  # Channels that can't keep up: messages in flight unacknowledged up to
  # the window, a full queue, or dropped from it, most dropped first. EMQX
  # refreshes a channel's stats in its table every so often, not on every
  # message: they're its latest.
  defp slow_consumers(last_chans) do
    rows =
      for {id, pid, _, _, _, _, s} <- last_chans,
          s = Map.new(s),
          full?(s[:inflight_cnt], s[:inflight_max]) or full?(s[:mqueue_len], s[:mqueue_max]) or
            (s[:mqueue_dropped] || 0) > 0 do
        %{
          client_id: to_string(id),
          pid: Format.inspect(pid),
          in_flight: "#{s[:inflight_cnt]} of #{max_text(s[:inflight_max])}",
          queued: "#{s[:mqueue_len]} of #{max_text(s[:mqueue_max])}",
          dropped: s[:mqueue_dropped] || 0,
          delivered: s[:send_msg],
          memory_bytes: s[:memory]
        }
      end
      |> Enum.sort_by(&(-&1.dropped))
      |> Enum.take(10)

    rows != [] && rows
  end

  defp full?(n, max) when is_integer(n) and is_integer(max) and max > 0, do: n >= max
  defp full?(_, _), do: false

  defp max_text(:infinity), do: "no limit"
  defp max_text(n), do: n

  # Client ids whose connection changed between the samples, or connected
  # during the window: reconnecting.
  defp reconnecting(chans, last_chans, now, elapsed) do
    before = Map.new(chans, fn {id, pid, _, _, _, _, _} -> {id, pid} end)

    ids =
      for {id, pid, _, connected_at, _, _, _} <- last_chans,
          (Map.has_key?(before, id) and before[id] != pid) or
            (is_integer(connected_at) and now - connected_at < elapsed),
          uniq: true,
          do: to_string(id)

    ids != [] && %{clients: length(ids), some: Enum.take(Enum.sort(ids), 10)}
  end

  defp rules(rules, last_rules) do
    before = Map.new(rules, fn {id, _, _, c} -> {id, c} end)

    rows =
      for {id, enable, sql, c} <- last_rules do
        c0 = before[id] || %{}
        delta = fn k -> (c[k] || 0) - (c0[k] || 0) end

        %{
          rule: to_string(id),
          enabled: enable != false,
          sql: text(sql),
          matched: c[:matched],
          failed: c[:failed],
          failed_in_window: delta.(:failed),
          actions_failed_in_window: delta.(:"actions.failed")
        }
      end

    rows != [] && rows
  end

  defp actions(actions, last_actions) do
    before = Map.new(actions, fn {t, n, _, _, _, c} -> {{t, n}, c} end)

    rows =
      for {type, name, enable, status, error, c} <- last_actions do
        c0 = before[{type, name}] || %{}
        delta = fn k -> (c[k] || 0) - (c0[k] || 0) end

        %{action: "#{type}:#{name}", enabled: enable != false, status: text(status)}
        |> put(:error, error && text(error))
        |> put(:queuing, c[:queuing])
        |> put(:dropped_in_window, delta.(:dropped))
        |> put(:failed_in_window, delta.(:failed))
      end

    rows != [] && rows
  end

  # -- Findings ------------------------------------------------------------------

  defp findings(r) do
    w = r.window

    overloaded =
      if r.overloaded,
        do: [
          {:critical,
           "EMQX's overload protection is on: it's shedding load (refusing new connections, hibernating, dropping)"}
        ],
        else: []

    cluster =
      case r.cluster[:stopped] do
        [_ | _] = s -> [{:warning, "cluster nodes not running: #{Enum.join(s, ", ")}"}]
        _ -> []
      end

    alarms =
      for a <- r[:alarms] || [] do
        {:warning, "EMQX alarm #{a.name}: #{a.message}"}
      end

    listeners =
      for l <- r.listeners,
          finding = listener_finding(l),
          finding != nil,
          do: finding

    slow =
      case r[:slow_consumers] do
        [top | _] = list ->
          [
            {:warning,
             "#{length(list)} clients can't keep up; #{top.client_id} has #{top.in_flight} messages in flight unacknowledged and #{top.queued} queued, and has had #{top.dropped} dropped#{if (w.dropped_per_s[:queue_full] || 0) > 0, do: " (EMQX drops #{w.dropped_per_s.queue_full} a second for full queues now)", else: ""}: EMQX keeps QoS 1 and 2 messages in flight until the client acknowledges them, queues the rest, and drops what doesn't fit (delivery.dropped.queue_full). A client that never acknowledges, or reads too slowly, misses messages"}
          ]

        _ ->
          []
      end

    drops =
      case Map.drop(w.dropped_per_s, [:queue_full]) do
        m when map_size(m) > 0 ->
          [
            {:info,
             "messages dropped a second, by reason: #{Enum.map_join(m, ", ", fn {k, v} -> "#{k} #{v}" end)}"}
          ]

        _ ->
          []
      end

    churn = w.sessions_taken_over_per_s + w.sessions_discarded_per_s

    clash =
      if churn >= 1 do
        some =
          case r[:reconnecting] do
            %{some: [_ | _] = ids} -> " (reconnecting in the window: #{Enum.join(ids, ", ")})"
            _ -> ""
          end

        [
          {:warning,
           "#{churn} sessions a second taken over or discarded, with #{w.connects_per_s} connects a second#{some}: clients reconnecting with a client id already connected, which kicks the other off; two devices sharing one client id kick each other off forever"}
        ]
      else
        []
      end

    auth =
      if w.authentication_failures_per_s > 0,
        do: [
          {:warning,
           "#{w.authentication_failures_per_s} authentication failures a second: clients with wrong credentials, often retrying in a loop"}
        ],
        else: []

    rules =
      for rule <- r[:rules] || [],
          rule.failed_in_window > 0 or rule.actions_failed_in_window > 0 do
        {:warning,
         "rule #{rule.rule} failed #{rule.failed_in_window} times in the window, its actions #{rule.actions_failed_in_window} times: #{rule.sql}"}
      end

    actions =
      for a <- r[:actions] || [],
          a.enabled,
          a.status not in ["connected", nil] or (a[:dropped_in_window] || 0) > 0 do
        {:warning,
         "action #{a.action} is #{a.status}#{if a[:error], do: " (#{a.error})", else: ""}#{if a[:queuing], do: ", #{a.queuing} messages queuing", else: ""}#{if (a[:dropped_in_window] || 0) > 0, do: ", #{a.dropped_in_window} dropped in the window", else: ""}"}
      end

    overloaded ++
      cluster ++ alarms ++ listeners ++ slow ++ drops ++ clash ++ auth ++ rules ++ actions
  end

  defp listener_finding(%{running: false} = l),
    do: {:critical, "listener #{l.listener} (#{l.bind}) isn't running: its clients can't connect"}

  defp listener_finding(%{connections: c, max_connections: m} = l)
       when is_integer(c) and is_integer(m) and m > 0 and c >= 0.8 * m,
       do: {:warning, "listener #{l.listener} (#{l.bind}) has #{c} of #{m} connections"}

  defp listener_finding(_), do: nil

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
    cluster is the nodes running (and stopped) by mria; overloaded is
    EMQX's overload protection. alarms are EMQX's own, active now
    (high_system_memory, too_many_processes, conn_congestion...).
    listeners: their connections against max_connections. clients are
    EMQX's counts. window is its counters over the sample: connects,
    messages received and delivered, dropped a second by reason
    (queue_full: a client's queue full; expired: queued past its expiry;
    no_subscribers: published where nobody listens), sessions taken over
    (the same client id connecting again) or discarded, and authentication
    failures. slow_consumers are clients from the channel table with
    messages in flight up to their window (unacknowledged), a full queue,
    or drops, the most dropping now first. reconnecting are client ids
    whose connection changed during the window; a channel's stats are as
    EMQX last refreshed them in its table, every so often. rules and actions: their
    failures in the window, and actions not connected or dropping. Up to
    the first 20,000 channels are read. Next step: process_info on a slow
    consumer's pid; recent_errors for EMQX's own log of kicked or failing
    clients; the client's code, for acknowledging and for its client id.
    """
  end
end
