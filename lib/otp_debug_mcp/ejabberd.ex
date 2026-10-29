defmodule OtpDebugMcp.Ejabberd do
  @moduledoc """
  ejabberd, the XMPP server, on a node of its cluster, sampled at the
  start and the end of a window, through its own APIs and tables: its
  version, hosts, database and cluster; its sessions, and the client
  connections (c2s processes) that are backed up, and whose they are;
  the users with the most offline messages; the message archive; the
  busiest MUC rooms; server-to-server connections; and ejabberd's own
  processes with long mailboxes.

  A c2s process archives each stanza for its user (mod_mam), then sends
  it to the client's socket. ejabberd's p1_server moves its mailbox into
  a queue of its own, on the heap, so a connection that can't keep up
  shows in that queue and in memory, not in message_queue_len. A client
  that stops reading blocks the process sending until send_timeout
  closes the socket; the session stays until the process gets through
  its queue. Messages for a user who's offline are kept by mod_offline,
  up to max_user_offline_messages; past that they're bounced to the
  sender.

  Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Sessions and users with offline messages looked at, at most.
  @max_sessions 20_000
  @max_offline_users 2_000

  @snapshot ~S"""
  case catch ejabberd_option:version() of
    {'EXIT', _} -> not_ejabberd;
    Vsn ->
      Hosts = case catch ejabberd_option:hosts() of L when is_list(L) -> L; _ -> [] end,
      %% Sessions: {session, Sid = {Time, Pid}, USR, US, Priority, Info}.
      Sessions = case catch mnesia:dirty_select(session, [{'_', [], ['$_']}]) of
        S when is_list(S) -> lists:sublist(S, MaxSessions);
        _ -> []
      end,
      %% Each local session's c2s process: its mailbox and memory, whether
      %% it still has its socket, and, when it's big, what it's doing.
      Conn = fun(Pid) ->
        case erlang:process_info(Pid, [message_queue_len, memory, current_function, links]) of
          undefined -> undefined;
          [Q, {memory, Mem} = M, F, {links, Links}] ->
            %% p1_server moves the mailbox into a queue of its own, and
            %% keeps its length in the process dictionary.
            Queued = case catch erlang:process_info(Pid, {dictionary, '$internal_queue_len'}) of
              {{dictionary, '$internal_queue_len'}, N} when is_integer(N) -> N;
              _ -> case erlang:process_info(Pid, dictionary) of
                     {dictionary, D} -> proplists:get_value('$internal_queue_len', D, 0);
                     _ -> 0
                   end
            end,
            Big = element(2, Q) + Queued > 10 orelse Mem > 1000000,
            Stack = case Big andalso erlang:process_info(Pid, current_stacktrace) of
              {current_stacktrace, St} -> [{Mod, Fun, Ar} || {Mod, Fun, Ar, _} <- lists:sublist(St, 8)];
              _ -> []
            end,
            [Q, {queued, Queued}, M, F, {socket, lists:any(fun erlang:is_port/1, Links)}, {stack, Stack}]
        end
      end,
      Conns = [{element(2, element(2, S)), element(3, S), element(1, element(2, S)),
                Conn(element(2, element(2, S)))}
               || S <- Sessions, is_tuple(element(2, S)), is_pid(element(2, element(2, S))),
                  node(element(2, element(2, S))) =:= node()],
      %% Offline messages, by user.
      Offline = case catch mnesia:dirty_all_keys(offline_msg) of
        Keys when is_list(Keys) ->
          %% With the user's limit, max_user_offline_messages.
          [{K, length(catch mnesia:dirty_read(offline_msg, K)),
            catch ejabberd_shaper:match(element(2, K), mod_offline_opt:access_max_user_messages(element(2, K)),
                                        jid:make(element(1, K), element(2, K), <<>>))}
           || K <- lists:sublist(Keys, MaxOffline)];
        _ -> []
      end,
      OfflineTotal = case catch mnesia:table_info(offline_msg, size) of N when is_integer(N) -> N; _ -> undefined end,
      Rooms = lists:append([case catch mod_muc:get_online_rooms(H) of
                              Rs when is_list(Rs) -> Rs;
                              _ -> []
                            end || H <- Hosts]),
      RoomInfo = [{Name, RHost, catch erlang:process_info(Pid, [message_queue_len, memory])}
                  || {Name, RHost, Pid} <- lists:sublist(Rooms, 5000), is_pid(Pid)],
      Core = [{N, Q} || N <- [ejabberd_router, ejabberd_sm, ejabberd_local, ejabberd_s2s,
                              ejabberd_router_multicast, ejabberd_hooks, ejabberd_cluster],
                        P <- [whereis(N)], is_pid(P),
                        {message_queue_len, Q} <- [erlang:process_info(P, message_queue_len)]]
             ++ [{N, Q} || N <- registered(),
                           lists:prefix("mod_", atom_to_list(N)),
                           P <- [whereis(N)], is_pid(P),
                           {message_queue_len, Q} <- [erlang:process_info(P, message_queue_len)],
                           Q > 100],
      %% The message archive (mod_mam): its backend, and on Mnesia the
      %% archive_msg table, with how long one look at it takes.
      MamHosts = [H || H <- Hosts, catch gen_mod:is_loaded(H, mod_mam) =:= true],
      Mam = case MamHosts of
        [] -> undefined;
        [MH | _] ->
          Db = catch mod_mam_opt:db_type(MH),
          Table = case Db =:= mnesia andalso catch mnesia:table_info(archive_msg, storage_type) of
            Type when is_atom(Type), Type =/= false ->
              {Us, Mem} = timer:tc(fun() -> mnesia:table_info(archive_msg, memory) end),
              {Type, mnesia:table_info(archive_msg, size),
               case Type of disc_only_copies -> Mem; _ -> Mem * erlang:system_info(wordsize) end, Us};
            _ -> undefined
          end,
          {MamHosts, Db, Table}
      end,
      {ok, Vsn, Hosts, catch ejabberd_option:default_db(),
       catch ejabberd_cluster:get_nodes(), catch ejabberd_cluster:get_known_nodes(),
       catch ejabberd_sm:connected_users_number(),
       [{H, catch ejabberd_sm:get_vh_session_number(H)} || H <- Hosts],
       length(Sessions), Conns, OfflineTotal, Offline, length(Rooms), RoomInfo,
       catch ejabberd_s2s:incoming_s2s_number(), catch ejabberd_s2s:outgoing_s2s_number(),
       Core, Mam, erlang:system_time(microsecond)}
  end.
  """

  @doc "ejabberd on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_ejabberd ->
          {:error, "this node doesn't run ejabberd (no ejabberd_option module)"}

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

  defp snapshot,
    do: Checks.remote_eval(@snapshot, MaxSessions: @max_sessions, MaxOffline: @max_offline_users)

  # -- Analysis ------------------------------------------------------------------

  defp analyze(first, last, elapsed) do
    {:ok, vsn, hosts, db, running, known, _users, _per_host, _sessions, conns, offline_total,
     offline, _rooms, _room_info, _, _, _core, mam, _} = first

    {:ok, _, _, _, running1, known1, users1, per_host1, sessions1, conns1, offline_total1,
     offline1, rooms1, room_info1, s2s_in, s2s_out, core1, mam1, now} = last

    running = list(running1 || running)
    down = list(known1 || known) -- running

    report =
      %{
        version: to_string(vsn),
        hosts: hosts,
        database: Format.inspect(db),
        cluster:
          %{running: Enum.map(running, &to_string/1)}
          |> put(:down, down != [] && Enum.map(down, &to_string/1)),
        sessions: %{
          users_online: users1,
          by_host: Map.new(per_host1, fn {h, n} -> {h, n} end),
          read: sessions1
        },
        s2s: %{incoming: s2s_in, outgoing: s2s_out},
        rooms_online: rooms1,
        window_ms: elapsed
      }
      |> put(:backed_up_clients, backed_up(conns, conns1, now, elapsed))
      |> put(:offline, offline(offline_total, offline_total1, offline, offline1, elapsed))
      |> put(:busy_rooms, busy_rooms(room_info1))
      |> put(:busy_core, busy_core(core1))
      |> put(:archive, archive(mam, mam1, elapsed))

    notes = findings(report) |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp list(l) when is_list(l), do: l
  defp list(_), do: []

  # Client connections (c2s processes) backed up: stanzas waiting in the
  # mailbox or, mostly, in the queue p1_server moves the mailbox into, on
  # the heap. Most waiting first, with how much they grew over the window.
  defp backed_up(conns, conns1, now, elapsed) do
    before = Map.new(conns, fn {pid, _, _, info} -> {pid, info} end)

    rows =
      for {pid, {user, server, resource}, since, info} <- conns1,
          is_list(info),
          waiting(info) > 10 or info[:memory] > 1_000_000 do
        info0 = before[pid]

        %{
          jid: "#{user}@#{server}/#{resource}",
          pid: Format.inspect(pid),
          queued: info[:queued],
          mailbox: info[:message_queue_len],
          memory_bytes: info[:memory],
          socket_open: info[:socket],
          now_in: mfa(info[:current_function]),
          stack: Enum.map(info[:stack], &mfa/1),
          connected_s: connected(since, now)
        }
        |> put(
          :memory_growth_bytes_per_s,
          is_list(info0) && round((info[:memory] - info0[:memory]) * 1000 / elapsed)
        )
        |> put(
          :waiting_growth_per_s,
          is_list(info0) && Float.round((waiting(info) - waiting(info0)) * 1000 / elapsed, 1)
        )
      end
      |> Enum.sort_by(&{-(&1.queued + &1.mailbox), -&1.memory_bytes})
      |> Enum.take(10)

    rows != [] && rows
  end

  defp offline(total, total1, offline, offline1, elapsed) do
    before = Map.new(offline, fn {us, n, _} -> {us, n} end)

    top =
      offline1
      |> Enum.sort_by(fn {_, n, _} -> -n end)
      |> Enum.take(10)
      |> Enum.map(fn {{user, server}, n, limit} ->
        %{user: "#{user}@#{server}", messages: n}
        |> put(:limit, is_integer(limit) && limit)
        |> put(:full, is_integer(limit) && n >= limit)
        |> put(:growth_in_window, (n - Map.get(before, {user, server}, n)) |> nonzero())
      end)

    total1 &&
      %{messages: total1, users: length(offline1)}
      |> put(
        :growth_per_s,
        is_integer(total) && Float.round((total1 - total) * 1000 / elapsed, 1)
      )
      |> put(:most, top != [] && top)
  end

  defp waiting(info), do: info[:message_queue_len] + info[:queued]

  # A session's id starts with when it was opened, erlang:timestamp() style.
  defp connected({mega, s, us}, now),
    do: div(now - (mega * 1_000_000 + s) * 1_000_000 - us, 1_000_000)

  defp connected(_, _), do: nil

  defp nonzero(0), do: false
  defp nonzero(n), do: n

  defp busy_rooms(rooms) do
    rows =
      for {name, host, info} <- rooms, is_list(info), (info[:message_queue_len] || 0) > 100 do
        %{room: "#{name}@#{host}", mailbox: info[:message_queue_len], memory_bytes: info[:memory]}
      end
      |> Enum.sort_by(&(-&1.mailbox))
      |> Enum.take(5)

    rows != [] && rows
  end

  defp archive(mam, {hosts, db, table}, elapsed) do
    %{hosts: hosts, backend: Format.inspect(db)}
    |> put(:table, archive_table(table))
    |> put(:messages_archived_per_s, archived(mam, table, elapsed))
  end

  defp archive(_, _, _), do: false

  defp archive_table({type, size, bytes, us}),
    do: %{
      name: "archive_msg",
      storage: type,
      messages: size,
      bytes: bytes,
      one_look_ms: Float.round(us / 1000, 1)
    }

  defp archive_table(_), do: false

  defp archived({_, _, {_, size0, _, _}}, {_, size1, _, _}, elapsed),
    do: Float.round((size1 - size0) * 1000 / elapsed, 1)

  defp archived(_, _, _), do: false

  defp busy_core(core) do
    rows = for {name, q} <- core, q > 100, do: %{process: Atom.to_string(name), mailbox: q}
    rows != [] && rows
  end

  defp mfa({m, f, a}) when is_integer(a), do: "#{m}:#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  # -- Findings ------------------------------------------------------------------

  defp findings(r) do
    cluster =
      case r.cluster[:down] do
        [_ | _] = d -> [{:warning, "cluster nodes known but not running: #{Enum.join(d, ", ")}"}]
        _ -> []
      end

    clients =
      case r[:backed_up_clients] do
        [top | _] = list ->
          [
            {if(top.memory_bytes > 50_000_000 or top.queued + top.mailbox > 10_000,
               do: :critical,
               else: :warning
             ),
             "#{length(list)} client #{if length(list) == 1, do: "connection is", else: "connections are"} backed up; #{top.jid}'s c2s process has #{top.queued + top.mailbox} stanzas waiting#{growth(top)}, in #{div(top.memory_bytes, 1_000_000)} MB: #{top.queued} in the queue ejabberd's p1_server keeps on the heap (where it moves the mailbox, so the mailbox, #{top.mailbox}, stays short). " <>
               doing(top) <>
               " Everything sent to that session waits there, and the user gets it late or not at all"}
          ]

        _ ->
          []
      end

    offline =
      case r[:offline] do
        %{most: [top | _] = most} ->
          full = Enum.filter(most, & &1[:full])

          case full do
            [_ | _] ->
              [
                {:warning,
                 "#{Enum.map_join(full, ", ", &"#{&1.user} (#{&1.messages})")} #{if length(full) == 1, do: "has", else: "have"} as many offline messages as max_user_offline_messages allows: every new message to #{if length(full) == 1, do: "that user", else: "them"} is bounced back to its sender with an error and lost, until they log in and read the queue"}
              ]

            [] ->
              [
                {:info,
                 "#{top.user} has #{top.messages} offline messages#{if top[:limit], do: " of #{top.limit} allowed", else: ""}#{if top[:growth_in_window], do: " (#{top.growth_in_window} more in the window)", else: ""}: kept until the user logs in; past max_user_offline_messages new ones are bounced"}
              ]
          end

        _ ->
          []
      end

    rooms =
      for room <- r[:busy_rooms] || [] do
        {:warning, "room #{room.room} has #{room.mailbox} messages waiting in its process"}
      end

    core =
      for p <- r[:busy_core] || [] do
        {:warning, "ejabberd's #{p.process} has #{p.mailbox} messages queued: it can't keep up"}
      end

    archive =
      case r[:archive] do
        %{backend: ":mnesia", table: %{storage: :disc_only_copies} = t} = a ->
          slow? = t.one_look_ms >= 20
          waiting = Enum.count(r[:backed_up_clients] || [], &archiving?/1)

          if slow? or waiting > 0 do
            [
              {:warning,
               "the message archive (mod_mam) is on Mnesia, in a disc_only_copies table (a dets file): archive_msg holds #{t.messages} messages, #{div(t.bytes, 1_000_000)} MB#{if a[:messages_archived_per_s], do: ", #{a.messages_archived_per_s} more a second", else: ""}, and one look at it took #{t.one_look_ms} ms. Every message delivered is archived by the recipient's c2s process before it goes on#{cond do
                 waiting == 1 -> "; a backed-up connection is waiting on it"
                 waiting > 1 -> "; #{waiting} backed-up connections are waiting on it"
                 true -> ""
               end}. Mnesia doesn't suit MAM beyond small servers (dets files are limited to 2 GB too); ejabberd's documentation recommends an SQL backend for it"}
            ]
          else
            []
          end

        _ ->
          []
      end

    cluster ++ clients ++ offline ++ rooms ++ core ++ archive
  end

  defp archiving?(c), do: Enum.any?([c.now_in | c.stack], &String.starts_with?(&1, "mod_mam"))

  defp growth(%{waiting_growth_per_s: g}) when g > 0, do: ", #{g} more a second"

  defp growth(_), do: ""

  defp doing(c) do
    frames = [c.now_in | c.stack]
    archive? = archiving?(c)
    sending? = Enum.any?(frames, &(&1 =~ ~r/^(prim_inet|gen_tcp|ssl|fast_tls):send/))

    cond do
      not c.socket_open ->
        "Its socket is closed (the client stopped reading, and ejabberd's send_timeout gave up on it), but the session is still open: the process is still working through what was queued for it#{if archive?, do: ", archiving each message (mod_mam) on the way", else: ""}."

      sending? ->
        "It's blocked sending to the client, which isn't reading its socket fast enough."

      archive? ->
        "It's archiving each message (mod_mam) before passing it on, which is where it is now: see the archive."

      true ->
        "It's now in #{c.now_in}."
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
    cluster: ejabberd's nodes running, and those known but down. sessions:
    users online, by host. backed_up_clients are client connections (c2s
    processes) with stanzas waiting, most first: queued is p1_server's
    own queue, on the heap, where ejabberd moves the mailbox, so the
    mailbox stays short. With their JID, memory, growth over the window,
    whether the socket's still open, and where the process is: in a
    socket send it's blocked on a client that doesn't read; in mod_mam,
    archiving. offline is mod_offline's queue: messages kept for users who
    aren't online, the users with most, and growth; past
    max_user_offline_messages, messages are bounced. busy_rooms and
    busy_core are MUC rooms and ejabberd's own processes (router, session
    manager...) with long mailboxes. archive is the message archive
    (mod_mam): its backend, and on Mnesia the archive_msg table, its size
    and how long one look at it took. ejabberd keeps its data in Mnesia by
    default: the mnesia tool shows its tables and transactions. Next
    step: process_info on a backed-up c2s pid; recent_errors for
    ejabberd's log; for offline messages, the account or the client that
    should be reading them.
    """
  end
end
