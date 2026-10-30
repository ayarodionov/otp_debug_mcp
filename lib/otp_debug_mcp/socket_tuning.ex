defmodule OtpDebugMcp.SocketTuning do
  @moduledoc """
  Every TCP and UDP socket on the node (inet ports), its options and its
  statistics, read twice a window apart, grouped by what owns them, with
  the settings that cost latency or throughput:

  - **Nagle with small writes.** A TCP socket with `nodelay` false holds
    a small write back until the previous one is acknowledged, and the
    peer delays its acknowledgement (up to 40 ms on Linux, more on some
    systems): a request written in two pieces, or a reply after a small
    write, waits that long. `{nodelay, true}` for request/response
    protocols.
  - **`{active, true}` with a mailbox backing up.** The socket sends its
    owner every packet as it arrives, with no back pressure: an owner
    slower than its peer fills its mailbox. `{active, once}` or
    `{active, N}` let it take what it can.
  - **Blocked sends.** More than `high_watermark` bytes queued in the
    driver makes every sender to the socket wait (the port is busy):
    bulk senders need a higher watermark and `sndbuf`; a peer that reads
    slowly holds them up, and with `send_timeout` infinity forever.
  - **Big reads through a small buffer.** The user-level `buffer` caps
    what one read takes; high-throughput sockets want it, and `recbuf`,
    larger.
  - **Idle connections with keepalive off**, which a vanished peer keeps
    open; `delay_send`, which trades latency for fewer writes; UDP
    receive buffers small for their traffic, which the kernel drops past.

  Sockets of the `socket` module (and gen_tcp with `inet_backend:
  socket`) aren't ports, and aren't seen. Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Format}

  @max_sockets 5_000

  @snapshot ~S"""
  Opts = [active, nodelay, sndbuf, recbuf, buffer, keepalive, send_timeout, send_timeout_close,
          delay_send, high_watermark, low_watermark, packet, linger],
  Stats = [recv_oct, recv_cnt, recv_max, send_oct, send_cnt, send_max, send_pend],
  Kinds = [{"tcp_inet", tcp}, {"udp_inet", udp}, {"sctp_inet", sctp}],
  Socks = lists:sublist([{P, K} || P <- erlang:ports(),
                                   {name, Name} <- [erlang:port_info(P, name)],
                                   {N, K} <- Kinds, N =:= Name], MaxSockets),
  %% What an owner is: its registered name, its initial call (a gen_server
  %% callback module's init), or, for a plain spawned process, the first
  %% function in its stack that isn't OTP's.
  Skip = [erlang, gen_tcp, gen_udp, gen_sctp, prim_inet, inet, inet_tcp, inet_udp, gen, gen_server,
          gen_statem, proc_lib, timer, lists, 'Elixir.Stream', 'Elixir.Enum', 'Elixir.Process'],
  Owner = fun(Pid) ->
    case erlang:process_info(Pid, [registered_name, dictionary, initial_call, current_function,
                                   message_queue_len, status, current_stacktrace]) of
      undefined -> undefined;
      I ->
        D = proplists:get_value(dictionary, I),
        Frame = case [{M, F, A} || {M, F, A, _} <- proplists:get_value(current_stacktrace, I),
                                   not lists:member(M, Skip)] of
          [{FM, FF, FA} | _] -> {FM, FF, case is_list(FA) of true -> length(FA); false -> FA end};
          [] -> undefined
        end,
        Label = case {proplists:get_value(registered_name, I), proplists:get_value('$initial_call', D)} of
          {N, _} when is_atom(N), N =/= [] -> {name, N};
          {_, {IM, IF, IA}} when IM =/= proc_lib, IM =/= erlang -> {initial_call, {IM, IF, IA}};
          _ when Frame =/= undefined -> {initial_call, Frame};
          _ -> {initial_call, proplists:get_value(initial_call, I)}
        end,
        {Label, proplists:get_value(current_function, I), proplists:get_value(message_queue_len, I),
         proplists:get_value(status, I)}
    end
  end,
  Rows = [begin
            O = case erlang:port_info(P, connected) of {connected, C} -> C; _ -> undefined end,
            Peer = case inet:peername(P) of {ok, Pe} -> Pe; _ -> undefined end,
            Local = case inet:sockname(P) of {ok, L} -> L; _ -> undefined end,
            Listening = K =:= tcp andalso Peer =:= undefined andalso
                        case catch prim_inet:getstatus(P) of
                          {ok, St} -> lists:member(listen, St);
                          _ -> false
                        end,
            {P, K, Listening, Local, Peer,
             case inet:getopts(P, Opts) of {ok, Os} -> Os; _ -> [] end,
             case inet:getstat(P, Stats) of {ok, Ss} -> Ss; _ -> [] end,
             case erlang:port_info(P, queue_size) of {queue_size, Q} -> Q; _ -> 0 end,
             O}
          end || {P, K} <- Socks],
  Owners = lists:usort([O || {_, _, _, _, _, _, _, _, O} <- Rows, is_pid(O)]),
  {ok, Rows, [{O, Owner(O)} || O <- Owners], length(Socks), erlang:monotonic_time(millisecond)}.
  """

  @doc "The node's sockets, sampled `duration_ms` apart, with tuning findings."
  def report(duration_ms, opts \\ []) do
    with {:ok, first} <- snapshot() do
      Process.sleep(duration_ms)

      with {:ok, last} <- snapshot() do
        {:ok, analyze(first, last, opts)}
      end
    end
  end

  defp snapshot do
    case Checks.remote_eval(@snapshot, MaxSockets: @max_sockets) do
      {:ok, {:ok, rows, owners, count, t}} -> {:ok, {rows, Map.new(owners), count, t}}
      {:ok, other} -> {:error, Format.inspect(other)}
      err -> err
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze({rows0, owners0, _, t0}, {rows, owners, count, t1}, opts) do
    elapsed = max(t1 - t0, 1)
    before = Map.new(rows0, &{elem(&1, 0), &1})

    sockets =
      rows
      |> Enum.map(&socket(&1, before[elem(&1, 0)], owners, owners0, elapsed))
      |> filter(opts)

    groups =
      sockets
      |> Enum.group_by(& &1.owner)
      |> Enum.map(fn {owner, list} -> group(owner, list) end)
      |> Enum.sort_by(&(-(&1.bytes_per_s.in + &1.bytes_per_s.out) - &1.sockets))

    notes = findings(sockets) |> Enum.sort_by(fn {l, _} -> rank(l) end)

    %{
      sockets: length(sockets),
      by_kind: sockets |> Enum.map(& &1.kind) |> Enum.frequencies(),
      window_ms: elapsed,
      groups: Enum.take(groups, 15)
    }
    |> put(:sampled, count >= @max_sockets && "the first #{@max_sockets} sockets")
    |> put(:more_groups, length(groups) > 15 && length(groups) - 15)
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({l, t} <- notes, do: "#{l}: #{t}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp filter(sockets, opts) do
    sockets
    |> then(fn s ->
      case opts[:port] do
        nil -> s
        p -> Enum.filter(s, &(&1.local_port == p or &1.peer_port == p))
      end
    end)
    |> then(fn s ->
      case opts[:owner] do
        nil -> s
        o -> Enum.filter(s, &(&1.owner == o or &1.owner_pid == o))
      end
    end)
  end

  defp socket(
         {port, kind, listening, local, peer, os, ss, queue, owner},
         prev,
         owners,
         owners0,
         elapsed
       ) do
    {label, current, mailbox, status} = owner_info(owners[owner])
    {_, _, mailbox0, _} = owner_info(owners0[owner])
    stat0 = if prev, do: elem(prev, 6), else: nil
    delta = fn key -> if stat0, do: max((ss[key] || 0) - (stat0[key] || 0), 0) end
    per_s = fn n -> if n, do: Float.round(n * 1000 / elapsed, 1) end
    sends = delta.(:send_cnt)
    sent = delta.(:send_oct)

    %{
      port: Format.inspect(port),
      kind: if(listening, do: :tcp_listen, else: kind),
      local: address(local),
      local_port: port_of(local),
      peer: address(peer),
      peer_port: port_of(peer),
      owner: label,
      owner_pid: Format.inspect(owner),
      owner_mailbox: mailbox,
      owner_mailbox_before: mailbox0,
      owner_suspended: status == :suspended,
      owner_in: current,
      options: Map.new(os),
      send_pend: ss[:send_pend] || 0,
      send_pend_before: (stat0 && stat0[:send_pend]) || 0,
      queue: queue,
      recv_max: ss[:recv_max],
      in_per_s: per_s.(delta.(:recv_oct)),
      out_per_s: per_s.(sent),
      sends_per_s: per_s.(sends),
      avg_send: if(sends && sends > 0, do: div(sent, sends)),
      # Writes for every read: 2 or more is a message written in pieces.
      writes_per_read: (r = delta.(:recv_cnt)) && r > 0 && sends && Float.round(sends / r, 1),
      idle: stat0 != nil and delta.(:recv_oct) == 0 and sent == 0,
      seen_before: stat0 != nil
    }
  end

  defp owner_info({label, current, mailbox, status}),
    do: {label(label), mfa(current), mailbox, status}

  defp owner_info(_), do: {"no owner", nil, 0, nil}

  defp label({:name, n}), do: Format.inspect(n)
  defp label({:initial_call, {m, f, a}}), do: mfa({m, f, a})
  defp label(other), do: Format.inspect(other)

  defp mfa({m, f, a}) when is_atom(m) and is_integer(a) do
    if String.starts_with?(Atom.to_string(m), "Elixir."),
      do: "#{Format.inspect(m)}.#{f}/#{a}",
      else: "#{m}:#{f}/#{a}"
  end

  defp mfa(other), do: Format.inspect(other)

  defp address({ip, port}) when is_tuple(ip), do: "#{:inet.ntoa(ip)}:#{port}"
  defp address({:local, path}), do: "unix:#{path}"
  defp address(_), do: nil

  defp port_of({_, port}) when is_integer(port), do: port
  defp port_of(_), do: nil

  # One group: what owns these sockets, how many of which kind, the
  # options they have (the most common value of each), and their traffic.
  defp group(owner, list) do
    common = fn key ->
      list
      |> Enum.map(&Map.get(&1.options, key))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
      |> elem(0)
    end

    sum = fn key -> list |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum() |> Float.round(1) end

    %{
      owner: owner,
      sockets: length(list),
      kinds: list |> Enum.map(& &1.kind) |> Enum.frequencies(),
      bytes_per_s: %{in: sum.(:in_per_s), out: sum.(:out_per_s)},
      sends_per_s: sum.(:sends_per_s),
      options:
        [
          :active,
          :nodelay,
          :packet,
          :sndbuf,
          :recbuf,
          :buffer,
          :high_watermark,
          :send_timeout,
          :keepalive
        ]
        |> Enum.map(&{&1, common.(&1)})
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()
    }
    |> put(
      :local_ports,
      list |> Enum.map(& &1.local_port) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.take(5)
    )
    |> put(
      :send_pend_max,
      Enum.max(Enum.map(list, & &1.send_pend)) > 0 && Enum.max(Enum.map(list, & &1.send_pend))
    )
    |> put(
      :owner_mailbox_max,
      Enum.max(Enum.map(list, & &1.owner_mailbox)) > 0 &&
        Enum.max(Enum.map(list, & &1.owner_mailbox))
    )
  end

  # -- Findings ------------------------------------------------------------------

  defp findings(sockets) do
    by_owner = fn list -> Enum.group_by(list, & &1.owner) end
    tcp = Enum.filter(sockets, &(&1.kind == :tcp and &1.seen_before))

    # Small writes, many of them, with Nagle on.
    nagle =
      tcp
      |> Enum.filter(fn s ->
        s.options[:nodelay] == false and (s.sends_per_s || 0) >= 5 and is_integer(s.avg_send) and
          s.avg_send < 1_000
      end)
      |> by_owner.()
      |> Enum.map(fn {owner, list} ->
        avg = div(Enum.sum(Enum.map(list, & &1.avg_send)), length(list))
        rate = list |> Enum.map(& &1.sends_per_s) |> Enum.sum() |> Float.round(1)
        ratios = list |> Enum.map(& &1.writes_per_read) |> Enum.filter(&is_number/1)
        pieces = ratios != [] && Enum.sum(ratios) / length(ratios)
        n = length(list)

        what =
          "#{n} TCP #{plural(n, "socket")} owned by #{owner} #{if n == 1, do: "makes", else: "make"} small writes (#{avg} bytes on average, #{rate} a second) with Nagle's algorithm on (nodelay false)"

        if pieces && pieces >= 1.5 do
          {:warning,
           "#{what}, #{Float.round(pieces, 1)} writes for every read: each message written in pieces. Nagle holds a write back until the previous one is acknowledged, and the peer delays its acknowledgement, up to 40 ms on Linux, so every such message waits that long. {nodelay, true}, or the message in one write (an iolist)"}
        else
          {:info,
           "#{what}, one per read: Nagle costs only when a write follows another before it's acknowledged, which a request/response exchange doesn't do; {nodelay, true} anyway if any message is written in pieces"}
        end
      end)

    flood =
      sockets
      |> Enum.filter(fn s ->
        s.options[:active] == true and s.owner_mailbox >= 1_000 and
          s.owner_mailbox >= s.owner_mailbox_before
      end)
      |> by_owner.()
      |> Enum.map(fn {owner, [s | _] = list} ->
        {if(s.owner_mailbox >= 100_000, do: :critical, else: :warning),
         "#{owner} has #{s.owner_mailbox} messages waiting#{if s.owner_mailbox > s.owner_mailbox_before, do: " (#{s.owner_mailbox - s.owner_mailbox_before} more than at the start)", else: ""} and #{length(list)} #{plural(length(list), "socket")} in {active, true}, which sends it every packet as it arrives, with nothing to slow the peer down: use {active, once} or {active, N} and ask for more as it handles them, so TCP holds the rest back"}
      end)

    blocked =
      tcp
      |> Enum.filter(fn s ->
        hw = s.options[:high_watermark] || 8_192
        (s.send_pend >= hw and s.send_pend_before >= hw) or s.owner_suspended
      end)
      |> by_owner.()
      |> Enum.map(fn {owner, list} ->
        worst = Enum.max_by(list, & &1.send_pend)
        hw = worst.options[:high_watermark] || 8_192
        forever = Enum.count(list, &(&1.options[:send_timeout] == :infinity))

        {:warning,
         "#{length(list)} TCP #{plural(length(list), "socket")} owned by #{owner} had more queued to send than their high_watermark (#{hw} bytes) through the window, up to #{worst.send_pend} bytes (#{worst.peer || worst.port}, sending #{worst.out_per_s || 0} bytes a second): every process sending to such a socket waits until it drains. A peer that reads slowly holds it up#{if forever > 0, do: ", and with send_timeout infinity (#{forever} of them) for ever: set send_timeout and send_timeout_close", else: ""}; a bulk sender wants a higher high_watermark and sndbuf"}
      end)

    big_reads =
      tcp
      |> Enum.filter(fn s ->
        (s.in_per_s || 0) >= 1_000_000 and is_integer(s.options[:buffer]) and
          s.options[:buffer] < 65_536
      end)
      |> by_owner.()
      |> Enum.map(fn {owner, [s | _] = list} ->
        {:info,
         "#{length(list)} TCP #{plural(length(list), "socket")} owned by #{owner} #{if length(list) == 1, do: "receives", else: "receive"} #{round(s.in_per_s / 1_000_000)} MB a second through a #{s.options.buffer}-byte user buffer: each read takes at most that, so the owner gets many small packets; {buffer, 65536} or larger, with recbuf to match, for bulk transfers"}
      end)

    idle =
      tcp
      |> Enum.filter(&(&1.idle and &1.options[:keepalive] == false))
      |> by_owner.()
      |> Enum.filter(fn {_, list} -> length(list) >= 10 end)
      |> Enum.map(fn {owner, list} ->
        {:info,
         "#{length(list)} TCP connections owned by #{owner} moved no bytes through the window, with keepalive off: one whose peer vanished (a NAT that dropped it, a machine that went away) stays open until the owner times it out; {keepalive, true}, or a timeout in the protocol, closes those"}
      end)

    delay =
      sockets
      |> Enum.filter(&(&1.options[:delay_send] == true))
      |> by_owner.()
      |> Enum.map(fn {owner, list} ->
        {:info,
         "#{length(list)} #{plural(length(list), "socket")} owned by #{owner} have delay_send on: writes are queued and sent together later, fewer system calls for more latency"}
      end)

    udp =
      sockets
      |> Enum.filter(fn s ->
        s.kind == :udp and (s.in_per_s || 0) >= 1_000_000 and is_integer(s.options[:recbuf]) and
          s.options[:recbuf] < 1_000_000
      end)
      |> Enum.map(fn s ->
        {:info,
         "UDP socket #{s.local} receives #{round(s.in_per_s / 1_000_000)} MB a second with a #{s.options.recbuf}-byte recbuf: what arrives while it's full is dropped by the kernel, silently; a larger recbuf (and the OS's limit on it) absorbs bursts"}
      end)

    flood ++ blocked ++ nagle ++ big_reads ++ idle ++ udp ++ delay
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

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

  defp put(map, _key, value) when value in [nil, false, []], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    groups: the node's sockets by what owns them (a registered name, or
    the owner's initial call), each with how many of which kind
    (tcp, tcp_listen, udp), their traffic over the window in and out,
    sends a second, the most common value of each option (active,
    nodelay, packet, sndbuf, recbuf, buffer, high_watermark,
    send_timeout, keepalive), the most queued to send (send_pend), and
    the owner's mailbox. Findings name what to change: nodelay for small
    writes, active once or N for a flooded owner, send_timeout and the
    watermarks for blocked senders, buffer for bulk reads, keepalive for
    idle connections. Next step: port_info on one of the group's
    sockets; module_code on the owner's code where it opens or sets up
    the socket (gen_tcp:connect/listen options, inet:setopts).
    """
  end
end
