defmodule OtpDebugMcp.Shackle do
  @moduledoc """
  shackle client pools on a node (marina, anchor, buoy and other clients
  built on it): each pool's backend, options and connections now, the
  processes waiting for a reply, and over a window what shackle's
  telemetry says.

  A pool is `pool_size` connections, each a `shackle_server` process
  holding one socket to the backend. A call picks one (random or round
  robin), counts the request in that connection's backlog, and waits for
  the reply. Past `backlog_size` requests in flight on the picked
  connection, or when it's down (reconnecting), shackle tries another,
  `max_retries` times, then gives up: `{error, no_server}`, whether the
  connections it picked were full or down (telemetry tells which:
  `backlog_full`, `disabled`). A request without a reply within its timeout
  ends with `{error, timeout}`; a reply arriving after that is
  `not_found`. All of that is read from shackle's own state (its
  backlog counters, connection flags and pool options), without asking
  the connection processes anything.

  One connection backed up while the others aren't is head-of-line
  blocking: the backend answers a connection's requests in order, and a
  slow one holds up every request behind it.
  """

  alias OtpDebugMcp.{Checks, Format, Telemetry}

  # Waiting callers whose stack is looked at, at most.
  @max_callers 2_000

  @snapshot ~S"""
  case whereis(shackle_sup) of
    undefined ->
      not_running;
    Sup ->
      Kids = case catch supervisor:which_children(Sup) of L when is_list(L) -> L; _ -> [] end,
      Get = fun(Key, Default) -> case catch persistent_term:get(Key, Default) of
                                   {'EXIT', _} -> Default;
                                   V -> V
                                 end end,
      Servers = [begin
                   Up = case Get(Pool, undefined) of
                     undefined -> undefined;
                     C -> catch counters:get(C, Index)
                   end,
                   Backlog = case Get({shackle_backlog, Pool}, undefined) of
                     undefined -> undefined;
                     A -> catch atomics:get(A, Index)
                   end,
                   Info = case is_pid(Pid) of
                     true -> erlang:process_info(Pid, [message_queue_len, memory]);
                     false -> undefined
                   end,
                   Opts = [{K, V} || {K, V} <- COpts,
                                     lists:member(K, [address, ip, port, protocol, max_requests, reconnect,
                                                      reconnect_time_min, reconnect_time_max])],
                   {Pool, Index, Client, Opts, Pid, Up, Backlog, Info}
                 end
                 || {Id, Pid, worker, [shackle_server]} <- Kids,
                    {ok, #{start := {_, _, [_, {Pool, Index, Client, COpts}]}}}
                      <- [catch supervisor:get_childspec(Sup, Id)]],
      Pools = lists:usort([P || {P, _, _, _, _, _, _, _} <- Servers]),
      PoolOpts = [{P, case catch shackle_pool_foil:lookup(P) of
                        {ok, {pool_options, BacklogSize, _Client, MaxRetries, PoolSize, Strategy}} ->
                          #{backlog_size => BacklogSize, max_retries => MaxRetries,
                            pool_size => PoolSize, pool_strategy => Strategy};
                        _ -> #{}
                      end} || P <- Pools],
      Skip = [gen, gen_server, gen_statem, proc_lib, erlang, timer, lists, maps, shackle],
      SkipPrefixes = ["Elixir.Enum", "Elixir.Stream", "Elixir.Task", "Elixir.GenServer",
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
      %% Callers waiting in shackle:call/2,3 for a reply.
      Waiting = [P || P <- erlang:processes(),
                      erlang:process_info(P, current_function) =:= {current_function, {shackle, receive_response, 1}}],
      Callers = [AppFrame(St) || P <- lists:sublist(Waiting, MaxCallers),
                                 {current_stacktrace, St} <- [erlang:process_info(P, current_stacktrace)]],
      {ok, Servers, PoolOpts, length(Waiting), Callers, Get({shackle, telemetry}, true)}
  end.
  """

  @events [
    "shackle.reply",
    "shackle.timeout",
    "shackle.backlog_full",
    "shackle.disabled",
    "shackle.no_server",
    "shackle.not_found"
  ]

  @doc """
  Every shackle pool on the node, sampled at the start and the end of
  `duration_ms`, and its telemetry meanwhile.
  """
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        :not_running ->
          {:error, "shackle isn't running on this node (no shackle_sup process)"}

        {:ok, [], _, _, _, _} ->
          {:error, "shackle runs on this node, but no pool has been started"}

        _ ->
          t0 = System.monotonic_time(:millisecond)
          telemetry = Telemetry.listen(@events, duration_ms)
          if match?({:error, _}, telemetry), do: Process.sleep(duration_ms)
          elapsed = max(System.monotonic_time(:millisecond) - t0, 1)

          with {:ok, last} <- snapshot() do
            {:ok, analyze(first, last, telemetry, elapsed)}
          end
      end
    end
  end

  defp snapshot, do: Checks.remote_eval(@snapshot, MaxCallers: @max_callers)

  defp analyze(
         {:ok, servers, pool_opts, waiting, callers, telemetry_on},
         last,
         telemetry,
         elapsed
       ) do
    last_servers =
      case last do
        {:ok, s, _, _, _, _} -> s
        _ -> []
      end

    window = window(telemetry, elapsed)

    pools =
      for {pool, opts} <- pool_opts do
        mine = Enum.filter(servers, &(elem(&1, 0) == pool))
        later = Enum.filter(last_servers, &(elem(&1, 0) == pool))
        pool(pool, opts, mine, later, window)
      end

    notes =
      (Enum.flat_map(pools, &pool_findings(&1, elapsed)) ++
         telemetry_findings(telemetry_on, window))
      |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    %{
      status: status(notes),
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      pools: pools,
      callers_waiting: %{count: waiting}
    }
    |> put_in([:callers_waiting, :in], callers(callers))
    |> Map.put(:window, window)
    |> Map.put(:interpretation, interpretation())
  end

  # -- A pool --------------------------------------------------------------------

  defp pool(pool, opts, servers, later, window) do
    [{_, _, client, copts, _, _, _, _} | _] = servers
    down_still = for {_, i, _, _, _, up, _, _} <- later, up == 0, do: i

    # A connection far busier than every other, in either sample: held up.
    held_up =
      for sample <- [servers, later], sample != [] do
        flights = for {_, i, _, _, _, _, b, _} <- sample, do: {i, b || 0}
        {i, top} = Enum.max_by(flights, &elem(&1, 1))
        rest = for {j, b} <- flights, j != i, do: b

        if top >= 4 and rest != [] and top >= 4 * max(Enum.max(rest), 1),
          do: %{index: i, in_flight: top, others_at_most: Enum.max(rest)}
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(& &1.in_flight, fn -> nil end)

    conns =
      for {_, index, _, _, pid, up, backlog, info} <- Enum.sort_by(servers, &elem(&1, 1)) do
        %{
          index: index,
          up: up == 1,
          in_flight: backlog,
          mailbox: info && info[:message_queue_len],
          pid: Format.inspect(pid)
        }
      end

    in_flight = conns |> Enum.map(&(&1.in_flight || 0)) |> Enum.sum()

    %{
      pool: Format.inspect(pool),
      client: module(client),
      backend: backend(copts),
      protocol: (copts[:protocol] && Format.inspect(copts[:protocol])) || "shackle_tcp",
      pool_size: opts[:pool_size] || length(servers),
      pool_strategy: opts[:pool_strategy],
      backlog_size: opts[:backlog_size],
      max_retries: opts[:max_retries],
      connections_up: Enum.count(conns, & &1.up),
      in_flight: in_flight,
      connections: conns,
      reconnect_ms: %{
        min: copts[:reconnect_time_min] || 500,
        max: copts[:reconnect_time_max] || 120_000
      }
    }
    |> put(:down_through_window, down_still != [] && down_still)
    |> put(:held_up, held_up)
    |> put(:window, window[:by_client] && Map.get(window.by_client, module(client)))
  end

  defp backend(copts) do
    address = copts[:address] || copts[:ip] || "127.0.0.1"
    address = if is_tuple(address), do: to_string(:inet.ntoa(address)), else: to_string(address)
    "#{address}:#{copts[:port]}"
  end

  defp callers([]), do: []

  defp callers(frames) do
    frames
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.map(fn {frame, n} -> %{callers: n, in_your_code: mfa(frame)} end)
  end

  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(_), do: "unknown"

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- The window ----------------------------------------------------------------

  defp window({:error, reason}, _elapsed), do: %{not_listened: Format.inspect(reason)}

  # Events by client module.
  defp window({:ok, report}, elapsed) do
    by_client =
      for %{event: event, groups: groups} <- report.by_event, g <- groups, reduce: %{} do
        acc ->
          name = event |> String.replace_prefix("shackle.", "")
          # Named as the pool names it: an Elixir module without its prefix.
          client = String.replace_prefix(g[:key] || "unknown", "Elixir.", "")

          entry =
            case name do
              "reply" ->
                %{replies: g.count}
                |> put(:reply_ms, g[:duration_ms])

              other ->
                %{String.to_atom(other) => g.count}
            end

          Map.update(acc, client, entry, &Map.merge(&1, entry))
      end

    per_s = fn n -> Float.round(n * 1000 / elapsed, 1) end

    by_client =
      Map.new(by_client, fn {client, e} ->
        {client, Map.put(e, :replies_per_s, per_s.(e[:replies] || 0))}
      end)

    %{listened_ms: elapsed, by_client: by_client}
    |> put(:dropped_events, report[:dropped])
  end

  # -- Findings ------------------------------------------------------------------

  defp pool_findings(p, elapsed) do
    where = "pool #{p.pool} (#{p.client} to #{p.backend})"
    w = p[:window] || %{}
    size = p.backlog_size

    down =
      cond do
        p.connections_up == 0 ->
          [
            {:critical,
             "#{where}: none of its #{p.pool_size} connections is up, so every call fails with {error, no_server}; shackle keeps reconnecting, every #{p.reconnect_ms.min} to #{p.reconnect_ms.max} ms"}
          ]

        p.connections_up < p.pool_size ->
          [
            {:warning,
             "#{where}: #{p.pool_size - p.connections_up} of #{p.pool_size} connections are down (reconnecting): calls that pick one go to another (max_retries #{p.max_retries}) or fail with {error, no_server}"}
          ]

        true ->
          []
      end

    # A call out of retries fails with {error, no_server}; each pick of a
    # full or a down connection before that counts as backlog_full or
    # disabled.
    refused =
      case w[:no_server] || 0 do
        0 ->
          []

        none ->
          [
            {:critical,
             "#{where}: #{none} calls refused with {error, no_server} in #{elapsed} ms: the connections they picked were full (#{w[:backlog_full] || 0} picks found backlog_size #{size} reached) or down (#{w[:disabled] || 0}), and their retries (max_retries #{p.max_retries}) ran out"}
          ]
      end

    replies = w[:replies] || 0
    timeouts = w[:timeout] || 0

    timed_out =
      if timeouts > 0 and timeouts / max(replies + timeouts, 1) >= 0.01,
        do: [
          {:warning,
           "#{where}: #{timeouts} of #{replies + timeouts} calls timed out ({error, timeout}) in #{elapsed} ms#{if w[:reply_ms], do: "; replies took #{w.reply_ms.p50} ms at p50, #{w.reply_ms.p95} ms at p95", else: ""}#{if w[:not_found], do: ", and #{w.not_found} replies came after their call had given up", else: ""}"}
        ],
        else: []

    full = Enum.filter(p.connections, &(is_integer(size) and (&1.in_flight || 0) >= 0.8 * size))

    backed =
      cond do
        h = p[:held_up] ->
          [
            {:warning,
             "#{where}: connection #{h.index} had #{h.in_flight} requests in flight#{if is_integer(size), do: " (of #{size})", else: ""}, while the others had at most #{h.others_at_most}: something holds that connection up (a slow request ahead of the others, as a backend answers a connection's requests in order, or a slow backend instance), and the calls behind it wait"}
          ]

        full != [] ->
          [
            {:warning,
             "#{where}: connections #{Enum.map_join(full, ", ", & &1.index)} have #{Enum.map_join(full, ", ", & &1.in_flight)} of #{size} requests in flight: the backend can't keep up"}
          ]

        true ->
          []
      end

    mailbox =
      for c <- p.connections, (c.mailbox || 0) > 1_000 do
        {:warning,
         "#{where}: connection #{c.index} has #{c.mailbox} requests in its mailbox, not yet sent: it can't send as fast as calls come"}
      end

    down ++ refused ++ timed_out ++ backed ++ mailbox
  end

  defp telemetry_findings(false, _window),
    do: [
      {:info,
       "shackle's telemetry is turned off ({shackle, telemetry} in persistent_term is false): no timeouts, refusals or reply times are counted"}
    ]

  defp telemetry_findings(_, _), do: []

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
    pools are the node's shackle pools: the client module, the backend,
    pool_size connections, the strategy that picks one per call, and
    backlog_size, the most requests in flight on one connection. Each
    connection is up (connected) or down (reconnecting, every
    reconnect_ms.min to .max ms), with its in_flight requests (sent or
    about to be, without a reply yet) and its mailbox (calls not yet
    sent). A call that picks a down or full connection tries another,
    max_retries times, then fails with {error, no_server}, whichever it
    was. callers_waiting are processes in shackle:call waiting
    for a reply, grouped by the first frame of your code. window is
    shackle's telemetry by client module: replies with their times
    (reply_ms, from the call to its reply), timeout ({error, timeout}),
    no_server (calls refused, out of retries) and why: backlog_full (a
    pick of a full connection) and disabled (of a down one), and
    not_found (replies after their call gave up).
    One connection with many in flight while the others have few is
    head-of-line blocking: the backend answers a connection's requests in
    order. Next step: trace_calls on the client module's handle_request
    for what's sent; module_code on the callers' frames; profile the
    backend if it runs on the BEAM.
    """
  end
end
