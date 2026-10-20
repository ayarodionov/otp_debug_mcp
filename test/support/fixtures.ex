# Code that runs on target nodes (see OtpDebugMcp.TestTarget). Processes are
# started unlinked: the peer.call process that starts them exits right away.

defmodule OtpDebugMcp.Fixtures.Ticker do
  @moduledoc "A GenServer that handles a :tick message every `interval` ms."
  use GenServer

  def start(name, interval), do: GenServer.start(__MODULE__, interval, name: name)

  @impl true
  def init(interval) do
    :timer.send_interval(interval, :tick)
    {:ok, 0}
  end

  @impl true
  def handle_info(:tick, n), do: {:noreply, n + 1}
end

defmodule OtpDebugMcp.Fixtures.Mailbox do
  @moduledoc "A registered process that never reads its mailbox, holding `n` messages."

  def start(name, n) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)
    for i <- 1..n, do: send(pid, {:junk, i})
    pid
  end
end

defmodule OtpDebugMcp.Fixtures.Operator do
  @moduledoc """
  An operator's recon_trace session, as someone debugging the node by hand
  would run it, writing to an io server that counts the lines it gets.
  """

  def start(spec) do
    sink = spawn(fn -> sink(0) end)
    Process.register(sink, :operator_sink)

    # recon_trace links its tracer to the caller, so the caller stays alive.
    spawn(fn ->
      :recon_trace.calls(spec, {50, 1000}, io_server: sink)
      Process.sleep(:infinity)
    end)

    wait_for_tracer(50)
  end

  def alive? do
    tracer = Process.whereis(:recon_trace_tracer)
    tracer != nil and Process.alive?(tracer)
  end

  def lines do
    send(:operator_sink, {:count, self()})

    receive do
      {:count, n} -> n
    after
      1_000 -> :no_sink
    end
  end

  defp wait_for_tracer(0), do: {:error, :tracer_not_started}

  defp wait_for_tracer(n) do
    if alive?() do
      :ok
    else
      Process.sleep(20)
      wait_for_tracer(n - 1)
    end
  end

  defp sink(n) do
    receive do
      {:io_request, from, ref, _} ->
        send(from, {:io_reply, ref, :ok})
        sink(n + 1)

      {:count, from} ->
        send(from, {:count, n})
        sink(n)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.Worker do
  @moduledoc "An idle GenServer, used as a supervised child."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}
end

defmodule OtpDebugMcp.Fixtures.App do
  @moduledoc """
  An application with a small nested supervision tree: two workers, and a
  DynamicSupervisor holding `children` workers. Start it on a target with
  `start/1`.
  """
  use Application

  alias OtpDebugMcp.Fixtures.Worker

  def start(children) do
    spec =
      {:application, :fixture_app,
       [
         description: ~c"test fixture",
         vsn: ~c"1.0.0",
         modules: [__MODULE__, Worker],
         registered: [],
         applications: [:kernel, :stdlib, :elixir],
         mod: {__MODULE__, children}
       ]}

    :ok = :application.load(spec)
    :ok = :application.start(:fixture_app)
  end

  @impl true
  def start(_type, children) do
    tree = [
      Supervisor.child_spec({Worker, :a}, id: :worker_a),
      Supervisor.child_spec({Worker, :b}, id: :worker_b),
      {DynamicSupervisor, name: OtpDebugMcp.Fixtures.Pool, strategy: :one_for_one}
    ]

    {:ok, sup} = Supervisor.start_link(tree, strategy: :one_for_one)

    for i <- 1..children//1 do
      {:ok, _} = DynamicSupervisor.start_child(OtpDebugMcp.Fixtures.Pool, {Worker, i})
    end

    {:ok, sup}
  end
end
