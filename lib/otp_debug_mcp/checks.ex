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

  alias OtpDebugMcp.Target

  @checks [
    :message_queues,
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
          %{pid: inspect(pid), queue_len: qlen, info: format_proc_info(info)}
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

  # Refc-binary leak detection — the classic hidden BEAM memory leak: processes
  # holding references to large off-heap binaries that GC won't reclaim because
  # the holding process rarely runs. `recon:bin_leak/1` GCs candidates and
  # reports who released the most.
  def run(:binary_leak) do
    with {:ok, leaks} <- Target.rpc(:recon, :bin_leak, [5], 15_000) do
      offenders =
        for {pid, freed, info} <- leaks, freed < -1_000 do
          %{pid: inspect(pid), binaries_freed: -freed, info: format_proc_info(info)}
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
          %{name: inspect(name), bytes: mem_words * wordsize, rows: size, owner: inspect(owner)}
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
          %{pid: inspect(pid), reductions_per_s: reds, info: format_proc_info(info)}
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

  @doc "Evaluate an Erlang expression string on the target. Used by checks and the eval tool."
  def remote_eval(code) do
    with {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(code)),
         {:ok, exprs} <- :erl_parse.parse_exprs(tokens),
         {:ok, {:value, value, _binds}} <-
           Target.rpc(:erl_eval, :exprs, [exprs, []], 15_000) do
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
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, inspect(v))
      name, acc when is_atom(name) -> Map.put(acc, :registered_name, inspect(name))
      other, acc -> Map.put(acc, :extra, inspect(other))
    end)
  end

  defp format_proc_info(other), do: inspect(other)

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
    %{check: check, status: :error, findings: [], interpretation: "check failed: #{inspect(err)}"}
  end
end
