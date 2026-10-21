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
    :allocator_fragmentation,
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
          %{pid: Format.inspect(pid), queue_len: qlen, info: format_proc_info(pid, info)}
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
      offender's current_function and backtrace (process_info tool). To find
      who sends to it, trace the sending side, not the receiver (which only
      shows it handling messages): e.g. trace_calls on GenServer cast or call,
      whose events name the sending pid and the destination; top_reductions
      often names a flooding producer too.
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

  # One supervisor's restart history, given as Sup.
  @restart_history ~S"""
  Name =
    case erlang:process_info(Sup, registered_name) of
      {registered_name, N} when is_atom(N) -> N;
      _ -> undefined
    end,
  case catch sys:get_state(Sup, 1000) of
    {'EXIT', _} -> {Name, unresponsive};
    St -> {Name, {erlang:monotonic_time(second), History(St)}}
  end.
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
          |> Map.merge(
            if mod == Supervisor.Default, do: %{}, else: %{module: Format.inspect(mod)}
          )
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
          %{pid: Format.inspect(pid), binaries_freed: -freed, info: format_proc_info(pid, info)}
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
      `other_system` is the runtime's own memory: its process and port
      tables, distribution and driver buffers, literals and persistent
      terms. It's often the largest category on a small or idle node, and
      rarely where a leak is; watch it in snapshot diffs before suspecting
      it.
      """)
    else
      err -> error_result(:memory_breakdown, err)
    end
  end

  # Memory the VM's allocators hold from the OS against what live data
  # uses. recon_alloc reads it from erlang:system_info({allocator, A}); its
  # set_unit/1 only affects snapshots, so these are always bytes.
  def run(:allocator_fragmentation) do
    with {:ok, allocated} <- Target.rpc(:recon_alloc, :memory, [:allocated]),
         {:ok, used} <- Target.rpc(:recon_alloc, :memory, [:used]),
         {:ok, peak} <- Target.rpc(:recon_alloc, :memory, [:allocated, :max]),
         {:ok, instances} <- Target.rpc(:recon_alloc, :fragmentation, [:current]) do
      unused = allocated - used
      usage = if allocated > 0, do: used / allocated, else: 1.0

      findings = %{
        allocated_bytes: allocated,
        used_bytes: used,
        unused_bytes: unused,
        usage: Float.round(usage, 3),
        peak_allocated_bytes: peak,
        allocators: allocator_slack(instances)
      }

      result(:allocator_fragmentation, fragmentation_status(unused, usage), findings, """
      Memory the VM's allocators hold from the OS (allocated_bytes, roughly
      what the OS sees as the node's memory, apart from what NIFs and drivers
      allocate themselves) against what live data uses (used_bytes, about
      erlang:memory(total)). The difference sits in partly empty carriers:
      fragmentation. Some is normal, since allocators keep carriers for reuse,
      and small nodes often show usage near 0.5 with tens of MB unused; it
      matters when unused_bytes is large. allocators names the allocators
      holding the most slack: binary_alloc after bursts of large binaries,
      eheap_alloc after process heap spikes, ets_alloc after table churn.
      ll_alloc holds long-lived data (code, atoms, tables made at boot) and
      keeps its carriers by design, so its slack isn't fragmentation to act
      on.
      peak_allocated_bytes far above allocated_bytes means memory went back
      to the OS after a spike. Remedies are allocator flags, such as a
      different allocation strategy (+MBas aobf for binary_alloc) or smaller
      carriers; see recon_alloc's documentation and the memory chapter of
      Erlang in Anger. If the OS reports much more than allocated_bytes, the
      rest is outside the allocators: NIFs, drivers, or the code area.
      """)
    else
      err -> error_result(:allocator_fragmentation, err)
    end
  end

  # Process count vs the node's process limit, and how fast it's moving:
  # two counts a second apart (each read's own rpc process is in both, so
  # it cancels out). Plus where the processes are: grouped by initial call
  # and current function, the largest groups with a sample's stack, since a
  # leak is one group that keeps growing, and its stack names the code.
  @process_sample_ms 1_000
  @process_groups ~S"""
  %% proc_lib's '$initial_call' names the real entry point; {dictionary,
  %% Key} is OTP 26.2+.
  InitialCall = fun(P) ->
    PI =
      try erlang:process_info(P, {dictionary, '$initial_call'}) of
        {_, V} -> V;
        _ -> undefined
      catch error:badarg ->
        case erlang:process_info(P, dictionary) of
          {dictionary, D} -> proplists:get_value('$initial_call', D);
          _ -> undefined
        end
      end,
    case PI of
      undefined ->
        case erlang:process_info(P, initial_call) of
          {initial_call, IC} -> IC;
          _ -> undefined
        end;
      _ ->
        PI
    end
  end,
  Groups = lists:foldl(
    fun(P, Acc) ->
      case erlang:process_info(P, current_function) of
        {current_function, CF} ->
          Key = {InitialCall(P), CF},
          {N, Sample} = maps:get(Key, Acc, {0, P}),
          Acc#{Key => {N + 1, Sample}};
        _ -> Acc
      end
    end, #{}, erlang:processes()),
  Top = lists:sublist(lists:reverse(lists:keysort(2,
          [{K, N, S} || {K, {N, S}} <- maps:to_list(Groups)])), 5),
  [{IC, CF, N, S,
    case erlang:process_info(S, current_stacktrace) of
      {current_stacktrace, Stack} -> lists:sublist(Stack, 4);
      _ -> []
    end} || {{IC, CF}, N, S} <- Top].
  """

  def run(:process_count) do
    started = System.monotonic_time(:microsecond)

    with {:ok, count0} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, limit} <- Target.rpc(:erlang, :system_info, [:process_limit]),
         :ok <- Process.sleep(@process_sample_ms),
         {:ok, count} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, groups} <- remote_eval(@process_groups) do
      seconds = (System.monotonic_time(:microsecond) - started) / 1_000_000
      rate = (count - count0) / seconds
      seconds_left = if rate > 0, do: round((limit - count) / rate)

      status =
        cond do
          count / limit > 0.9 -> :critical
          seconds_left && seconds_left < 3_600 -> :critical
          count / limit > 0.5 -> :warning
          rate >= 50 -> :warning
          true -> :ok
        end

      findings =
        %{
          count: count,
          limit: limit,
          growth_per_second: Float.round(rate * 1.0, 1),
          largest_groups:
            for {initial_call, current_function, n, sample, stack} <- groups do
              %{
                processes: n,
                initial_call: Format.inspect(initial_call),
                current_function: Format.inspect(current_function),
                sample: Format.inspect(sample),
                sample_stack: Format.inspect(stack)
              }
            end
        }
        |> Map.merge(if seconds_left, do: %{seconds_until_limit: seconds_left}, else: %{})

      result(:process_count, status, findings, """
      Near the limit the node dies with `system_limit`. growth_per_second is
      the net change over 1s: a steady climb (confirm with snapshot diffs)
      means a process leak, workers spawned and never exiting, and
      seconds_until_limit is when the node dies at that rate. largest_groups
      groups every process by initial call and current function: a leak is
      one large group that keeps growing, and its sample_stack names the code
      that spawned or is holding the processes; process_info on the sample
      shows more. A large group of a pool's workers is normal.
      """)
    else
      err -> error_result(:process_count, err)
    end
  end

  # Atom table pressure — atoms are never GC'd; exhaustion kills the node.
  # Atoms only ever accumulate, so two counts a second apart show whether
  # something is creating them now, and how long until the table is full;
  # what this tool itself added in between doesn't count.
  @atom_sample_ms 1_000

  def run(:atom_table) do
    started = System.monotonic_time(:microsecond)

    with {:ok, node} <- Target.target(),
         {:ok, count0} <- Target.rpc(:erlang, :system_info, [:atom_count]),
         {:ok, limit} <- Target.rpc(:erlang, :system_info, [:atom_limit]),
         :ok <- Process.sleep(@atom_sample_ms),
         {:ok, count} <- Target.rpc(:erlang, :system_info, [:atom_count]) do
      seconds = (System.monotonic_time(:microsecond) - started) / 1_000_000
      ours = Target.footprint_since(node, started).atoms
      rate = max(count - count0 - ours, 0) / seconds
      seconds_left = if rate > 0, do: round((limit - count) / rate)

      status =
        cond do
          count / limit > 0.5 -> :critical
          seconds_left && seconds_left < 86_400 -> :critical
          rate > 0 -> :warning
          true -> :ok
        end

      findings =
        %{count: count, limit: limit, growth_per_second: Float.round(rate, 1)}
        |> Map.merge(if seconds_left, do: %{seconds_until_full: seconds_left}, else: %{})

      result(:atom_table, status, findings, """
      Atoms are never garbage collected, and the node dies when the table is
      full. growth_per_second is measured over 1s, not counting atoms this
      tool added; any growth means something is creating atoms right now
      (list_to_atom or binary_to_atom on input, String.to_atom/1,
      binary_to_term without safe), and seconds_until_full is when the node
      dies at that rate. Loading code adds atoms too, so confirm a leak with
      snapshot diffs, then trace_calls on erlang list_to_atom or
      binary_to_atom to find the caller.
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
            name: Format.inspect(name),
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
          %{pid: Format.inspect(pid), reductions_per_s: reds, info: format_proc_info(pid, info)}
        end

      result(:top_reductions, :ok, hogs, """
      Top CPU consumers over a 1s window (informational — something is always
      at the top). When the schedulers check shows saturation, these are the
      processes using the CPU. Otherwise, a process far above the rest is
      still worth a look: a producer flooding another process's mailbox,
      or a busy loop.
      """)
    else
      err -> error_result(:top_reductions, err)
    end
  end

  # -- Helpers -------------------------------------------------------------------

  @doc "Erlang funs InitialCall/1 and History/1, for code evaluated on the target."
  def supervisor_funs, do: @supervisor_funs

  @doc """
  The registered name, strategy and summarized restart history of
  supervisor `sup`, for supervision_tree. Without the history if its state
  can't be read as a supervisor's.
  """
  def restart_history(sup) do
    case remote_eval(@supervisor_funs <> @restart_history, Sup: sup) do
      {:ok, {name, history}} -> Map.merge(registered(name), history_fields(history))
      _ -> %{}
    end
  end

  defp registered(:undefined), do: %{}
  defp registered(name), do: %{name: Format.inspect(name)}

  defp history_fields({now, {kind, strategy, intensity, period, restarts}}) do
    %{kind: kind, strategy: strategy, restarts: restart_summary(now, intensity, period, restarts)}
  end

  defp history_fields(:unresponsive) do
    %{
      restarts:
        "unavailable: the supervisor didn't answer within 1s, usually because " <>
          "it is blocked starting a child whose init hangs"
    }
  end

  defp history_fields(_), do: %{}

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

  @mib 1_048_576

  @doc false
  # Fragmentation matters in absolute terms: a small node with half its
  # allocated memory unused is normal.
  def fragmentation_status(unused, usage) do
    cond do
      unused >= 2_048 * @mib and usage < 0.4 -> :critical
      unused >= 512 * @mib and usage < 0.6 -> :warning
      true -> :ok
    end
  end

  # Per allocator type (summing its instances), the five holding the most
  # allocated-but-unused memory.
  defp allocator_slack(instances) do
    instances
    |> Enum.group_by(fn {{alloc, _n}, _props} -> alloc end, fn {_key, props} -> props end)
    |> Enum.map(fn {alloc, props} ->
      sum = fn key -> props |> Enum.map(&Keyword.get(&1, key, 0)) |> Enum.sum() end
      allocated = sum.(:sbcs_carriers_size) + sum.(:mbcs_carriers_size)
      used = sum.(:sbcs_block_size) + sum.(:mbcs_block_size)

      %{
        allocator: alloc,
        instances: length(props),
        allocated_bytes: allocated,
        used_bytes: used,
        unused_bytes: allocated - used,
        usage: if(allocated > 0, do: Float.round(used / allocated, 3), else: 1.0)
      }
      |> Map.merge(
        if alloc == :ll_alloc,
          do: %{note: "long-lived data, which keeps its carriers by design: not fragmentation"},
          else: %{}
      )
    end)
    |> Enum.sort_by(& &1.unused_bytes, :desc)
    |> Enum.take(5)
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
        id: Format.inspect(id),
        modules: Format.inspect(mods),
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
  # name atom as the first element. Its initial_call for a proc_lib process
  # (every gen_server, supervisor, Task, Gleam actor...) is proc_lib's own
  # wrapper, so it's replaced by the real one.
  defp format_proc_info(pid, info) when is_list(info) do
    info =
      case List.keyfind(info, :initial_call, 0) do
        {:initial_call, {:proc_lib, _, _}} ->
          case Target.rpc(:proc_lib, :translate_initial_call, [pid]) do
            {:ok, real} -> List.keystore(info, :initial_call, 0, {:initial_call, real})
            _ -> info
          end

        _ ->
          info
      end

    Enum.reduce(info, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, Format.inspect(v))
      name, acc when is_atom(name) -> Map.put(acc, :registered_name, Format.inspect(name))
      other, acc -> Map.put(acc, :extra, Format.inspect(other))
    end)
  end

  defp format_proc_info(_pid, other), do: Format.inspect(other)

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
