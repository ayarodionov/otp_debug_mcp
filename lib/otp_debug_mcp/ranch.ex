defmodule OtpDebugMcp.Ranch do
  @moduledoc """
  Ranch listeners on a node, whatever protocol they run (Cowboy's HTTP,
  RabbitMQ's AMQP, a protocol of your own), sampled at the start and the
  end of a window: each listener's limits and connections, what the
  connection processes are doing, those that did nothing through the
  whole window, and the connections that crashed meanwhile.

  A listener is acceptors, and connection supervisors (one per acceptor
  unless `num_conns_sups` says otherwise), each holding its share of the
  connections. `max_connections` caps each connection supervisor: past
  it, the acceptor that brought a connection waits for room, and new
  clients wait in the listen backlog, unaccepted, with nothing refused
  and nothing logged. A connection the protocol removed from the count
  (`ranch:remove_connection/1`) no longer counts against the limit:
  `all_connections` minus `active_connections`.

  Each connection is one process, the protocol's. One whose reductions
  didn't change from one sample to the other did nothing in between: a
  client that went quiet, held open by a protocol that waits with no
  timeout, holds a place under max_connections for as long as it stays.
  A socket with bytes waiting to be sent (`send_pend`) belongs to a
  client that reads slower than it's written to.

  Ranch logs each connection process that exits abnormally ("Ranch
  listener ... had connection process ... exit with reason"); a log watch
  over the window counts them. Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Errors, Format}

  # Connections looked at, and connections whose stack is looked at, at most.
  @max_connections 5_000
  @max_stacks 500

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
      Skip = [gen, gen_server, gen_statem, gen_tcp, proc_lib, prim_inet, inet, ssl, ssl_gen_statem,
              tls_sender, tls_connection, tls_gen_connection, erlang, timer, lists, maps, io, file,
              logger, telemetry],
      SkipPrefixes = ["ranch", "Elixir.Enum", "Elixir.Stream", "Elixir.Task", "Elixir.GenServer",
                      "Elixir.Process", "Elixir.Kernel", "Elixir.Logger"],
      Mine = fun({Mo, F, _, _}) ->
        not lists:member(Mo, Skip) andalso F =/= module_info andalso
          not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end, SkipPrefixes)
      end,
      Arity = fun(A) when is_list(A) -> length(A); (A) -> A end,
      Handshake = fun(Stack) ->
        lists:any(fun({ranch, handshake, _, _}) -> true;
                     ({ranch, handshake_continue, _, _}) -> true;
                     ({ranch_ssl, handshake, _, _}) -> true;
                     ({ranch_ssl, handshake_continue, _, _}) -> true;
                     ({ssl, handshake, _, _}) -> true;
                     (_) -> false
                  end, Stack)
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
      Socket = fun(Links) ->
        case [P || P <- Links, is_port(P), erlang:port_info(P, name) =:= {name, "tcp_inet"}] of
          [Port | _] ->
            case inet:getstat(Port, [recv_oct, send_oct, send_pend]) of
              {ok, S} -> S;
              _ -> undefined
            end;
          [] -> undefined
        end
      end,
      Conn = fun(P, WithStack) ->
        Keys = [current_function, message_queue_len, memory, reductions, links]
               ++ case WithStack of true -> [current_stacktrace]; false -> [] end,
        case erlang:process_info(P, Keys) of
          undefined -> [];
          I ->
            Stack = proplists:get_value(current_stacktrace, I, []),
            App = case [{Mo, F, Arity(A)} || {Mo, F, A, _} = Fr <- Stack, Mine(Fr)] of
              [First | _] -> First;
              [] -> undefined
            end,
            [{P, [{socket, Socket(proplists:get_value(links, I))}, {app, App},
                  {handshake, Handshake(Stack)}
                  | [KV || {K, _} = KV <- I, K =/= links, K =/= current_stacktrace]]}]
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
        {WithStacks, Rest} = lists:split(min(MaxStacks, length(Conns)), Conns),
        Rows = lists:append([Conn(P, true) || P <- WithStacks] ++ [Conn(P, false) || P <- Rest]),
        Trans = maps:get(transport_options, I, #{}),
        TransMap = case is_map(Trans) of
          true -> Trans;
          false -> maps:from_list([KV || {_, _} = KV <- Trans])
        end,
        SocketOpts = case maps:get(socket_opts, TransMap, []) of SO when is_list(SO) -> SO; _ -> [] end,
        {Ref,
         maps:with([status, ip, port, max_connections, active_connections, all_connections, transport,
                    protocol, metrics], I),
         maps:with([num_acceptors, num_conns_sups, max_connections, handshake_timeout, shutdown], TransMap),
         proplists:get_value(backlog, SocketOpts, 1024),
         PerSup(maps:get(pid, I, undefined)),
         length(Acceptors), Waiting, Rows}
      end,
      {ok, [Describe(L) || L <- Infos]}
  end.
  """

  @doc "Every Ranch listener on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_running ->
          {:error, "Ranch isn't running on this node (no ranch_server)"}

        [] ->
          {:error, "Ranch runs on this node, but no listener has been started"}

        _ ->
          t0 = System.monotonic_time(:millisecond)
          crashes = watch(duration_ms)
          elapsed = max(System.monotonic_time(:millisecond) - t0, 1)

          with {:ok, last} <- snapshot() do
            last = if is_list(last), do: last, else: []

            listeners =
              Enum.map(first, fn l ->
                # As Ranch's log line has it.
                ref = :io_lib.format("~p", [elem(l, 0)]) |> to_string()
                listener(l, Enum.find(last, &(elem(&1, 0) == elem(l, 0))), crashes[ref], elapsed)
              end)

            {:ok, summary(listeners, crashes, elapsed)}
          end
      end
    end
  end

  defp snapshot do
    case Checks.remote_eval(@snapshot, MaxConns: @max_connections, MaxStacks: @max_stacks) do
      {:ok, {:ok, listeners}} -> {:ok, listeners}
      {:ok, :not_running} -> {:ok, :not_running}
      {:error, _} = err -> err
    end
  end

  # Ranch's log lines for connections that exited abnormally, by listener,
  # over the window. A watch already running (recent_errors') is read as
  # it is, and the window slept through.
  @crash ~r/Ranch listener (.+?) had connection process started with (\S+?):start_link\/\d at (\S+) exit with reason: (.*)/s

  defp watch(duration_ms) do
    case Errors.listen(:error, duration_ms) do
      {:ok, how, report} ->
        if how == :watch, do: Process.sleep(duration_ms)

        report.entries
        |> Enum.flat_map(fn e ->
          case Regex.run(@crash, to_string(e[:text] || "")) do
            [_, ref, _protocol, _pid, reason] -> [{ref, reason |> String.trim() |> normalize()}]
            nil -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {ref, reasons} -> {ref, reasons} end)
        |> Map.put(:watched, true)

      _ ->
        Process.sleep(duration_ms)
        %{watched: false}
    end
  end

  # Pids, refs and ports differ from one crash to the next.
  defp normalize(text) do
    text
    |> String.replace(~r/<\d+\.\d+\.\d+>/, "<pid>")
    |> String.replace(~r/#(Ref|Port)<[\d.]+>/, "#\\1<>")
    |> String.slice(0, 300)
  end

  # -- A listener ----------------------------------------------------------------

  defp listener(first, last, crashes, elapsed) do
    {ref, info, trans, backlog, per_sup, acceptors, waiting, conns} = first

    {info1, per_sup1, waiting1, conns1} =
      case last do
        {_, i, _, _, ps, _, w, c} -> {i, ps, w, c}
        nil -> {info, per_sup, waiting, conns}
      end

    max = info[:max_connections]
    sups = trans[:num_conns_sups] || trans[:num_acceptors] || max(length(per_sup1), 1)

    # Ranch 2 caps each connection supervisor; Ranch 1 has just one.
    limit =
      cond do
        not is_integer(max) -> :infinity
        per_sup1 == [] -> max
        true -> max * sups
      end

    before = Map.new(conns)
    both = for {pid, i} <- conns1, i0 = before[pid], do: {pid, i0, i}
    # Each look at a process costs it a reduction or two.
    idle = Enum.filter(both, fn {_, i0, i} -> i[:reductions] - i0[:reductions] < 10 end)
    handshaking = Enum.filter(both, fn {_, i0, i} -> i0[:handshake] and i[:handshake] end)

    slow_readers =
      Enum.filter(both, fn {_, i0, i} -> pending(i0) > 0 and pending(i) > 0 end)

    active = info1[:active_connections]
    all = info1[:all_connections]
    fullest = Enum.max(per_sup1, fn -> active end)

    %{
      listener: Format.inspect(ref),
      listening: listening(info1),
      status: info1[:status] || :running,
      transport: info1[:transport] && Format.inspect(info1[:transport]),
      protocol: info1[:protocol] && Format.inspect(info1[:protocol]),
      acceptors: acceptors,
      connections: %{
        active: active,
        all: all,
        limit: limit,
        max_connections: max || :unknown,
        connection_supervisors: if(per_sup1 == [], do: 1, else: sups),
        fullest_supervisor: fullest,
        acceptors_waiting_for_room: length(waiting1),
        acceptors_waiting_through_window: Enum.count(waiting, &(&1 in waiting1))
      },
      handshake_timeout_ms: trans[:handshake_timeout] || 5_000,
      backlog: backlog
    }
    |> Map.merge(rates(info[:metrics], info1[:metrics], elapsed))
    |> put(
      :removed_from_count,
      (is_integer(all) and is_integer(active) and all > active) && all - active
    )
    |> put(:doing, doing(conns1))
    |> put(:idle_through_window, idle(idle, length(both)))
    |> put(:in_handshake_through_window, nonempty(handshaking, &groups/1))
    |> put(:slow_readers, slow(slow_readers))
    |> put(:largest, largest(conns1))
    |> put(:crashed_in_window, crashed(crashes, elapsed))
    |> put(
      :sampled,
      length(conns1) >= @max_connections && "the first #{@max_connections} connections"
    )
  end

  defp pending(i) do
    case i[:socket] do
      s when is_list(s) -> s[:send_pend] || 0
      _ -> 0
    end
  end

  defp listening(%{ip: {:local, path}}), do: "unix:#{path}"
  defp listening(%{ip: {_, _, _, _} = ip, port: port}), do: "#{:inet.ntoa(ip)}:#{port}"

  defp listening(%{ip: {_, _, _, _, _, _, _, _} = ip, port: port}),
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp listening(%{port: port}) when is_integer(port), do: "port #{port}"
  defp listening(_), do: "not listening"

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

  # Connections grouped by the function they're in and the first frame of
  # the protocol's code.
  defp doing([]), do: false
  defp doing(conns), do: groups(Enum.map(conns, fn {pid, i} -> {pid, i, i} end))

  defp groups(rows) do
    rows
    |> Enum.map(fn {_, _, i} -> {i[:current_function], i[:app]} end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.map(fn {{fun, app}, n} ->
      %{connections: n, current_function: mfa(fun)}
      |> put(:in_protocol_code, app && app != :undefined && app != fun && mfa(app))
    end)
  end

  defp idle([], _), do: false

  defp idle(rows, of) do
    bytes = for {_, i0, i} <- rows, is_list(i0[:socket]) and is_list(i[:socket]), do: {i0, i}

    %{connections: length(rows), of: of, waiting_in: groups(rows)}
    |> put(
      :no_bytes_either,
      bytes != [] &&
        Enum.count(bytes, fn {i0, i} ->
          i0[:socket][:recv_oct] == i[:socket][:recv_oct] and
            i0[:socket][:send_oct] == i[:socket][:send_oct]
        end)
    )
  end

  defp nonempty([], _), do: false
  defp nonempty(rows, f), do: %{connections: length(rows), in: f.(rows)}

  defp slow([]), do: false

  defp slow(rows) do
    top =
      rows
      |> Enum.sort_by(fn {_, _, i} -> -pending(i) end)
      |> Enum.take(5)
      |> Enum.map(fn {pid, _, i} ->
        %{
          pid: Format.inspect(pid),
          bytes_waiting: pending(i),
          current_function: mfa(i[:current_function])
        }
      end)

    %{connections: length(rows), most: top}
  end

  defp largest(conns) do
    big =
      conns
      |> Enum.filter(fn {_, i} -> i[:memory] > 1_000_000 or i[:message_queue_len] > 100 end)
      |> Enum.sort_by(fn {_, i} -> -max(i[:message_queue_len], div(i[:memory], 1000)) end)
      |> Enum.take(3)

    big != [] &&
      for {pid, i} <- big do
        %{
          pid: Format.inspect(pid),
          memory_bytes: i[:memory],
          message_queue_len: i[:message_queue_len]
        }
      end
  end

  defp crashed(nil, _), do: false

  defp crashed(reasons, elapsed) do
    top =
      reasons
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(3)
      |> Enum.map(fn {reason, n} -> %{connections: n, reason: reason} end)

    %{
      connections: length(reasons),
      per_s: Float.round(length(reasons) * 1000 / elapsed, 1),
      reasons: top
    }
  end

  # Each module in its own language's syntax.
  defp mfa({m, f, a}) when is_atom(m),
    do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"

  defp mfa(other), do: Format.inspect(other)

  defp module(m), do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))
  defp elixir?(m), do: String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- Findings ------------------------------------------------------------------

  defp summary(listeners, crashes, elapsed) do
    notes =
      listeners
      |> Enum.flat_map(&findings/1)
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    %{
      status: status(notes),
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      listeners: listeners,
      window_ms: elapsed,
      interpretation: interpretation()
    }
    |> put(:note, !crashes.watched && "no log watch could be started: crashes aren't counted")
  end

  defp findings(l) do
    c = l.connections
    name = l.listener

    full =
      cond do
        c.acceptors_waiting_through_window > 0 ->
          [
            {:critical,
             "#{name}: #{c.acceptors_waiting_through_window} of #{l.acceptors} acceptors waited for room through the whole window (connection supervisors at max_connections, #{c.max_connections} each, #{inspect(c.limit)} for the listener): new clients wait in the listen backlog (#{l.backlog}), unaccepted, and nothing is refused or logged"}
          ]

        c.acceptors_waiting_for_room > 0 or
            (is_integer(c.max_connections) and c.fullest_supervisor >= c.max_connections) ->
          [
            {:warning,
             "#{name}: a connection supervisor is at max_connections (#{c.max_connections}); its acceptor waits for room while it is"}
          ]

        true ->
          []
      end

    idle =
      case l[:idle_through_window] do
        %{connections: n, of: of, waiting_in: [top | _]} when n >= 5 ->
          share = n / max(of, 1)
          near_limit? = is_integer(c.limit) and c.active >= c.limit * 0.8

          if share >= 0.5 or near_limit? do
            [
              {if(near_limit?, do: :critical, else: :warning),
               "#{name}: #{n} of #{of} connections did nothing through the whole window#{if l[:idle_through_window][:no_bytes_either], do: " (#{l.idle_through_window.no_bytes_either} without a byte either way)", else: ""}, most in #{top.current_function}#{if top[:in_protocol_code], do: " from #{top.in_protocol_code}", else: ""}: clients that went quiet, held open by a protocol waiting with no timeout#{if near_limit?, do: ". They hold #{c.active} of the listener's #{c.limit} places, so new clients wait", else: ""}. A receive timeout (gen_tcp:recv's, or {active, once} with an after) closes them"}
            ]
          else
            []
          end

        _ ->
          []
      end

    handshakes =
      case l[:in_handshake_through_window] do
        %{connections: n} ->
          [
            {:warning,
             "#{name}: #{n} connections were in their handshake through the whole window (handshake_timeout #{l.handshake_timeout_ms} ms): clients that connect and never finish the handshake"}
          ]

        _ ->
          []
      end

    slow =
      case l[:slow_readers] do
        %{connections: n, most: [top | _]} ->
          [
            {:warning,
             "#{name}: #{n} connections had bytes waiting to be sent in both samples (up to #{top.bytes_waiting}, #{top.pid} in #{top.current_function}): clients reading slower than they're written to; a protocol process blocked in send holds its place, and its sender waits"}
          ]

        _ ->
          []
      end

    removed =
      case l[:removed_from_count] do
        n when is_integer(n) and n > 0 ->
          [
            {:info,
             "#{name}: #{n} connections were removed from the count (ranch:remove_connection/1): they don't count against max_connections, so nothing limits them"}
          ]

        _ ->
          []
      end

    crashed =
      case l[:crashed_in_window] do
        %{connections: n, per_s: rate, reasons: [top | _]} ->
          [
            {:warning,
             "#{name}: #{n} connection processes crashed in the window (#{rate} a second); most with: #{top.reason}"}
          ]

        _ ->
          []
      end

    suspended =
      if l.status == :suspended,
        do: [
          {:warning,
           "#{name} is suspended: it accepts no connections until ranch:resume_listener/1"}
        ],
        else: []

    suspended ++ full ++ idle ++ handshakes ++ slow ++ crashed ++ removed
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
    One entry per Ranch listener, whatever its protocol. connections:
    active (counted against max_connections), all, the limit
    (max_connections per connection supervisor, times their number), the
    fullest supervisor, acceptors waiting for room (now, and through the
    whole window: clients then wait in the listen backlog, unaccepted).
    accepted_per_s and closed_per_s are Ranch 2.1's counters. doing
    groups the connection processes by the function they're in and the
    first frame of the protocol's code. idle_through_window are those
    whose reductions didn't change between the samples (no_bytes_either:
    their TCP socket moved no bytes either): clients gone quiet, held
    open by a protocol with no receive timeout. in_handshake_through_window
    are clients that never finish the (TLS) handshake; slow_readers
    sockets with bytes waiting to be sent in both samples;
    removed_from_count connections taken out of the count, which nothing
    limits; crashed_in_window Ranch's log lines for connection processes
    that exited abnormally, by reason. Next step: process_info on a
    connection pid; port_info on its socket; module_code on the
    protocol's loop for its timeouts.
    """
  end
end
