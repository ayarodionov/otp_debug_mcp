# An incident that passes before anyone looks. Orders.Ledger handles an
# entry in a millisecond or two, which is plenty for normal traffic. Twenty
# seconds after the node starts, Orders.Import replays a day of entries,
# forty thousand in a few seconds: the ledger's mailbox climbs to about
# that, everything sent to it waits behind them, and over the next minute
# and a half it drains. By the time anyone connects, the node
# looks healthy; only a recording of those minutes shows what happened.

Logger.configure(level: :info)

defmodule Orders.Ledger do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def record(entry), do: GenServer.cast(__MODULE__, {:record, entry})
  def init(n), do: {:ok, n}

  def handle_cast({:record, _entry}, n) do
    Process.sleep(1)
    {:noreply, n + 1}
  end
end

defmodule Orders.Import do
  # A trickle of entries, then the replay, then the trickle again.
  def run do
    Process.register(self(), __MODULE__)
    trickle(20_000)

    for i <- 1..40_000 do
      Orders.Ledger.record({:replayed, i})
      if rem(i, 10) == 0, do: Process.sleep(1)
    end

    trickle(:infinity)
  end

  defp trickle(ms) do
    until = if ms == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + ms
    loop(until)
  end

  defp loop(until) do
    if until == :infinity or System.monotonic_time(:millisecond) < until do
      Orders.Ledger.record(:live)
      Process.sleep(20)
      loop(until)
    end
  end
end

{:ok, sup} =
  Supervisor.start_link([Orders.Ledger, {Task, &Orders.Import.run/0}],
    strategy: :one_for_one,
    name: Orders.Supervisor
  )

# The script's process exits when the script ends, and a supervisor exits
# with its parent: it must not stay linked to it.
Process.unlink(sup)
