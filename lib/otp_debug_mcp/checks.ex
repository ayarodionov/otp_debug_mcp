defmodule OtpDebugMcp.Checks do
  @moduledoc """
  The diagnostic battery: encoded BEAM operational knowledge, in the spirit of
  recon + "Erlang in Anger".

  Each check returns a `%{check, status, findings, evidence}` map where
  `status` is `:ok | :warning | :critical | :error`. `run_all/0` runs every
  check and returns findings ranked worst-first — designed so an AI agent's
  *first* tool call already points at the likely problem instead of requiring
  twenty rounds of raw `process_info` calls.
  """

  alias OtpDebugMcp.{Format, Target}

  @checks [
    :message_queues,
    :supervisor_restarts,
    :binary_leak,
    :memory_breakdown,
    :process_count,
    :atom_table,
    :ets_tables,
    :ports,
    :schedulers,
    :top_reductions
  ]

  def all_checks, do: @checks

  @doc "Run every check; findings ranked worst-first."
  def run_all do
    @checks
    |> Enum.map(&run/1)
    |> Enum.sort_by(fn %{status: s} -> status_rank(s) end)
  end

  defp status_rank(:critical), do: 0
  defp status_rank(:error), do: 1
  defp status_rank(:warning), do: 2
  defp status_rank(:ok), do: 3

  # -- Individual checks ---------------------------------------------------------

  # Processes with large mailboxes. The single most common BEAM production
  # problem: a bottleneck process that can't keep up, usually visible long
  # before the node dies of memory exhaustion.
  def run(:message_queues) do
    with {:ok, top} <- Target.rpc(:recon, :proc_count, [:message_queue_len, 10]) do
      offenders =
        for {pid, qlen, info} <- top, qlen > 1_000 do
          %{pid: Format.inspect(pid), queue_len: qlen, info: format_proc_info(info)}
        end

      status =
        cond do
          Enum.any?(offenders, &(&1.queue_len > 100_000)) -> :critical
          offenders != [] -> :warning
          true -> :ok
        end

      result(:message_queues, status, offenders, """
      Processes with message_queue_len > 1000. A growing queue means the
      process can't keep up with its callers. Next step: inspect the worst
      offender's current_function and backtrace (process_info tool), and find
      who is sending to it (trace tool on the receiving module).
      """)
    else
      err -> error_result(:message_queues, err)
    end
  end

  # Every supervisor's restart history, read from its own state. Erlang
  # supervisors (and Elixir's Supervisor) keep it in a #state{} record
  # whose intensity, period and restarts fields have sat at positions 6-8
  # for many OTP releases; DynamicSupervisor keeps it in its struct. Both
  # record monotonic seconds, newest first, and both mark themselves with
  # an '$initial_call' of {supervisor, Module, 1}, so one process scan
  # finds them all, including supervisors outside any application.
  #
  # InitialCall and History are shared with process_info's supervisor
  # context, through supervisor_funs/0.
  @supervisor_funs ~S"""
  InitialCall = fun(P) ->
    try erlang:process_info(P, {dictionary, '$initial_call'}) of
      {_, V} -> V;
      _ -> undefined
    catch error:badarg ->
      %% {dictionary, Key} is OTP 26.2+.
      case erlang:process_info(P, dictionary) of
        {dictionary, D} -> proplists:get_value('$initial_call', D);
        _ -> undefined
      end
    end
  end,
  History = fun
    (St) when is_tuple(St), tuple_size(St) >= 8, element(1, St) =:= state,
              is_integer(element(6, St)), is_integer(element(7, St)), is_list(element(8, St)) ->
      {static, element(3, St), element(6, St), element(7, St), element(8, St)};
    (#{restarts := R, max_restarts := I, max_seconds := Pe, strategy := S}) ->
      {dynamic, S, I, Pe, R};
    (_) ->
      unknown
  end,
  """

  @supervisor_scan ~S"""
  Now = erlang:monotonic_time(second),
  Name = fun(P) ->
    case erlang:process_info(P, registered_name) of
      {registered_name, N} when is_atom(N) -> N;
      _ -> P
    end
  end,
  {Now,
   [{P, M, Name(P), application:get_application(P),
     case catch sys:get_state(P, 1000) of
       {'EXIT', _} -> unresponsive;
       St -> History(St)
     end}
    || P <- erlang:processes(), {supervisor, M, _} <- [InitialCall(P)]]}.
  """

  # Restarts this recent count as happening now.
  @recent_s 60
  @sample_ms 2_000
  @max_sampled 10

  def run(:supervisor_restarts) do
    with {:ok, {now, sups}} <- remote_eval(@supervisor_funs <> @supervisor_scan) do
      restarted =
        for {pid, mod, name, app, {kind, strategy, intensity, period, [_ | _] = restarts}} <- sups do
          %{
            supervisor: Format.inspect(name),
            pid: Format.inspect(pid),
            application: app_name(app),
            kind: kind,
            strategy: strategy,
            raw_pid: pid
          }
          |> Map.merge(restart_summary(now, intensity, period, restarts))
          # Every Supervisor.start_link(children, opts) has this callback
          # module, so it says nothing.
          |> Map.merge(if mod == Supervisor.Default, do: %{}, else: %{module: inspect(mod)})
        end
        |> Enum.sort_by(& &1.last_restart_seconds_ago)

      unresponsive = for {_pid, _, name, _, :unresponsive} <- sups, do: Format.inspect(name)

      recent = Enum.filter(restarted, &(&1.last_restart_seconds_ago <= @recent_s))
      sampled = sample_restarting_children(recent)

      findings =
        Enum.map(restarted, fn s ->
          s |> Map.delete(:raw_pid) |> Map.merge(Map.get(sampled, s.raw_pid, %{}))
        end)

      status =
        cond do
          Enum.any?(restarted, & &1.at_limit) -> :critical
          recent != [] or unresponsive != [] -> :warning
          true -> :ok
        end

      result(
        :supervisor_restarts,
        status,
        %{
          supervisors_scanned: length(sups),
          restarted: findings,
          unresponsive: unresponsive
        },
        """
        Supervisors that have restarted children, from each supervisor's own
        restart history (only recent restarts are kept, so this shows current
        activity, not totals), most recent first. restarts_in_window counts
        restarts within the last max_seconds; at_limit means one more crash in
        that window makes the supervisor give up: it terminates all its children
        and exits, so its parent restarts it or, at the top, the application
        stops. A loop that stays below the limit is the worse case: nothing
        ever fails over, and it shows up only as intermittent errors from
        whatever depends on the child. A last restart within #{@recent_s}s
        means a crash loop may be running now: restarting_children names the
        children whose pid changed during a #{div(@sample_ms, 1000)}s sample,
        with the exit_reason (including the stack trace, with file and line)
        of each one seen to die. Next step: read the code at the top of that
        stack; trace_calls on the crashing function shows its arguments.
        Unresponsive supervisors didn't answer within 1s, usually because
        they are blocked starting a child whose init hangs.
        """
      )
    else
      err -> error_result(:supervisor_restarts, err)
    end
  end

  # Refc-binary leak detection — the classic hidden BEAM memory leak: processes
  # holding references to large off-heap binaries that GC won't reclaim because
  # the holding process rarely runs. `recon:bin_leak/1` GCs candidates and
  # reports who released the most.
  def run(:binary_leak) do
    with {:ok, leaks} <- Target.rpc(:recon, :bin_leak, [5], 15_000) do
      offenders =
        for {pid, freed, info} <- leaks, freed < -1_000 do
          %{pid: Format.inspect(pid), binaries_freed: -freed, info: format_proc_info(info)}
        end

      status = if Enum.any?(offenders, &(&1.binaries_freed > 100_000)), do: :warning, else: :ok

      result(:binary_leak, status, offenders, """
      Processes that released many refc binaries when force-GC'd. Large values
      suggest a binary leak: long-lived processes touching large binaries
      without copying sub-binaries (binary:copy/1) or hibernating.
      """)
    else
      err -> error_result(:binary_leak, err)
    end
  end

  # Where the node's memory actually is (processes vs binary vs ets vs code).
  def run(:memory_breakdown) do
    with {:ok, mem} <- Target.rpc(:erlang, :memory, []) do
      total = mem[:total]

      # erlang:memory/0 categories overlap (atom, binary, code and ets are
      # all part of system; *_used are subsets), so report a partition.
      parts = [
        processes: mem[:processes],
        binary: mem[:binary],
        ets: mem[:ets],
        code: mem[:code],
        atom: mem[:atom],
        other_system: mem[:system] - mem[:binary] - mem[:ets] - mem[:code] - mem[:atom]
      ]

      breakdown =
        for {k, v} <- parts do
          %{category: k, bytes: v, percent: Float.round(100.0 * v / total, 1)}
        end
        |> Enum.sort_by(& &1.bytes, :desc)

      findings = %{total_bytes: total, breakdown: breakdown}

      result(:memory_breakdown, :ok, findings, """
      erlang:memory/0 as a partition summing to total (informational). High
      `processes` share: find the process holding it (message_queues check,
      process_info memory field). High `binary` share with
      modest `processes` share points to refc binaries (see binary_leak
      check); high `ets` means a table is growing (see ets_tables check).
      """)
    else
      err -> error_result(:memory_breakdown, err)
    end
  end

  # Process count vs the node's process limit.
  def run(:process_count) do
    with {:ok, count} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, limit} <- Target.rpc(:erlang, :system_info, [:process_limit]) do
      ratio = count / limit

      status =
        cond do
          ratio > 0.9 -> :critical
          ratio > 0.5 -> :warning
          true -> :ok
        end

      result(:process_count, status, %{count: count, limit: limit}, """
      Near the limit the node dies with `system_limit`. A steadily growing
      count usually means process leaks: spawned workers that never terminate.
      Use the snapshot/diff tool to confirm growth over time.
      """)
    else
      err -> error_result(:process_count, err)
    end
  end

  # Atom table pressure — atoms are never GC'd; exhaustion kills the node.
  def run(:atom_table) do
    with {:ok, count} <- Target.rpc(:erlang, :system_info, [:atom_count]),
         {:ok, limit} <- Target.rpc(:erlang, :system_info, [:atom_limit]) do
      ratio = count / limit
      status = if ratio > 0.5, do: :critical, else: :ok

      result(:atom_table, status, %{count: count, limit: limit}, """
      Atoms are never garbage collected. Growth at runtime means something is
      creating atoms dynamically (String.to_atom/1, :erlang.binary_to_term
      without :safe, list_to_atom on user input).
      """)
    else
      err -> error_result(:atom_table, err)
    end
  end

  # Largest ETS tables by memory.
  def run(:ets_tables) do
    code = """
    lists:sublist(
      lists:reverse(lists:keysort(2,
        [{ets:info(T, name), ets:info(T, memory), ets:info(T, size), ets:info(T, owner)}
         || T <- ets:all(), ets:info(T, memory) =/= undefined])), 10).
    """

    with {:ok, tables} <- remote_eval(code) do
      wordsize = 8

      top =
        for {name, mem_words, size, owner} <- tables do
          %{
            name: inspect(name),
            bytes: mem_words * wordsize,
            rows: size,
            owner: Format.inspect(owner)
          }
        end

      result(:ets_tables, :ok, top, """
      Ten largest ETS tables (informational). A cache without eviction or a
      table keyed on unbounded input grows forever. Compare against a later
      snapshot to confirm growth.
      """)
    else
      err -> error_result(:ets_tables, err)
    end
  end

  # Port count vs limit (sockets, files — leaks exhaust file descriptors).
  def run(:ports) do
    with {:ok, count} <- Target.rpc(:erlang, :system_info, [:port_count]),
         {:ok, limit} <- Target.rpc(:erlang, :system_info, [:port_limit]) do
      ratio = count / limit
      status = if ratio > 0.8, do: :critical, else: :ok

      result(:ports, status, %{count: count, limit: limit}, """
      Ports are sockets and file handles. Steady growth means something opens
      connections/files without closing them.
      """)
    else
      err -> error_result(:ports, err)
    end
  end

  # Scheduler utilization — the honest CPU number for a BEAM node.
  def run(:schedulers) do
    with {:ok, usage} <- Target.rpc(:recon, :scheduler_usage, [1_000], 10_000) do
      per_sched = for {id, u} <- usage, do: %{scheduler: id, usage: Float.round(u, 3)}
      busy = Enum.count(per_sched, &(&1.usage > 0.8))

      status = if busy == length(per_sched) and busy > 0, do: :warning, else: :ok

      result(:schedulers, status, per_sched, """
      recon:scheduler_usage/1 over a 1s window — unlike OS CPU%, this excludes
      busy-wait spinning. All schedulers pegged means genuine CPU saturation;
      one pegged scheduler with the rest idle can mean a long-running NIF.
      """)
    else
      err -> error_result(:schedulers, err)
    end
  end

  # Busiest processes by reductions (CPU) over a sampling window.
  def run(:top_reductions) do
    with {:ok, top} <- Target.rpc(:recon, :proc_window, [:reductions, 5, 1_000], 10_000) do
      hogs =
        for {pid, reds, info} <- top do
          %{pid: Format.inspect(pid), reductions_per_s: reds, info: format_proc_info(info)}
        end

      result(:top_reductions, :ok, hogs, """
      Top CPU consumers over a 1s window (informational — something is always
      at the top). Only meaningful when the schedulers check shows saturation.
      """)
    else
      err -> error_result(:top_reductions, err)
    end
  end

  # -- Helpers -------------------------------------------------------------------

  @doc "Erlang funs InitialCall/1 and History/1, for code evaluated on the target."
  def supervisor_funs, do: @supervisor_funs

  @doc """
  A supervisor's restart history, as read by History/1, summarized. `now`
  is the target's `erlang:monotonic_time(second)`.
  """
  def restart_summary(now, intensity, period, restarts) do
    in_window = Enum.count(restarts, &(&1 >= now - period))

    %{
      max_restarts: intensity,
      max_seconds: period,
      restarts_in_window: in_window,
      last_restart_seconds_ago: if(restarts != [], do: now - Enum.max(restarts)),
      at_limit: in_window > 0 and in_window >= intensity
    }
  end

  defp app_name({:ok, app}), do: app
  defp app_name(_), do: nil

  # Which children are restarting: compare each supervisor's children in
  # two samples taken @sample_ms apart. Dynamic supervisors' children have
  # no stable ids to compare by.
  defp sample_restarting_children(sups) do
    {static, dynamic} =
      sups
      |> Enum.take(@max_sampled)
      |> Enum.split_with(&(&1.kind == :static and &1.strategy != :simple_one_for_one))

    before = Map.new(static, &{&1.raw_pid, children_by_id(&1.raw_pid)})

    # Monitoring a child is passive, and a child that dies during the sample
    # tells us why, stack trace included.
    monitors =
      for {_sup, children} <- before,
          children,
          {_id, {pid, _}} <- children,
          is_pid(pid),
          into: %{},
          do: {Process.monitor(pid), pid}

    if static != [], do: Process.sleep(@sample_ms)
    reasons = collect_exit_reasons(monitors)

    sampled =
      Map.new(static, fn sup ->
        changed = changed(before[sup.raw_pid], children_by_id(sup.raw_pid), reasons)
        {sup.raw_pid, %{restarting_children: changed}}
      end)

    Enum.reduce(dynamic, sampled, fn sup, acc ->
      Map.put(acc, sup.raw_pid, %{
        restarting_children: "not sampled: a dynamic supervisor's children have no stable ids"
      })
    end)
  end

  defp children_by_id(sup) do
    case Target.rpc(:supervisor, :which_children, [sup], 2_000) do
      {:ok, children} when is_list(children) ->
        Map.new(children, fn {id, pid, _type, mods} -> {id, {pid, mods}} end)

      _ ->
        nil
    end
  end

  defp collect_exit_reasons(monitors) do
    Map.new(monitors, fn {ref, pid} ->
      receive do
        {:DOWN, ^ref, :process, _, reason} -> {pid, reason}
      after
        0 ->
          Process.demonitor(ref, [:flush])
          {pid, nil}
      end
    end)
  end

  defp changed(nil, _, _), do: "unavailable: which_children failed"
  defp changed(_, nil, _), do: "unavailable: which_children failed"

  defp changed(before, now, reasons) do
    for {id, {pid, mods}} <- now,
        {old_pid, _} = Map.get(before, id, {nil, nil}),
        pid != old_pid or pid == :restarting do
      %{
        id: inspect(id),
        modules: inspect(mods),
        pid_before: Format.inspect(old_pid),
        pid_now: Format.inspect(pid)
      }
      |> Map.merge(exit_reason(reasons[old_pid]))
    end
  end

  defp exit_reason(nil), do: %{}

  # In Erlang syntax and depth-limited, like trace lines.
  defp exit_reason(reason),
    do: %{exit_reason: Format.erlang(~c"~9999tP", [reason, 20], chars_limit: 1500)}

  @doc """
  Evaluate an Erlang expression string on the target, with `bindings` as
  its variables (e.g. `[Pid: pid]`). Used by checks and the eval tool.
  """
  def remote_eval(code, bindings \\ []) do
    # A list of bindings is an orddict to erl_eval, so it must be sorted.
    with {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(code)),
         {:ok, exprs} <- :erl_parse.parse_exprs(tokens),
         {:ok, {:value, value, _binds}} <-
           Target.rpc(:erl_eval, :exprs, [exprs, Enum.sort(bindings)], 15_000) do
      {:ok, value}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  # recon's attribute list mixes {key, value} pairs with a bare registered
  # name atom as the first element.
  defp format_proc_info(info) when is_list(info) do
    Enum.reduce(info, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, Format.inspect(v))
      name, acc when is_atom(name) -> Map.put(acc, :registered_name, inspect(name))
      other, acc -> Map.put(acc, :extra, Format.inspect(other))
    end)
  end

  defp format_proc_info(other), do: Format.inspect(other)

  defp result(check, status, findings, interpretation) do
    %{
      check: check,
      status: status,
      findings: findings,
      interpretation: String.trim(interpretation)
    }
  end

  defp error_result(check, {:error, message}) when is_binary(message),
    do: %{check: check, status: :error, findings: [], interpretation: "check failed: " <> message}

  defp error_result(check, err) do
    %{
      check: check,
      status: :error,
      findings: [],
      interpretation: "check failed: #{Format.inspect(err)}"
    }
  end
end
