defmodule OtpDebugMcp.CallChains do
  @moduledoc """
  Who waits on whom: processes blocked in a call (`gen_server:call`,
  `GenServer.call`, `gen_statem:call`, anything through `gen:call`), in
  `Task.await`, or in `proc_lib:start_link` waiting for a new process's
  init, and the process each waits on.

  A waiting process monitors the one it waits on, and its backtrace has
  the call's monitor reference, and for `gen_server:call` the request and
  the timeout. The node is sampled twice, a second apart: a process still
  waiting on the same reference has waited at least that long. Those
  waits make a graph, in which a cycle is a deadlock, a long path a chain
  of calls, and a process many wait on a bottleneck.

  Processes whose group leader is on another node, such as this tool's
  own rpc processes, are left out.
  """

  alias OtpDebugMcp.{Checks, Format}

  @interval_ms 1_000
  @max_waiters 2_000

  @sample ~S"""
  Waits = #{{gen, do_call, 4} => call,
            {'Elixir.Task', await_receive, 3} => await, {'Elixir.Task', await, 2} => await,
            {proc_lib, sync_start, 2} => start, {proc_lib, sync_start_link, 2} => start,
            {proc_lib, sync_start_monitor, 2} => start},
  Regs = fun(Frame) ->
    [V || Line <- binary:split(Frame, <<"\n">>, [global]),
          {match, [V]} <- [re:run(Line, "^y\\(\\d+\\)\\s+(.*)$", [{capture, all_but_first, binary}])]]
  end,
  PidsIn = fun(Text) ->
    case re:run(Text, "<\\d+\\.\\d+\\.\\d+>", [global, {capture, first, list}]) of
      {match, Found} -> [Pd || [S] <- Found, Pd <- [catch list_to_pid(S)], is_pid(Pd)];
      nomatch -> []
    end
  end,
  Named = fun(undefined) -> [];
             (Server) ->
               Name = string:trim(binary_to_list(Server), both, "'"),
               case catch whereis(list_to_existing_atom(Name)) of
                 Pd when is_pid(Pd) -> [Pd];
                 _ -> []
               end
          end,
  Short = fun(undefined) -> undefined;
             (Bin) when byte_size(Bin) > 300 -> <<(binary:part(Bin, 0, 300))/binary, "...">>;
             (Bin) -> Bin
          end,
  Waiter = fun(P, Kind) ->
    Frames = case erlang:process_info(P, backtrace) of
      {backtrace, Bt} -> binary:split(Bt, <<"Return addr">>, [global]);
      _ -> []
    end,
    {Top, Caller} = case Frames of [T, C | _] -> {T, C}; [T] -> {T, <<>>}; [] -> {<<>>, <<>>} end,
    Ref = case re:run(Top, "#Ref<[^>]*>", [{capture, first, binary}]) of {match, [R]} -> R; _ -> undefined end,
    CallFun = case re:run(Caller, "^[^(]*\\(([^ ]+) \\+", [{capture, all_but_first, binary}]) of
      {match, [F]} -> F;
      _ -> undefined
    end,
    {Timeout, Request, Server} =
      case {CallFun, [V || V <- Regs(Caller), binary:longest_common_prefix([V, <<"Catch ">>]) < 6]} of
        {Cf, [Tm, Rq, Sv]} when Cf =:= <<"gen_server:call/3">>;
                                Cf =:= <<"'Elixir.GenServer':call/3">>;
                                Cf =:= <<"gen_statem:call/3">> -> {Tm, Rq, Sv};
        {<<"gen_server:call/2">>, [Rq, Sv]} -> {<<"5000">>, Rq, Sv};
        {<<"gen_statem:call/3">>, [Rq, Sv]} -> {<<"infinity">>, Rq, Sv};
        _ -> {undefined, undefined, undefined}
      end,
    Monitored = case erlang:process_info(P, monitors) of
      {monitors, Ms} -> [Tg || {process, Tg} <- Ms];
      _ -> []
    end,
    Linked = case Kind of
      start -> case erlang:process_info(P, links) of {links, Ls} -> Ls; _ -> [] end;
      _ -> []
    end,
    Candidates = Monitored ++ [L || L <- Linked, is_pid(L)],
    Mentioned = PidsIn(<<Top/binary, Caller/binary>>) ++ Named(Server),
    Callee = case [Cd || Cd <- Candidates, lists:member(Cd, Mentioned)] of
      [Cd | _] -> Cd;
      [] -> case Candidates of [Cd | _] -> Cd; [] -> undefined end
    end,
    {P, Kind, Callee, Ref, CallFun, Timeout, Short(Request)}
  end,
  Sample = fun() ->
    Found = [{P, K} || P <- erlang:processes(),
                       {current_function, F} <- [erlang:process_info(P, current_function)],
                       K <- [maps:get(F, Waits, none)], K =/= none,
                       {group_leader, G} <- [erlang:process_info(P, group_leader)],
                       node(G) =:= node()],
    maps:from_list([{P, Waiter(P, K)} || {P, K} <- lists:sublist(Found, Max)])
  end,
  First = Sample(),
  timer:sleep(Interval),
  Second = Sample(),
  Waited = [W || {P, {_, _, _, Ref2, _, _, _} = W} <- maps:to_list(Second), Ref2 =/= undefined,
                 {_, _, _, Ref1, _, _, _} <- [maps:get(P, First, {x, x, x, none, x, x, x})],
                 Ref1 =:= Ref2],
  Kinds = lists:foldl(fun({_, K, _, _, _, _, _}, Acc) -> maps:update_with(K, fun(N) -> N + 1 end, 1, Acc) end,
                      #{}, maps:values(Second)),
  Involved = lists:usort([P || {P, _, _, _, _, _, _} <- Waited]
                         ++ [C || {_, _, C, _, _, _, _} <- Waited, is_pid(C), node(C) =:= node()]),
  Infos = [{P, Initial(P), catch erlang:process_info(P, [registered_name, current_function,
                                                          message_queue_len, status])}
           || P <- Involved],
  {Waited, maps:size(Second), Kinds, Infos}.
  """

  @doc "The check's status, findings and interpretation."
  def run do
    code = Checks.supervisor_funs() <> Checks.initial_call_fun() <> @sample

    with {:ok, {waited, waiting_now, kinds, infos}} <-
           Checks.remote_eval(code, Interval: @interval_ms, Max: @max_waiters) do
      procs = Map.new(infos, fn {pid, initial, info} -> {pid, {initial, info}} end)

      edges =
        Map.new(waited, fn {pid, kind, callee, _ref, fun, timeout, request} ->
          {pid,
           %{
             kind: kind,
             callee: defined(callee),
             fun: defined(fun),
             timeout: defined(timeout),
             request: defined(request)
           }}
        end)

      deadlocks = cycles(edges)
      in_cycle = deadlocks |> List.flatten() |> MapSet.new()
      chains = chains(edges, in_cycle)
      busiest = busiest(edges, in_cycle)

      findings = %{
        waiting_now: waiting_now,
        by_kind: kinds,
        waiting_over_1s: map_size(edges),
        deadlocks:
          Enum.map(deadlocks, fn cycle ->
            for pid <- cycle do
              step(pid, edges, procs)
              |> put(:also_waiting_on_it, outside_waiters(pid, cycle, edges))
            end
          end),
        chains: Enum.map(chains, fn chain -> Enum.map(chain, &step(&1, edges, procs)) end),
        most_waited_on:
          for {callee, waiters} <- busiest do
            callee
            |> describe(procs)
            |> Map.merge(%{
              waiting_processes: length(waiters),
              some_waiters: waiters |> Enum.take(3) |> Enum.map(&step(&1, edges, procs))
            })
          end
      }

      status =
        cond do
          deadlocks != [] -> :critical
          chains != [] -> :warning
          Enum.any?(busiest, fn {_, waiters} -> length(waiters) >= 5 end) -> :warning
          true -> :ok
        end

      {:ok, status, findings, interpretation()}
    end
  end

  defp defined(:undefined), do: nil
  defp defined(value), do: value

  # Each process waits on at most one: following the waits from every
  # process finds each cycle, kept once.
  defp cycles(edges) do
    edges
    |> Map.keys()
    |> Enum.flat_map(fn start ->
      case walk(start, edges, [start]) do
        {:cycle, cycle} -> [cycle]
        _ -> []
      end
    end)
    |> Enum.uniq_by(&Enum.sort/1)
    |> Enum.map(&rotate/1)
  end

  defp walk(current, edges, path) do
    case edges[current] do
      %{callee: next} when next != nil ->
        case Enum.find_index(path, &(&1 == next)) do
          nil -> walk(next, edges, [next | path])
          i -> {:cycle, path |> Enum.take(i + 1) |> Enum.reverse()}
        end

      _ ->
        {:end, Enum.reverse(path)}
    end
  end

  # The same cycle, wherever it was entered: from its smallest pid.
  defp rotate(cycle) do
    {before, from} = Enum.split(cycle, Enum.find_index(cycle, &(&1 == Enum.min(cycle))))
    from ++ before
  end

  # Paths of three processes or more, from a process nobody waits on to
  # one that waits on nobody: the longest first.
  defp chains(edges, in_cycle) do
    callees = edges |> Map.values() |> Enum.map(& &1.callee) |> MapSet.new()

    edges
    |> Map.keys()
    |> Enum.reject(&(MapSet.member?(callees, &1) or MapSet.member?(in_cycle, &1)))
    |> Enum.flat_map(fn root ->
      case walk(root, edges, [root]) do
        {:end, path} when length(path) >= 3 -> [path]
        _ -> []
      end
    end)
    |> Enum.sort_by(&(-length(&1)))
    |> Enum.uniq_by(&List.last/1)
    |> Enum.take(3)
  end

  # The processes, outside the cycle, that wait on a deadlocked one: they
  # wait forever too.
  defp outside_waiters(pid, cycle, edges) do
    case Enum.count(edges, fn {waiter, e} -> e.callee == pid and waiter not in cycle end) do
      0 -> nil
      n -> n
    end
  end

  # Processes two or more wait on, but for a deadlock's own.
  defp busiest(edges, in_cycle) do
    edges
    |> Enum.group_by(fn {_pid, e} -> e.callee end, fn {pid, _} -> pid end)
    |> Enum.reject(fn {callee, waiters} ->
      is_nil(callee) or length(waiters) < 2 or MapSet.member?(in_cycle, callee)
    end)
    |> Enum.sort_by(fn {_, waiters} -> -length(waiters) end)
    |> Enum.take(5)
  end

  # A process on the path, and what it waits for if it does.
  defp step(pid, edges, procs) do
    base = describe(pid, procs)

    case edges[pid] do
      nil ->
        base

      e ->
        base
        |> Map.put(:waits_on, waiting_label(e, procs))
        |> put(:call, e.fun)
        |> put(:request, term(e.request))
        |> put(:timeout, term(e.timeout))
    end
  end

  defp waiting_label(%{kind: kind, callee: callee}, procs) do
    what =
      case kind do
        :call -> "a call to"
        :await -> "the task"
        :start -> "the init of"
      end

    "#{what} #{name_of(callee, procs)}"
  end

  defp name_of({name, node}, _procs), do: "#{Format.inspect(name)} on #{node}"
  defp name_of(nil, _procs), do: "an unknown process"

  defp name_of(pid, procs) do
    with {_, info} when is_list(info) <- procs[pid],
         registered when is_binary(registered) <- name(info[:registered_name]) do
      "#{registered} (#{Format.inspect(pid)})"
    else
      _ -> Format.inspect(pid)
    end
  end

  # A request or timeout as the node printed it, in the target's syntax
  # when it reads back as a term (it can't with pids, refs or funs in it).
  defp term(nil), do: nil

  defp term(text) do
    with false <- String.ends_with?(text, "..."),
         {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(text <> ".")),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      if is_integer(term), do: term, else: Format.inspect(term)
    else
      _ -> text
    end
  end

  defp describe({name, node}, _procs) when is_atom(node),
    do: %{process: "#{Format.inspect(name)} on #{node}", remote: true}

  defp describe(pid, procs) when is_pid(pid) do
    case procs[pid] do
      {initial, info} when is_list(info) ->
        %{process: Format.inspect(pid)}
        |> put(:name, name(info[:registered_name]))
        |> put(:initial_call, initial && Format.inspect(initial))
        |> Map.merge(%{
          current_function: Format.inspect(info[:current_function]),
          message_queue_len: info[:message_queue_len],
          status: info[:status]
        })

      {_initial, _} ->
        %{process: Format.inspect(pid), exited: true}

      nil ->
        if node(pid) == node(),
          do: %{process: Format.inspect(pid)},
          else: %{process: Format.inspect(pid), node: node(pid)}
    end
  end

  defp describe(other, _procs), do: %{process: Format.inspect(other)}

  defp name(name) when is_atom(name) and name not in [nil, []], do: Format.inspect(name)
  defp name(_), do: nil

  defp put(map, _key, value) when value in [nil, :undefined], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    Processes waiting on another: in a call (gen_server/GenServer/gen_statem \
    call), in Task.await, or in proc_lib:start_link for a new process's \
    init. waiting_now counts them; waiting_over_1s those still waiting on \
    the same call a second later, which the rest is about. A deadlock is \
    processes waiting on each other in a cycle: none can answer, so each \
    waits until its call times out, or forever with timeout infinity \
    (usually two gen_servers calling each other, or one calling itself \
    through another). A chain is calls waiting on calls: the last process \
    in it is the one to look at, since all the others wait on it. \
    most_waited_on is the processes with the most waiters: a bottleneck, \
    or one stuck itself (see its current_function and message_queue_len). \
    request and timeout are the call's, for gen_server and gen_statem calls. \
    Next step: process_info on the last process of a chain or the most \
    waited on; module_code on the callbacks of a deadlock's processes, for \
    the calls they make to each other. Fixes: a cast or a reply from \
    another process instead of a call back, a timeout instead of infinity, \
    or no call into a process from its own callbacks.\
    """
  end
end
