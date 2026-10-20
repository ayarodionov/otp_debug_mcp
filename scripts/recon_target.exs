# A target that already has recon (start it with recon on the code path:
# `elixir --sname rt -pa _build/prod/lib/recon/ebin ...`), where an operator
# has a long-running recon_trace session open. A watcher appends a line per
# second to $STATUS_FILE saying whether that session is still alive, so a
# test can check the debugger never disturbs it.
#
# With FAKE_OLD_RECON=1 the target instead gets a stand-in for an old recon
# release that only has recon:proc_count/2.
status_file = System.fetch_env!("STATUS_FILE")

defmodule Ticker do
  use GenServer
  def start_link(name), do: GenServer.start_link(__MODULE__, 0, name: name)
  def init(n), do: (:timer.send_interval(100, :tick); {:ok, n})
  def handle_info(:tick, n), do: {:noreply, n + 1}
end

defmodule Sink do
  # A long-lived io server that counts the lines written to it.
  def start, do: spawn(fn -> loop(0) end)

  defp loop(n) do
    receive do
      {:io_request, from, ref, _} -> send(from, {:io_reply, ref, :ok}); loop(n + 1)
      {:count, from} -> send(from, {:count, n}); loop(n)
    end
  end
end

if System.get_env("FAKE_OLD_RECON") == "1" do
  defmodule :recon do
    def proc_count(_attr, _n), do: []
  end

  Process.sleep(:infinity)
end

# As in a release that depends on recon, the application is loaded.
:ok = Application.load(:recon)

{:ok, _} = Ticker.start_link(TickerA)
sink = Sink.start()
me = self()

# The operator's trace: up to 50 calls/s on TickerA (which ticks 10/s).
# recon_trace links its tracer to the caller, so the caller stays alive.
spawn(fn ->
  :recon_trace.calls({Ticker, :handle_info, :_}, {50, 1000}, io_server: sink, pid: Process.whereis(TickerA))
  send(me, :recon_started)
  Process.sleep(:infinity)
end)

receive do: (:recon_started -> :ok)

spawn(fn ->
  Stream.repeatedly(fn ->
    tracer = Process.whereis(:recon_trace_tracer)
    send(sink, {:count, self()})
    lines = receive do: ({:count, n} -> n)
    alive = if tracer && Process.alive?(tracer), do: "alive", else: "DEAD"
    File.write!(status_file, "operator_trace=#{alive} lines=#{lines}\n", [:append])
    Process.sleep(1000)
  end)
  |> Stream.run()
end)
