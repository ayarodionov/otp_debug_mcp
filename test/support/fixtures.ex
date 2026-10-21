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

defmodule OtpDebugMcp.Fixtures.Crasher do
  @moduledoc "A GenServer that raises `ms` milliseconds after it starts, or never if nil."
  use GenServer

  def start_link(ms), do: GenServer.start_link(__MODULE__, ms)

  @impl true
  def init(nil), do: {:ok, nil}

  def init(ms) do
    Process.send_after(self(), :crash, ms)
    {:ok, ms}
  end

  @impl true
  def handle_info(:crash, _ms), do: raise(ArgumentError, "crash loop fixture")
end

defmodule OtpDebugMcp.Fixtures.CrashSup do
  @moduledoc """
  A registered supervisor of Crashers, given as `[{id, ms}]`, started under
  a holder process so it outlives the peer.call that starts it. The
  target's logging is turned off, since crash reports would flood the test
  output.
  """
  alias OtpDebugMcp.Fixtures.Crasher

  def start(name, children, opts) do
    :logger.set_primary_config(:level, :none)
    caller = self()

    spawn(fn ->
      specs = for {id, ms} <- children, do: Supervisor.child_spec({Crasher, ms}, id: id)
      {:ok, _} = Supervisor.start_link(specs, [name: name, strategy: :one_for_one] ++ opts)
      send(caller, :started)
      Process.sleep(:infinity)
    end)

    receive do
      :started -> :ok
    after
      5_000 -> {:error, :not_started}
    end
  end

  @doc "Kill the child `id` of supervisor `name` and wait until it's restarted."
  def kill_child(name, id) do
    old = child_pid(name, id)
    Process.exit(old, :kill)
    wait_for_new_child(name, id, old, 100)
  end

  defp child_pid(name, id) do
    Enum.find_value(Supervisor.which_children(name), fn
      {^id, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp wait_for_new_child(_name, _id, _old, 0), do: {:error, :not_restarted}

  defp wait_for_new_child(name, id, old, n) do
    case child_pid(name, id) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_new_child(name, id, old, n - 1)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.Spawner do
  @moduledoc "Keeps a node busy spawning a short-lived process every `interval` ms."

  def start(interval), do: spawn(fn -> loop(interval) end)

  defp loop(interval) do
    spawn(fn -> :ok end)
    Process.sleep(interval)
    loop(interval)
  end
end

defmodule OtpDebugMcp.Fixtures.Fragmenter do
  @moduledoc """
  Fragments binary_alloc: allocates `mb` megabytes of 64 KB binaries, then
  frees all but one in `keep_every`, which a registered process holds. Most
  carriers stay allocated around a few live blocks.
  """

  def start(mb, keep_every) do
    holder = spawn(fn -> receive do: ({:keep, bins} -> hold(bins)) end)
    Process.register(holder, :fragmenter)
    caller = self()

    spawn(fn ->
      bins = for i <- 1..(mb * 16), do: :binary.copy(<<rem(i, 256)>>, 65_536)
      send(holder, {:keep, Enum.take_every(bins, keep_every)})
      send(caller, :done)
    end)

    receive do
      :done -> :ok
    after
      30_000 -> {:error, :timeout}
    end
  end

  # Keeps the binaries referenced, forever.
  defp hold(bins) do
    receive do
      :never -> hold(bins)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.Hog do
  @moduledoc "A registered process holding a binary of `mb` megabytes."

  def start(name, mb) do
    caller = self()

    pid =
      spawn(fn ->
        bin = :binary.copy(<<0>>, mb * 1_048_576)
        send(caller, :allocated)
        hold(bin)
      end)

    Process.register(pid, name)

    receive do
      :allocated -> :ok
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp hold(bin) do
    receive do
      :never -> hold(bin)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.AtomLeak do
  @moduledoc "Creates an atom about every `ms` milliseconds, forever."

  def start(ms), do: spawn(fn -> loop(0, ms) end)

  defp loop(n, ms) do
    _ = :erlang.list_to_atom(~c"leaked_atom_" ++ Integer.to_charlist(n))
    Process.sleep(ms)
    loop(n + 1, ms)
  end
end

defmodule OtpDebugMcp.Fixtures.ProcLeak do
  @moduledoc "Spawns a worker every `ms` milliseconds that waits forever."

  def start(ms), do: spawn(fn -> loop(ms) end)

  defp loop(ms) do
    spawn(fn -> wait_forever() end)
    Process.sleep(ms)
    loop(ms)
  end

  defp wait_forever do
    receive do
      :never -> :ok
    end
  end
end

defmodule OtpDebugMcp.Fixtures.SliceKeeper do
  @moduledoc """
  A registered GenServer keeping, of each of `n` 16 KB binaries, either a
  256-byte slice (`:slices`, each pinning its whole binary) or the binary
  itself (`:whole`).
  """
  use GenServer

  def start(name, n, mode), do: GenServer.start(__MODULE__, {n, mode}, name: name) |> ok()

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other

  @impl true
  def init({n, mode}) do
    kept =
      for i <- 1..n do
        record = :binary.copy(<<i::32>>, 4096)

        case mode do
          :slices ->
            <<slice::binary-size(256), _::binary>> = record
            slice

          :whole ->
            record
        end
      end

    {:ok, kept}
  end
end
