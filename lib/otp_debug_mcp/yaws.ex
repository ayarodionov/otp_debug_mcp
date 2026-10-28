defmodule OtpDebugMcp.Yaws do
  @moduledoc """
  Yaws on a node: each listening server's connections against its limit,
  what its acceptor processes are doing, and its cookie sessions, sampled
  at the start and the end of a window.

  Yaws runs one server process (`gserv`) per address and port, and an
  acceptor process per connection: it accepts it, reads its requests
  (`aloop`), and runs the page's or appmod's `out/1` itself. So an
  acceptor is waiting to accept, pooled for reuse, waiting for a
  connection's next request, or handling one; the handling ones grouped
  by the first frame of the application's code show what requests wait
  on. Past `max_connections`, Yaws closes each new connection as soon as
  it's accepted, and logs "Max connections reached".

  Cookie sessions live in an ETS table (`yaws_session_server`) for `ttl`
  seconds after their last use (30 minutes by default), but expired ones
  are removed only by a sweep every `ysession_long_timeout` (an hour), or
  after the session server has been idle for `ysession_idle_timeout`: on
  a busy server, an hour's sessions pile up.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Acceptors looked at, and sessions sampled, at most.
  @max_acceptors 5_000
  @max_sessions 2_000

  @snapshot ~S"""
  case whereis(yaws_server) of
    undefined ->
      not_running;
    _ ->
      Pids = case catch gen_server:call(yaws_server, pids, 5000) of [_ | Ps] -> Ps; _ -> [] end,
      Status = fun(P) ->
        P ! {self(), status},
        receive {P, S} -> S after 2000 -> timeout end
      end,
      Skip = [gen, gen_server, gen_statem, proc_lib, prim_inet, inet, ssl, ssl_gen_statem, tls_sender,
              erlang, timer, lists, maps, gen_tcp, inet_tcp],
      SkipPrefixes = ["yaws", "Elixir.Enum", "Elixir.Stream", "Elixir.Task", "Elixir.GenServer",
                      "Elixir.Process"],
      AppFrame = fun(Stack) ->
        case [MFA || {Mo, F, A, _} = MFA <- Stack,
                     not lists:member(Mo, Skip),
                     not lists:any(fun(Pre) -> lists:prefix(Pre, atom_to_list(Mo)) end, SkipPrefixes),
                     F =/= module_info, is_integer(A) orelse is_list(A)] of
          [{Mo, F, A, _} | _] -> {Mo, F, case is_list(A) of true -> length(A); false -> A end};
          [] -> undefined
        end
      end,
      IsAcceptor = fun(P) ->
        case erlang:process_info(P, dictionary) of
          {dictionary, D} -> proplists:get_value('$initial_call', D) =:= {yaws_server, acceptor0, 2};
          _ -> false
        end
      end,
      %% What an acceptor does: accept, wait to be reused, wait for a
      %% connection's next request, or handle one.
      Doing = fun(Stack) ->
        Fs = [{M, F} || {M, F, _, _} <- Stack],
        case Fs of
          [{yaws_server, acceptor0} | _] -> pooled;
          _ ->
            case lists:any(fun({M, F}) -> lists:member(F, [accept, accept0, transport_accept]) andalso
                                          lists:member(M, [prim_inet, inet_tcp, inet6_tcp, gen_tcp,
                                                           gen_tcp_socket, ssl, yaws_server])
                           end, Fs) of
              true -> accepting;
              false ->
                case lists:member({yaws, http_recv_request}, Fs) orelse
                     lists:member({yaws, do_http_get_headers}, Fs) of
                  true -> waiting;
                  false -> handling
                end
            end
        end
      end,
      Acc = fun(GP) ->
        {links, Ls} = erlang:process_info(GP, links),
        As = lists:sublist([A || A <- Ls, is_pid(A), IsAcceptor(A)], MaxAcc),
        [{A, Doing(St), AppFrame(St), CF, Q, M}
         || A <- As,
            [{current_stacktrace, St}, {current_function, CF}, {message_queue_len, Q}, {memory, M}]
              <- [erlang:process_info(A, [current_stacktrace, current_function, message_queue_len, memory])]]
      end,
      Servers = [begin
                   Size = tuple_size(GS),
                   Group = element(3, GS),
                   Scs = [{catch yaws:sconf_servername(SC), catch yaws:sconf_listen(SC),
                           catch yaws_server:listen_port(SC), catch yaws:sconf_appmods(SC),
                           catch yaws:sconf_docroot(SC)} || SC <- Group],
                   {GP, element(4, GS), element(Size - 2, GS), element(Size - 1, GS), element(Size, GS),
                    Scs, Acc(GP)}
                 end || GP <- Pids, GS <- [Status(GP)], is_tuple(GS)],
      {ok, GC, _} = yaws_api:getconf(),
      Conf = [{K, catch yaws:F(GC)} || {K, F} <- [{max_connections, gconf_max_connections},
                                                    {keepalive_timeout, gconf_keepalive_timeout},
                                                    {keepalive_maxuses, gconf_keepalive_maxuses},
                                                    {acceptor_pool_size, gconf_acceptor_pool_size},
                                                    {session_idle_timeout, gconf_ysession_idle_timeout},
                                                    {session_long_timeout, gconf_ysession_long_timeout},
                                                    {session_backend, gconf_ysession_mod}]],
      %% Sessions in the default ETS backend: each {ysession, Cookie, To,
      %% Ttl, Start, Cleanup, Opaque}. Never used again: its expiry is
      %% still its start plus its ttl. Expired: past its expiry, still
      %% kept.
      Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
      Sessions = case ets:info(yaws_session_server, size) of
        undefined -> undefined;
        N ->
          Sample = case ets:select(yaws_session_server, [{'_', [], ['$_']}], MaxSess) of
            {L, _} -> L;
            _ -> []
          end,
          Kept = [S || S <- Sample, is_tuple(S), tuple_size(S) >= 7],
          Once = [S || S <- Kept,
                       abs(element(3, S) - element(4, S) -
                           calendar:datetime_to_gregorian_seconds(element(5, S))) =< 1],
          Expired = [S || S <- Kept, element(3, S) < Now],
          Ttls = lists:usort([element(4, S) || S <- Kept]),
          #{count => N, memory_words => ets:info(yaws_session_server, memory),
            sampled => length(Kept), used_once => length(Once), expired => length(Expired),
            ttls => lists:sublist(Ttls, 5)}
      end,
      Log = case whereis(yaws_log) of
        undefined -> undefined;
        LP -> element(2, erlang:process_info(LP, message_queue_len))
      end,
      {ok, Servers, Conf, Sessions, Log}
  end.
  """

  @doc """
  Every Yaws server on the node, sampled at the start and the end of
  `duration_ms`.
  """
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_running ->
          {:error, "Yaws isn't running on this node (no yaws_server process)"}

        {:ok, [], _, _, _} ->
          {:error, "Yaws runs on this node, but no server is listening"}

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

  defp snapshot do
    Checks.remote_eval(@snapshot, MaxAcc: @max_acceptors, MaxSess: @max_sessions)
  end

  defp analyze({:ok, servers, conf, sessions, log}, last, elapsed) do
    conf = Map.new(conf, fn {k, v} -> {k, plain(v)} end)

    {last_servers, last_sessions} =
      case last do
        {:ok, s, _, ls, _} -> {s, ls}
        _ -> {[], nil}
      end

    servers =
      for s <- servers,
          do: server(s, Enum.find(last_servers, &(elem(&1, 0) == elem(s, 0))), conf, elapsed)

    sessions = sessions(sessions, last_sessions, elapsed)

    notes =
      (Enum.flat_map(servers, &server_findings(&1, conf, elapsed)) ++
         session_findings(sessions, conf) ++ log_findings(log))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    %{
      status: status(notes),
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      servers: servers,
      config: conf,
      listened_ms: elapsed,
      interpretation: interpretation()
    }
    |> put(:sessions, sessions)
    |> put(:access_log_queue, log)
  end

  defp plain(v) when is_atom(v) or is_number(v), do: v
  defp plain(v), do: Format.inspect(v)

  # -- A server ------------------------------------------------------------------

  defp server({gp, ssl, conns, acceptors_alive, reqs, scs, accs}, last, conf, elapsed) do
    by = Enum.frequencies_by(accs, &elem(&1, 1))

    handling = for {pid, :handling, app, cf, _, _} <- accs, do: {pid, app, cf}

    # Still handling at the end, in the same frame of the application's
    # code: a request that ran through the window (or a keep-alive
    # connection's next, there again).
    {long, reqs_per_s} =
      case last do
        {_, _, _, _, last_reqs, _, last_accs} ->
          now = MapSet.new(for {pid, :handling, app, _, _, _} <- last_accs, do: {pid, app})

          {Enum.filter(handling, fn {pid, app, _} -> app && MapSet.member?(now, {pid, app}) end),
           Float.round((last_reqs - reqs) * 1000 / elapsed, 1)}

        nil ->
          {[], nil}
      end

    %{
      server: Format.inspect(gp),
      virtual_servers: Enum.map(scs, &virtual_server/1),
      listening: listening(scs),
      ssl: ssl == :ssl,
      connections: %{
        open: conns,
        max_connections: conf[:max_connections]
      },
      acceptors: %{
        alive: acceptors_alive,
        accepting: Map.get(by, :accepting, 0),
        pooled: Map.get(by, :pooled, 0),
        waiting_for_a_request: Map.get(by, :waiting, 0),
        handling_a_request: Map.get(by, :handling, 0)
      },
      requests_total: reqs
    }
    |> put(:requests_per_s, reqs_per_s)
    |> put(:waiting_in, groups(handling))
    |> put(:running_through_window, long != [] && %{requests: length(long), in: groups(long)})
    |> put(:largest_acceptors, largest(accs))
  end

  defp virtual_server({name, _listen, _port, appmods, docroot}) do
    %{name: text(name), docroot: text(docroot)}
    |> put(:appmods, appmods(appmods))
  end

  defp appmods(list) when is_list(list) and list != [] do
    for item <- list do
      case item do
        {path, mod} -> "#{text(path)} -> #{module(mod)}"
        {path, mod, _excl} -> "#{text(path)} -> #{module(mod)}"
        other -> Format.inspect(other)
      end
    end
  end

  defp appmods(_), do: false

  defp listening([{_, ip, port, _, _} | _]) when is_tuple(ip) and is_integer(port),
    do: "#{:inet.ntoa(ip)}:#{port}"

  defp listening([{_, _, port, _, _} | _]) when is_integer(port), do: "port #{port}"
  defp listening(_), do: "unknown"

  defp text(v) when is_list(v), do: List.to_string(v)
  defp text(v) when is_binary(v), do: v
  defp text(v), do: Format.inspect(v)

  defp groups([]), do: false

  defp groups(list) do
    list
    |> Enum.frequencies_by(fn {_, app, cf} -> {cf, app} end)
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.map(fn {{cf, app}, n} ->
      %{requests: n, current_function: mfa(cf)}
      |> put(:in_your_code, app && app != cf && mfa(app))
    end)
  end

  defp largest(accs) do
    big =
      accs
      |> Enum.sort_by(fn a -> -elem(a, 5) end)
      |> Enum.take(3)
      |> Enum.filter(fn a -> elem(a, 5) > 1_000_000 or elem(a, 4) > 100 end)

    big != [] &&
      for {pid, doing, _, _, q, mem} <- big do
        %{pid: Format.inspect(pid), doing: doing, memory_bytes: mem, message_queue_len: q}
      end
  end

  # Each module in its own language's syntax: appmods are often Erlang.
  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- Sessions ------------------------------------------------------------------

  defp sessions(nil, _, _), do: false

  # The counts at the end of the window, the sample from its start.
  defp sessions(s, last, elapsed) do
    words = :erlang.system_info(:wordsize)
    now = last || s

    %{
      count: now.count,
      memory_bytes: now.memory_words * words,
      sampled: s.sampled,
      used_once: s.used_once,
      expired_still_kept: s.expired,
      ttl_seconds: s.ttls
    }
    |> put(:new_per_s, last && Float.round((last.count - s.count) * 1000 / elapsed, 1))
  end

  # -- Findings ------------------------------------------------------------------

  defp server_findings(s, conf, elapsed) do
    where = "Yaws on #{s.listening}"
    max = conf[:max_connections]
    open = s.connections.open

    full =
      cond do
        is_integer(max) and open >= max ->
          [
            {:critical,
             "#{where}: #{open} connections open, at max_connections (#{max}): Yaws closes each new connection as soon as it's accepted (\"Max connections reached\" in the log), so clients see their connections reset"}
          ]

        is_integer(max) and open >= 0.8 * max ->
          [{:warning, "#{where}: #{open} of #{max} connections open"}]

        true ->
          []
      end

    long =
      case s[:running_through_window] do
        %{requests: n, in: [top | _]} ->
          [
            {:warning,
             "#{where}: #{n} requests ran through the whole #{elapsed} ms, most in #{top[:in_your_code] || top.current_function}"}
          ]

        _ ->
          []
      end

    busy =
      case s[:waiting_in] do
        [%{requests: n} = top | _] when n >= 5 and long == [] ->
          [
            {:warning,
             "#{where}: #{n} requests in flight in #{top[:in_your_code] || top.current_function}"}
          ]

        _ ->
          []
      end

    full ++ long ++ busy
  end

  defp session_findings(false, _conf), do: []

  defp session_findings(s, conf) do
    once = if s.sampled > 0, do: s.used_once / s.sampled, else: 0
    growing = (s[:new_per_s] || 0) > 1

    piling =
      if (growing or s.count > 10_000) and once >= 0.5,
        do: [
          {:warning,
           "#{s.count} cookie sessions (#{bytes(s.memory_bytes)})#{if s[:new_per_s], do: ", #{s.new_per_s} new a second", else: ""}, and #{round(once * 100)}% of a sample were never used again after the request that started them: a new session for each request (clients that don't send the cookie back, or code that starts a session without looking for one first). Each is kept for its ttl (#{Enum.join(s.ttl_seconds, ", ")} s), and until the hourly sweep (session_long_timeout #{conf[:session_long_timeout]} ms) once expired"}
        ],
        else: []

    big =
      if piling == [] and s.count > 100_000,
        do: [{:warning, "#{s.count} cookie sessions, #{bytes(s.memory_bytes)}"}],
        else: []

    expired =
      if s.sampled > 0 and s.expired_still_kept / s.sampled >= 0.2,
        do: [
          {:info,
           "#{round(s.expired_still_kept / s.sampled * 100)}% of the sampled sessions have expired but are still kept, until the next sweep (every session_long_timeout, #{conf[:session_long_timeout]} ms)"}
        ],
        else: []

    piling ++ big ++ expired
  end

  defp bytes(b) when b >= 1_000_000, do: "#{Float.round(b / 1_000_000, 1)} MB"
  defp bytes(b), do: "#{div(b, 1000)} KB"

  defp log_findings(q) when is_integer(q) and q > 1_000,
    do: [
      {:warning,
       "the access log writer (yaws_log) has #{q} messages queued: it can't write the log as fast as requests come"}
    ]

  defp log_findings(_), do: []

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
    servers are Yaws's listening servers, one per address and port, each
    with its virtual servers (name, docroot, appmods). connections.open
    is Yaws's own count; at max_connections (nolimit by default) it closes
    every new connection as soon as it's accepted and logs "Max
    connections reached". Each connection is an acceptor process, which
    also runs out/1: accepting waits for a connection, pooled waits to be
    reused (up to acceptor_pool_size), waiting_for_a_request is a
    keep-alive connection between requests (up to keepalive_timeout), and
    handling_a_request runs one. waiting_in groups those by the function
    they're in and the first frame of your code (an appmod, a .yaws
    page's module), and running_through_window are those still there at
    the end. requests_total and requests_per_s count requests when their
    connection closes, so keep-alive connections show late. sessions are
    the cookie sessions in Yaws's default ETS backend: used_once are
    sessions never looked up after the request that started them, a sign
    of one session per request; expired_still_kept wait for the hourly
    sweep. access_log_queue is yaws_log's mailbox. Next step: trace_calls
    or profile on the function requests wait in; module_code on the
    appmod; ets_table on yaws_session_server for the sessions themselves;
    recent_errors for crashes in out/1 and "Max connections reached".
    """
  end
end
