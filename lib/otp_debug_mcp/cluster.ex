defmodule OtpDebugMcp.Cluster do
  @moduledoc """
  Several nodes of one cluster at once: find them, connect to them all, and
  run the same measurement on each, in parallel, so they can be compared.

  The members are the current target and the nodes it sees (`nodes()`),
  then the nodes those see, so a node partitioned away from the current
  target is still found through the others. They're attached as hidden
  nodes with the current target's cookie, since a cluster shares one. An
  explicit list of nodes can be given instead.
  """

  alias OtpDebugMcp.{Checks, Format, Snapshotter, Target}

  @max_nodes 50
  @timeout 60_000

  @doc """
  The cluster's members, connected: `{:ok, members, unreachable}`, the
  current target first.
  """
  def members(nodes \\ nil)

  def members(nil) do
    with {:ok, current} <- Target.target() do
      {members, unreachable} = discover([current], MapSet.new([current]), [current], [])
      {:ok, members, unreachable}
    end
  end

  def members(nodes) when is_list(nodes) do
    with {:ok, current} <- Target.target() do
      {members, unreachable} =
        nodes
        |> Enum.map(&String.to_atom/1)
        |> Enum.uniq()
        |> Enum.reduce({[], []}, fn
          ^current, {ok, failed} -> {ok ++ [current], failed}
          node, acc -> attach(node, acc)
        end)

      {:ok, members, unreachable}
    end
  end

  # Breadth first over each member's view of the cluster.
  defp discover([], _seen, members, unreachable), do: {members, unreachable}

  defp discover([node | frontier], seen, members, unreachable) do
    view =
      case Target.on(node, fn -> Target.rpc(:erlang, :nodes, []) end) do
        {:ok, view} -> view
        _ -> []
      end

    new =
      view |> Enum.reject(&MapSet.member?(seen, &1)) |> Enum.take(@max_nodes - length(members))

    {attached, failed} = Enum.reduce(new, {[], unreachable}, &attach/2)
    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    discover(frontier ++ attached, seen, members ++ attached, failed)
  end

  defp attach(node, {ok, failed}) do
    case Target.attach(node) do
      {:ok, _recon} -> {ok ++ [node], failed}
      {:error, reason} -> {ok, failed ++ [%{node: node, reason: Format.inspect(reason)}]}
    end
  end

  @doc "Run `fun.(node)` against every member, in parallel: `[{node, result}]`."
  def each(members, fun) do
    members
    |> Task.async_stream(fn node -> Target.on(node, fn -> fun.(node) end) end,
      timeout: @timeout,
      on_timeout: :kill_task,
      max_concurrency: 16
    )
    |> Enum.zip(members)
    |> Enum.map(fn
      {{:ok, result}, node} -> {node, result}
      {{:exit, reason}, node} -> {node, {:error, "did not finish: #{Format.inspect(reason)}"}}
    end)
  end

  # -- compare ---------------------------------------------------------------

  @basics ~S"""
  {erlang:memory(), erlang:system_info(process_count), erlang:system_info(port_count),
   erlang:system_info(atom_count), erlang:statistics(run_queue), nodes(),
   element(1, erlang:statistics(wall_clock)), erlang:system_info(otp_release)}.
  """

  # Metric, how to read it from a row, how many times the other nodes'
  # median a value must be, and the least difference from that median that
  # counts, so small absolute gaps on idle nodes aren't flagged. Atoms get a
  # lower ratio: nodes running the same code should have nearly the same
  # count, and atoms are never freed.
  @metrics [
    {:memory_total_mb, [:memory_mb, :total], 2, 100},
    {:memory_processes_mb, [:memory_mb, :processes], 2, 50},
    {:memory_binary_mb, [:memory_mb, :binary], 2, 50},
    {:memory_ets_mb, [:memory_mb, :ets], 2, 50},
    {:process_count, [:process_count], 2, 1_000},
    {:port_count, [:port_count], 2, 100},
    {:atom_count, [:atom_count], 1.3, 5_000},
    {:run_queue, [:run_queue], 2, 10},
    {:scheduler_usage, [:scheduler_usage], 2, 0.3},
    {:max_message_queue, [:max_message_queue, :length], 2, 1_000},
    {:supervisors_restarting, [:supervisors_restarting], 2, 1}
  ]

  @doc "One row of key metrics per member, outliers, and partitions."
  def compare(nodes \\ nil) do
    with {:ok, members, unreachable} <- members(nodes) do
      rows = each(members, fn node -> row(node) end)
      {good, bad} = Enum.split_with(rows, fn {_node, row} -> is_map(row) end)
      good_rows = Enum.map(good, fn {_node, row} -> row end)

      partitions = partitions(good_rows, members)
      outliers = outliers(good_rows)

      failed =
        unreachable ++ for({node, {:error, reason}} <- bad, do: %{node: node, reason: reason})

      status =
        cond do
          partitions != [] -> :critical
          outliers != [] or failed != [] -> :warning
          true -> :ok
        end

      {:ok,
       %{
         status: status,
         nodes: good_rows,
         outliers: outliers,
         partitions: partitions,
         unreachable: failed,
         interpretation: """
         One row per node: memory in MB, counts, run queue, mean scheduler \
         usage over 1s, the largest mailbox, and how many supervisors \
         restarted children in the last minute. outliers lists each node \
         whose value is at least twice the other nodes' median (1.3 times \
         for atoms), and above it by a margin that matters (e.g. 100 MB of \
         memory, 1000 processes or messages, 5000 atoms). In a cluster whose nodes run the same code, an outlier \
         is where to look: connect to it and run diagnose. partitions lists \
         nodes that don't see members they should: a netsplit, or a node \
         that never joined; split-brain trouble (duplicate singletons, \
         diverging state) often follows. unreachable lists nodes this tool \
         couldn't connect to.\
         """
       }}
    end
  end

  defp row(node) do
    with {:ok, {memory, procs, ports, atoms, run_queue, view, uptime_ms, otp}} <-
           Checks.remote_eval(@basics) do
      mb = fn key -> Float.round(memory[key] / 1_048_576, 1) end

      %{
        node: node,
        otp_release: to_string(otp),
        uptime_seconds: div(uptime_ms, 1000),
        memory_mb: %{
          total: mb.(:total),
          processes: mb.(:processes),
          binary: mb.(:binary),
          ets: mb.(:ets)
        },
        process_count: procs,
        port_count: ports,
        atom_count: atoms,
        run_queue: run_queue,
        scheduler_usage: scheduler_usage(),
        max_message_queue: max_message_queue(),
        supervisors_restarting: supervisors_restarting(),
        sees: Enum.sort(view)
      }
    end
  end

  defp scheduler_usage do
    case Target.rpc(:recon, :scheduler_usage, [1_000], 10_000) do
      {:ok, [_ | _] = usage} ->
        Float.round(Enum.sum(Enum.map(usage, &elem(&1, 1))) / length(usage), 3)

      _ ->
        nil
    end
  end

  defp max_message_queue do
    case Target.rpc(:recon, :proc_count, [:message_queue_len, 1]) do
      {:ok, [{_pid, 0, _info}]} ->
        %{length: 0}

      {:ok, [{pid, len, info}]} ->
        name = Enum.find(info, &is_atom/1)
        %{length: len, pid: Format.inspect(pid), registered_name: name && inspect(name)}

      _ ->
        nil
    end
  end

  defp supervisors_restarting do
    case Checks.run(:supervisor_restarts) do
      %{findings: %{restarted: restarted}} ->
        Enum.count(restarted, &(&1.last_restart_seconds_ago <= 60))

      _ ->
        nil
    end
  end

  # Members a node doesn't see, besides itself.
  defp partitions(rows, members) do
    for %{node: node, sees: sees} <- rows,
        missing = members -- [node | sees],
        missing != [] do
      %{node: node, does_not_see: missing}
    end
  end

  defp outliers(rows) when length(rows) < 2, do: []

  defp outliers(rows) do
    for {metric, path, ratio, margin} <- @metrics,
        row <- rows,
        value = get_in(row, path),
        is_number(value),
        others =
          for(other <- rows, other.node != row.node, v = get_in(other, path), is_number(v), do: v),
        others != [],
        median = median(others),
        value - median >= margin and value >= ratio * median do
      %{node: row.node, metric: metric, value: value, others_median: median}
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # -- diagnose --------------------------------------------------------------

  @doc "The full diagnose on every member, keeping what isn't ok."
  def diagnose(nodes \\ nil) do
    with {:ok, members, unreachable} <- members(nodes) do
      results = each(members, fn _node -> Checks.run_all() end)

      per_node =
        for {node, checks} <- results, is_list(checks) do
          problems = Enum.reject(checks, &(&1.status == :ok))

          %{
            node: node,
            worst: worst(problems),
            problems: Enum.map(problems, &Map.delete(&1, :interpretation))
          }
        end
        |> Enum.sort_by(&rank(&1.worst))

      interpretations =
        for {_node, checks} <- results,
            is_list(checks),
            check <- checks,
            check.status != :ok,
            into: %{},
            do: {check.check, check.interpretation}

      {:ok,
       %{
         nodes: per_node,
         interpretations: interpretations,
         unreachable:
           unreachable ++ for({node, {:error, r}} <- results, do: %{node: node, reason: r})
       }}
    end
  end

  defp worst([]), do: :ok
  defp worst(problems), do: problems |> Enum.map(& &1.status) |> Enum.min_by(&rank/1)

  defp rank(:critical), do: 0
  defp rank(:error), do: 1
  defp rank(:warning), do: 2
  defp rank(:ok), do: 3

  # -- snapshots -------------------------------------------------------------

  @doc "A snapshot of every member."
  def snapshot_take(nodes \\ nil) do
    with {:ok, members, unreachable} <- members(nodes) do
      taken = each(members, fn _node -> Snapshotter.take() end)

      {:ok,
       %{
         taken: for({node, {:ok, s}} <- taken, do: Map.put(s, :node, node)),
         unreachable:
           unreachable ++ for({node, {:error, r}} <- taken, do: %{node: node, reason: r}),
         hint: "Wait (or let load run), then call cluster with action=snapshot_diff."
       }}
    end
  end

  @doc "Every member's diff against its snapshot, the biggest growth first."
  def snapshot_diff(nodes \\ nil) do
    with {:ok, members, unreachable} <- members(nodes) do
      diffs = each(members, fn _node -> Snapshotter.diff() end)

      growth =
        for {node, {:ok, d}} <- diffs do
          %{
            node: node,
            memory_total_delta_mb: d.memory_delta_mb[:total],
            memory_binary_delta_mb: d.memory_delta_mb[:binary],
            process_count_delta: d.process_count_delta,
            atom_count_delta: d.atom_count_delta,
            total_message_queue_delta: d.total_message_queue_delta,
            window_seconds: d.window_seconds
          }
        end
        |> Enum.sort_by(& &1.memory_total_delta_mb, :desc)

      {:ok,
       %{
         growth: growth,
         unreachable:
           unreachable ++
             for({node, {:error, r}} <- diffs, do: %{node: node, reason: Format.inspect(r)}),
         interpretation:
           "Each node's change since its snapshot, the most memory growth first. " <>
             "In a cluster running the same code, a node growing while the others " <>
             "stay flat is the one to investigate: connect to it and use snapshot " <>
             "and diagnose there. The deltas exclude what this tool added."
       }}
    end
  end
end
