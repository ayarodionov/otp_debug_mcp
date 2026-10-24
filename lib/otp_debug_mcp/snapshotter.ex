defmodule OtpDebugMcp.Snapshotter do
  @moduledoc """
  Point-in-time system snapshots and diffs.

  Trends beat point-in-time numbers: a 2 GB binary heap might be normal, but
  +200 MB of binary heap over 60 seconds is a leak. The diff is deliberately
  compact and pre-interpreted so the agent gets "what grew" directly.
  """

  use Agent

  alias OtpDebugMcp.Target

  # Sum of every process's mailbox; processes that exit mid-scan return
  # `undefined` and are skipped by the generator pattern.
  @total_message_queue """
  lists:sum([N || P <- erlang:processes(),
                  {message_queue_len, N} <- [erlang:process_info(P, message_queue_len)]]).
  """

  # The last snapshot of each node.
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Capture a snapshot of the target, store it, return a summary."
  def take do
    # Before capturing, so the capture's own footprint is in the window.
    started_us = System.monotonic_time(:microsecond)

    case capture() do
      {:ok, snap} ->
        snap = Map.put(snap, :started_us, started_us)
        # Here, not in the Agent's process, where Target.on/2 doesn't apply.
        node = Target.connected_node()
        Agent.update(__MODULE__, &Map.put(&1, node, snap))

        {:ok,
         %{
           taken_at: snap.at,
           memory_total_mb: Float.round(snap.memory[:total] / 1_048_576, 1),
           process_count: snap.process_count,
           hint: "Wait (or let load run), then call snapshot with action=diff."
         }}

      err ->
        err
    end
  end

  @doc "Diff the target's current state against its stored snapshot."
  def diff do
    node = Target.connected_node()

    case Agent.get(__MODULE__, &Map.get(&1, node)) do
      nil ->
        {:error, "no snapshot of #{node} taken yet — call snapshot with action=take first"}

      old ->
        with {:ok, new} <- capture() do
          ours = Target.footprint_since(node, old.started_us)

          {:ok,
           %{
             window_seconds: DateTime.diff(new.at, old.at),
             memory_delta_mb:
               Map.new(new.memory, fn {k, v} ->
                 delta = v - (old.memory[k] || 0) - code_footprint(k, ours)
                 # + 0.0 turns -0.0 into 0.0.
                 {k, Float.round(delta / 1_048_576, 2) + 0.0}
               end),
             process_count_delta: new.process_count - old.process_count,
             port_count_delta: new.port_count - old.port_count,
             port_delta_by_type: port_type_delta(new.ports, old.ports),
             port_delta_by_owner: port_owner_delta(new.ports, old.ports),
             atom_count_delta: new.atom_count - old.atom_count - ours.atoms,
             total_message_queue_delta: new.total_mq - old.total_mq,
             os_memory_delta_mb: mb_delta(new.os_memory, old.os_memory),
             native_memory_delta_mb: mb_delta(outside(new), outside(old)),
             excluded_footprint_of_this_tool: %{
               atoms: ours.atoms,
               code_mb: Float.round(ours.code_bytes / 1_048_576, 2)
             },
             interpretation: """
             Positive deltas that keep growing across repeated diffs indicate \
             leaks: memory_delta.binary → refc binary leak (run binary_leak \
             check); process_count_delta → process leak; atom_count_delta > 0 \
             is always worth investigating (atoms are never freed). \
             native_memory_delta_mb is the growth of memory outside the VM's \
             allocators (the OS's memory for the node minus what they hold): memory NIFs and \
             drivers allocate themselves, which erlang:memory() never shows, so \
             growth there with memory_delta flat is a native leak (run the \
             native_memory and native_code checks). port_delta_by_type and \
             port_delta_by_owner say which kind of port grew and which \
             processes opened them: steady growth is sockets or programs never \
             closed. The deltas \
             exclude what this tool itself added to the node in the window \
             (atoms it sent, code it caused to load), shown in \
             excluded_footprint_of_this_tool.\
             """
           }}
        end
    end
  end

  # The types whose count changed, and the owners that gained the most
  # ports, named: what leaks sockets or programs, and where.
  defp port_type_delta(%{by_type: new}, %{by_type: old}) do
    for type <- Enum.uniq(Map.keys(new) ++ Map.keys(old)),
        delta = Map.get(new, type, 0) - Map.get(old, type, 0),
        delta != 0,
        into: %{},
        do: {type, delta}
  end

  defp port_type_delta(_new, _old), do: nil

  defp port_owner_delta(%{by_owner: new}, %{by_owner: old}) do
    grown =
      new
      |> Enum.map(fn {owner, n} -> {owner, n - Map.get(old, owner, 0)} end)
      |> Enum.filter(fn {_, delta} -> delta > 0 end)
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(5)

    names = OtpDebugMcp.Checks.owners(Enum.map(grown, &elem(&1, 0)))

    for {owner, delta} <- grown do
      %{owner: OtpDebugMcp.Format.inspect(owner), ports_added: delta, ports_now: new[owner]}
      |> Map.merge(Map.get(names, owner, %{}))
    end
  end

  defp port_owner_delta(_new, _old), do: nil

  defp mb_delta(new, old) when is_integer(new) and is_integer(old),
    do: Float.round((new - old) / 1_048_576, 2) + 0.0

  defp mb_delta(_new, _old), do: nil

  defp outside(%{os_memory: os, allocated: allocated})
       when is_integer(os) and is_integer(allocated),
       do: os - allocated

  defp outside(_snap), do: nil

  # Loaded code counts in erlang:memory's code, system and total.
  defp code_footprint(key, ours) when key in [:code, :system, :total], do: ours.code_bytes
  defp code_footprint(_key, _ours), do: 0

  defp capture do
    with {:ok, memory} <- Target.rpc(:erlang, :memory, []),
         {:ok, pcount} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, port_count} <- Target.rpc(:erlang, :system_info, [:port_count]),
         {:ok, atom_count} <- Target.rpc(:erlang, :system_info, [:atom_count]),
         {:ok, total_mq} <- OtpDebugMcp.Checks.remote_eval(@total_message_queue) do
      # Native memory needs the OS's RSS and recon_alloc: without either,
      # the diff leaves it out.
      os_memory =
        with {:ok, {:ok, bytes, _how}} <- OtpDebugMcp.Checks.os_memory(),
             do: bytes,
             else: (_ -> nil)

      allocated =
        with {:ok, bytes} when is_integer(bytes) <-
               Target.rpc(:recon_alloc, :memory, [:allocated]),
             do: bytes,
             else: (_ -> nil)

      ports = with {:ok, counts} <- OtpDebugMcp.Checks.port_counts(), do: counts, else: (_ -> nil)

      {:ok,
       %{
         ports: ports,
         os_memory: os_memory,
         allocated: allocated,
         at: DateTime.utc_now(),
         memory: Map.new(memory),
         process_count: pcount,
         port_count: port_count,
         atom_count: atom_count,
         total_mq: total_mq
       }}
    end
  end
end
