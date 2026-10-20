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

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "Capture a snapshot, store it, return a summary."
  def take do
    # Before capturing, so the capture's own footprint is in the window.
    started_us = System.monotonic_time(:microsecond)

    case capture() do
      {:ok, snap} ->
        snap = Map.put(snap, :started_us, started_us)
        Agent.update(__MODULE__, fn _ -> snap end)

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

  @doc "Diff current state against the stored snapshot."
  def diff do
    case Agent.get(__MODULE__, & &1) do
      nil ->
        {:error, "no snapshot taken yet — call snapshot with action=take first"}

      old ->
        with {:ok, new} <- capture() do
          ours = Target.footprint_since(old.started_us)

          {:ok,
           %{
             window_seconds: DateTime.diff(new.at, old.at),
             memory_delta_mb:
               Map.new(new.memory, fn {k, v} ->
                 delta = v - (old.memory[k] || 0) - code_footprint(k, ours)
                 {k, Float.round(delta / 1_048_576, 2)}
               end),
             process_count_delta: new.process_count - old.process_count,
             port_count_delta: new.port_count - old.port_count,
             atom_count_delta: new.atom_count - old.atom_count - ours.atoms,
             total_message_queue_delta: new.total_mq - old.total_mq,
             excluded_footprint_of_this_tool: %{
               atoms: ours.atoms,
               code_mb: Float.round(ours.code_bytes / 1_048_576, 2)
             },
             interpretation: """
             Positive deltas that keep growing across repeated diffs indicate \
             leaks: memory_delta.binary → refc binary leak (run binary_leak \
             check); process_count_delta → process leak; atom_count_delta > 0 \
             is always worth investigating (atoms are never freed). The deltas \
             exclude what this tool itself added to the node in the window \
             (atoms it sent, code it caused to load), shown in \
             excluded_footprint_of_this_tool.\
             """
           }}
        end
    end
  end

  # Loaded code counts in erlang:memory's code, system and total.
  defp code_footprint(key, ours) when key in [:code, :system, :total], do: ours.code_bytes
  defp code_footprint(_key, _ours), do: 0

  defp capture do
    with {:ok, memory} <- Target.rpc(:erlang, :memory, []),
         {:ok, pcount} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, port_count} <- Target.rpc(:erlang, :system_info, [:port_count]),
         {:ok, atom_count} <- Target.rpc(:erlang, :system_info, [:atom_count]),
         {:ok, total_mq} <- OtpDebugMcp.Checks.remote_eval(@total_message_queue) do
      {:ok,
       %{
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
