defmodule OtpDebugMcp.Snapshotter do
  @moduledoc """
  Point-in-time system snapshots and diffs.

  Trends beat point-in-time numbers: a 2 GB binary heap might be normal, but
  +200 MB of binary heap over 60 seconds is a leak. The diff is deliberately
  compact and pre-interpreted so the agent gets "what grew" directly.
  """

  use Agent

  alias OtpDebugMcp.Target

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "Capture a snapshot, store it, return a summary."
  def take do
    case capture() do
      {:ok, snap} ->
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
          {:ok,
           %{
             window_seconds: DateTime.diff(new.at, old.at),
             memory_delta_mb:
               Map.new(new.memory, fn {k, v} ->
                 {k, Float.round((v - (old.memory[k] || 0)) / 1_048_576, 2)}
               end),
             process_count_delta: new.process_count - old.process_count,
             port_count_delta: new.port_count - old.port_count,
             atom_count_delta: new.atom_count - old.atom_count,
             total_message_queue_delta: new.total_mq - old.total_mq,
             interpretation: """
             Positive deltas that keep growing across repeated diffs indicate \
             leaks: memory_delta.binary → refc binary leak (run binary_leak \
             check); process_count_delta → process leak; atom_count_delta > 0 \
             is always worth investigating (atoms are never freed).\
             """
           }}
        end
    end
  end

  defp capture do
    with {:ok, memory} <- Target.rpc(:erlang, :memory, []),
         {:ok, pcount} <- Target.rpc(:erlang, :system_info, [:process_count]),
         {:ok, port_count} <- Target.rpc(:erlang, :system_info, [:port_count]),
         {:ok, atom_count} <- Target.rpc(:erlang, :system_info, [:atom_count]),
         {:ok, mqs} <-
           Target.rpc(:erlang, :statistics, [:total_run_queue_lengths], 5_000) do
      {:ok,
       %{
         at: DateTime.utc_now(),
         memory: Map.new(memory),
         process_count: pcount,
         port_count: port_count,
         atom_count: atom_count,
         total_mq: total(mqs)
       }}
    end
  end

  defp total(n) when is_integer(n), do: n
  defp total(list) when is_list(list), do: Enum.sum(list)
end
