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

defmodule OtpDebugMcp.Fixtures.DyingApp do
  @moduledoc """
  A permanent application whose only child crashes `ms` after it starts,
  until its supervisor gives up (after one restart): the application
  stops, and so the node, writing a crash dump. Its logging is turned off.
  """
  use Application

  alias OtpDebugMcp.Fixtures.Crasher

  def start(ms) do
    spec =
      {:application, :dying_app,
       [
         description: ~c"test fixture",
         vsn: ~c"1.0.0",
         modules: [__MODULE__, Crasher],
         registered: [],
         applications: [:kernel, :stdlib, :elixir],
         mod: {__MODULE__, ms}
       ]}

    :logger.set_primary_config(:level, :none)
    :ok = :application.load(spec)
    :ok = :application.start(:dying_app, :permanent)
  end

  @impl true
  def start(_type, ms),
    do: Supervisor.start_link([{Crasher, ms}], strategy: :one_for_one, max_restarts: 1)
end

defmodule OtpDebugMcp.Fixtures.Caller do
  @moduledoc """
  GenServers that call each other, for deadlocks, chains of calls and
  bottlenecks. A `{:via, servers}` call makes each server call the next
  while handling it; the last one waits forever.
  """
  use GenServer

  def start(name), do: GenServer.start(__MODULE__, nil, name: name)

  @doc "A process of its own that makes `request` to `server`, and waits."
  def call_later(server, request) do
    spawn(fn -> GenServer.call(server, request, :infinity) end)
    :ok
  end

  @doc """
  Processes of their own that call `server` each other way a call is made,
  and wait: gen_server:call/2 (its default timeout), gen_statem:call/3 with
  infinity, and a task's call awaited by another process.
  """
  def call_each_way(server) do
    spawn(fn -> :gen_server.call(server, {:form, 2}) end)
    spawn(fn -> :gen_statem.call(server, {:statem, 3}, :infinity) end)

    spawn(fn ->
      Task.async(fn -> GenServer.call(server, :in_task, :infinity) end) |> Task.await(:infinity)
    end)

    :ok
  end

  @doc "Make `server` call `target` while handling a cast: a call from its callbacks."
  def make_call(server, target, request), do: GenServer.cast(server, {:call, target, request})

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:via, [next | rest]}, _from, state),
    do: {:reply, GenServer.call(next, {:via, rest}, :infinity), state}

  def handle_call({:via, []}, _from, state) do
    Process.sleep(:infinity)
    {:reply, :ok, state}
  end

  # Any other request waits for a reply that never comes.
  def handle_call(_request, _from, state), do: {:noreply, state}

  @impl true
  def handle_cast({:call, target, request}, state) do
    GenServer.call(target, request, :infinity)
    {:noreply, state}
  end

  def handle_cast({:call, target, request, timeout}, state) do
    GenServer.call(target, request, timeout)
    {:noreply, state}
  end
end

defmodule OtpDebugMcp.Fixtures.Parser do
  @moduledoc """
  A registered process that parses a quantity every `ms` milliseconds,
  catching what fails: one input in four isn't a number, and raises.
  """

  @inputs ["3", "1", "n/a", "2"]

  def start(name, ms) do
    Process.register(spawn(fn -> loop(ms, 0) end), name)
    :ok
  end

  def quantity(text), do: String.to_integer(text)

  defp loop(ms, i) do
    try do
      quantity(Enum.at(@inputs, rem(i, 4)))
    rescue
      ArgumentError -> :error
    end

    Process.sleep(ms)
    loop(ms, i + 1)
  end
end

defmodule OtpDebugMcp.Fixtures.Emitter do
  @moduledoc """
  Emits telemetry events every `ms` milliseconds, as Phoenix and Ecto do:
  a request to one of two routes, the second one slow, with the query it
  runs, and every fourth request an exception. The conns carry a big
  assign, which the tool must not copy. A handler stands in for Phoenix's
  logger's.
  """

  def start(ms) do
    events = [[:phoenix, :router_dispatch, :stop], [:phoenix, :router_dispatch, :exception]]
    :ok = :telemetry.attach_many("fixture-logger", events, &__MODULE__.log/4, nil)

    spawn(fn -> loop(ms, 0) end)
    :ok
  end

  def log(_event, _measurements, _metadata, _config), do: :ok

  @doc "A metrics handler that needs a :source in the metadata, as many do."
  def metrics(_event, _measurements, %{source: _}, _config), do: :ok

  defp loop(ms, i) do
    {route, path, action, took} =
      if rem(i, 2) == 0,
        do: {"/products/:id", "/products/#{i}", :show, 2},
        else: {"/search", "/search", :search, 40}

    conn = %{
      __struct__: Plug.Conn,
      method: "GET",
      request_path: path,
      status: 200,
      host: "localhost",
      assigns: %{page: String.duplicate("x", 100_000)}
    }

    :telemetry.execute(
      [:shop, :repo, :query],
      %{total_time: native(took - 1), queue_time: native(1), query_time: native(took - 2)},
      %{
        source: "products",
        query: "SELECT p0.id FROM products AS p0 WHERE (p0.id = $1)",
        params: [i],
        result: {:ok, %{rows: [[i]]}},
        repo: OtpDebugMcp.Fixtures.FakeRepo
      }
    )

    meta = %{route: route, conn: conn, plug: ShopWeb.ProductController, plug_opts: action}

    if rem(i, 4) == 3 do
      :telemetry.execute(
        [:phoenix, :router_dispatch, :exception],
        %{duration: native(took)},
        Map.merge(meta, %{kind: :error, reason: %ArgumentError{message: "bad id"}, stacktrace: []})
      )
    else
      :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: native(took)}, meta)
    end

    Process.sleep(ms)
    loop(ms, i + 1)
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end

defmodule OtpDebugMcp.Fixtures.FakeRepo do
  @moduledoc "Looks like an Ecto repo to discovery: __adapter__/0 and config/0."
  def __adapter__, do: :fake
  def config, do: [telemetry_prefix: [:shop, :repo]]
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

defmodule OtpDebugMcp.Fixtures.Busy do
  @moduledoc """
  A registered process that keeps calling known functions, for profiling:
  `crunch/1` does most of the work and allocates (through Enum, which isn't
  in this module), `light/1` does almost nothing.
  """

  def start(name, n) do
    pid = spawn(fn -> loop(n) end)
    Process.register(pid, name)
    :ok
  end

  def loop(n) do
    step(n)

    receive do
      :stop -> :ok
    after
      1 -> loop(n)
    end
  end

  def step(n), do: {crunch(n), light(n)}

  def crunch(n), do: Enum.sum(Enum.map(1..n, &(&1 * &1)))

  def light(n), do: n + 1
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

defmodule OtpDebugMcp.Fixtures.Fussy do
  @moduledoc """
  A registered plain process, not an OTP behaviour, holding `mb` megabytes
  of binaries and crashing on any message it doesn't expect, as some
  processes do (recon's trace processes, for one).
  """

  def start(name, mb) do
    caller = self()

    pid =
      spawn(fn ->
        kept = for i <- 1..(mb * 64), do: :binary.copy(<<i::32>>, 4096)
        send(caller, :ready)
        loop(kept)
      end)

    Process.register(pid, name)

    receive do
      :ready -> :ok
    after
      30_000 -> {:error, :timeout}
    end
  end

  defp loop(kept) do
    receive do
      :expected -> loop(kept)
      other -> exit({:unexpected_message, other})
    end
  end
end

defmodule OtpDebugMcp.Fixtures.EtsOwner do
  @moduledoc """
  A registered process that owns three tables: otpdbg_set, a named public
  set of 2,000 small rows and one large one (:big, a list of 20,000
  integers); otpdbg_bag, an unnamed bag whose key :hot has 30 rows; and
  otpdbg_private, a named private table.
  """

  def start(name) do
    parent = self()

    pid =
      spawn(fn ->
        set = :ets.new(:otpdbg_set, [:named_table, :public, :set])
        for i <- 1..2_000, do: :ets.insert(set, {i, "row #{i}"})
        :ets.insert(set, {:big, Enum.to_list(1..20_000)})

        bag = :ets.new(:otpdbg_bag, [:bag, :public])
        for i <- 1..30, do: :ets.insert(bag, {:hot, i})
        for i <- 1..5, do: :ets.insert(bag, {i, i})

        :ets.new(:otpdbg_private, [:named_table, :private])
        send(parent, :ready)

        receive do
          :stop -> :ok
        end
      end)

    Process.register(pid, name)

    receive do
      :ready -> :ok
    end
  end
end

defmodule OtpDebugMcp.Fixtures.OldLoop do
  @moduledoc """
  A registered process whose receive loop calls itself locally, as plain
  receive loops do: loading the module again leaves it in the old code.
  """

  def start(name) do
    Process.register(spawn(fn -> loop() end), name)
    :ok
  end

  defp loop do
    receive do
      :stop -> :ok
    after
      100 -> loop()
    end
  end
end

defmodule OtpDebugMcp.Fixtures.WebShop do
  @moduledoc """
  A plug served by Bandit: / answers at once, /slow after `slow_ms`, /boom
  raises. `start/2` starts the server under a process of its own, with
  the given Thousand Island options, and returns its port; `clients/2`
  starts processes that each keep requesting `path` on their own
  connection.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/slow"} = conn, _opts) do
    Process.sleep(:persistent_term.get({__MODULE__, :slow_ms}, 2_000))
    Plug.Conn.send_resp(conn, 200, "slow")
  end

  def call(%{request_path: "/boom"}, _opts), do: raise("boom")
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")

  def start(thousand_island_options, slow_ms) do
    :persistent_term.put({__MODULE__, :slow_ms}, slow_ms)
    parent = self()

    spawn(fn ->
      {:ok, server} =
        Bandit.start_link(
          plug: __MODULE__,
          port: 0,
          ip: :loopback,
          startup_log: false,
          thousand_island_options: thousand_island_options
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      send(parent, {:port, port})
      Process.sleep(:infinity)
    end)

    receive do
      {:port, port} -> port
    end
  end

  def clients(port, n, path) do
    for _ <- 1..n do
      spawn(fn -> client(port, path) end)
    end

    :ok
  end

  # One connection, a request after another on it; a new connection when
  # it's closed (refused, or timed out).
  defp client(port, path) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000) do
      {:ok, socket} -> requests(socket, path)
      _ -> :ok
    end

    Process.sleep(50)
    client(port, path)
  end

  defp requests(socket, path) do
    with :ok <- :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: shop\r\n\r\n"),
         {:ok, _} <- :gen_tcp.recv(socket, 0, 10_000) do
      requests(socket, path)
    else
      _ -> :gen_tcp.close(socket)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.RiakShop do
  @moduledoc """
  A riak_core vnode keeping a map, served as the riak_shop service: put/2
  and get/1 go to the key's partition (a fallback when its owner is
  unreachable), slow/2 queues commands that each take `ms` on one key's
  vnode, without waiting for them.
  """
  @behaviour :riak_core_vnode

  def start do
    parent = self()

    spawn(fn ->
      {:ok, _} = :riak_core_vnode_master.start_link(__MODULE__)
      # Under an application that runs: riak_core waits for the one a
      # vnode module is registered under before handing its vnodes off.
      :ok = :riak_core.register(:riak_core, vnode_module: __MODULE__)
      :ok = :riak_core_node_watcher.service_up(:riak_shop, self())
      send(parent, :ready)
      Process.sleep(:infinity)
    end)

    receive do
      :ready -> :ok
    end
  end

  def put(key, value), do: sync(key, {:put, key, value})
  def get(key), do: sync(key, {:get, key})

  def slow(key, n, ms) do
    for _ <- 1..n, do: :riak_core_vnode_master.command(index_node(key), {:sleep, ms}, master())
    :ok
  end

  # {:error, :timeout} after 2 s: a request routed to a member just gone.
  defp sync(key, command) do
    :riak_core_vnode_master.sync_command(index_node(key), command, master(), 2_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp index_node(key) do
    index = :riak_core_util.chash_key({"shop", :erlang.term_to_binary(key)})
    [index_node] = :riak_core_apl.get_apl(index, 1, :riak_shop)
    index_node
  end

  defp master, do: :riak_core_vnode_master.reg_name(__MODULE__)

  def start_vnode(index), do: :riak_core_vnode_master.get_vnode_pid(index, __MODULE__)

  @impl true
  def init([partition]), do: {:ok, %{partition: partition, data: %{}}}

  @impl true
  def handle_command({:put, k, v}, _sender, s), do: {:reply, :ok, put_in(s.data[k], v)}
  def handle_command({:get, k}, _sender, s), do: {:reply, Map.fetch(s.data, k), s}

  def handle_command({:sleep, ms}, _sender, s) do
    Process.sleep(ms)
    {:noreply, s}
  end

  @impl true
  def handle_handoff_command(_request, _sender, s), do: {:noreply, s}
  @impl true
  def handoff_starting(_target, s), do: {true, s}
  @impl true
  def handoff_cancelled(s), do: {:ok, s}
  @impl true
  def handoff_finished(_target, s), do: {:ok, s}

  @impl true
  def handle_handoff_data(bin, s) do
    {k, v} = :erlang.binary_to_term(bin)
    {:reply, :ok, put_in(s.data[k], v)}
  end

  @impl true
  def encode_handoff_item(k, v), do: :erlang.term_to_binary({k, v})
  @impl true
  def is_empty(s), do: {map_size(s.data) == 0, s}
  @impl true
  def delete(s), do: {:ok, %{s | data: %{}}}
  @impl true
  def handle_coverage(_request, _keyspaces, _sender, s), do: {:stop, :not_implemented, s}
  @impl true
  def handle_exit(_pid, _reason, s), do: {:noreply, s}
  @impl true
  def terminate(_reason, _s), do: :ok
  @impl true
  def handle_overload_command(_request, _sender, _index), do: :ok
  @impl true
  def handle_overload_info(_request, _index), do: :ok
end

defmodule OtpDebugMcp.Fixtures.CowboyShop do
  @moduledoc """
  A Cowboy server with cowboy_telemetry: `/` answers at once, `/slow`
  after `slow_ms`, `/boom` raises. `start/2` takes Ranch's transport
  options and returns the port; `clients/3` keeps clients requesting a
  path, each on a keep-alive connection.
  """
  @behaviour :cowboy_handler

  def start(transport_options, slow_ms) do
    dispatch = :cowboy_router.compile([{:_, [{"/[...]", __MODULE__, %{slow_ms: slow_ms}}]}])

    {:ok, _} =
      :cowboy.start_clear(
        :cowboy_shop,
        Map.merge(%{socket_opts: [ip: {127, 0, 0, 1}, port: 0]}, Map.new(transport_options)),
        %{
          env: %{dispatch: dispatch},
          stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]
        }
      )

    :ranch.get_port(:cowboy_shop)
  end

  @impl true
  def init(req, %{slow_ms: ms} = state) do
    case :cowboy_req.path(req) do
      "/slow" -> Process.sleep(ms)
      "/boom" -> raise "boom"
      _ -> :ok
    end

    {:ok, :cowboy_req.reply(200, %{}, "ok", req), state}
  end

  def clients(port, n, path), do: OtpDebugMcp.Fixtures.HttpClients.start(port, n, path)
end

defmodule OtpDebugMcp.Fixtures.HttpClients do
  @moduledoc """
  `start/3` keeps `n` clients requesting a path, each on a keep-alive
  connection, paced, and on a new connection when the server closes
  theirs (Cowboy, after max_keepalive requests, answers connection: close
  and reads no more). They send no cookies.
  """

  def start(port, n, path) do
    for _ <- 1..n, do: spawn(fn -> client(port, path) end)
    :ok
  end

  defp client(port, path) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000) do
      {:ok, socket} -> requests(socket, path)
      _ -> :ok
    end

    Process.sleep(50)
    client(port, path)
  end

  defp requests(socket, path) do
    with :ok <- :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: shop\r\n\r\n"),
         {:ok, answer} <- :gen_tcp.recv(socket, 0, 10_000),
         false <- answer |> String.downcase() |> String.contains?("connection: close") do
      Process.sleep(10)
      requests(socket, path)
    else
      _ -> :gen_tcp.close(socket)
    end
  end
end

defmodule OtpDebugMcp.Fixtures.YawsShop do
  @moduledoc """
  Yaws, embedded, serving this appmod: `/` answers at once, `/slow` after
  `slow_ms`, `/boom` raises, `/session` starts a new cookie session on
  every request. `start/2` takes global options (max_connections...) and
  returns the port; `clients/3` keeps clients requesting a path.
  """

  def start(gconf, slow_ms) do
    :persistent_term.put({__MODULE__, :slow_ms}, slow_ms)
    dir = Path.join(System.tmp_dir!(), "otpdbg_yaws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    :ok =
      :yaws.start_embedded(
        String.to_charlist(dir),
        [port: 0, listen: {127, 0, 0, 1}, servername: ~c"shop", appmods: [{~c"/", __MODULE__}]],
        [logdir: String.to_charlist(dir), id: ~c"shop"] ++ gconf,
        ~c"shop"
      )

    {:ok, _gc, [[sc | _] | _]} = :yaws_api.getconf()
    :yaws_server.listen_port(sc)
  end

  def out(arg) do
    case :yaws_api.arg_server_path(arg) do
      ~c"/slow" ->
        Process.sleep(:persistent_term.get({__MODULE__, :slow_ms}))
        {:html, "ok"}

      ~c"/boom" ->
        raise "boom"

      ~c"/session" ->
        cookie = :yaws_api.new_cookie_session(%{cart: []})
        [{:html, "ok"}, :yaws_api.set_cookie(~c"shop", cookie, [])]

      _ ->
        {:html, "ok"}
    end
  end

  def clients(port, n, path), do: OtpDebugMcp.Fixtures.HttpClients.start(port, n, path)
end

defmodule OtpDebugMcp.Fixtures.ShackleShop do
  @moduledoc """
  A shackle pool, :shop_pool, of this client, to a backend in the same
  node: a line protocol (`Id Command`, answered `Id ok`), each
  connection's requests handled one at a time, `slow` taking `slow_ms`.
  `start/2` takes the pool options and slow_ms; `lookups/2` and `slow/1`
  keep callers busy; `backend_down/0` closes the backend.
  """
  @behaviour :shackle_client

  def start(pool_options, slow_ms) do
    parent = self()

    spawn(fn ->
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      :persistent_term.put({__MODULE__, :listen}, listen)
      send(parent, {:port, port})
      accept(listen, slow_ms)
    end)

    port =
      receive do
        {:port, port} -> port
      end

    :ok =
      :shackle_pool.start(
        :shop_pool,
        __MODULE__,
        [port: port, reconnect_time_min: 200, socket_options: [:binary]],
        pool_options
      )

    Process.sleep(300)
    port
  end

  def backend_down do
    :gen_tcp.close(:persistent_term.get({__MODULE__, :listen}))
    for pid <- :persistent_term.get({__MODULE__, :conns}, []), do: Process.exit(pid, :kill)
    :ok
  end

  defp accept(listen, slow_ms) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        # It reads only once the socket is its own.
        pid =
          spawn(fn ->
            receive do
              :go -> serve(socket, slow_ms)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)

        :persistent_term.put({__MODULE__, :conns}, [
          pid | :persistent_term.get({__MODULE__, :conns}, [])
        ])

        accept(listen, slow_ms)

      _ ->
        :ok
    end
  end

  # One request at a time on a connection, as many backends do.
  defp serve(socket, slow_ms) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        [id, command] = line |> String.trim() |> String.split(" ")
        if command == "slow", do: Process.sleep(slow_ms)
        :ok = :gen_tcp.send(socket, "#{id} ok\n")
        serve(socket, slow_ms)

      _ ->
        :ok
    end
  end

  def lookups(n, timeout) do
    for _ <- 1..n, do: spawn(fn -> lookup(timeout) end)
    :ok
  end

  defp lookup(timeout) do
    :shackle.call(:shop_pool, :get, timeout)
    Process.sleep(10)
    lookup(timeout)
  end

  def slow(n) do
    for _ <- 1..n, do: spawn(fn -> slow_call() end)
    :ok
  end

  defp slow_call do
    :shackle.call(:shop_pool, :slow, 60_000)
    slow_call()
  end

  @impl true
  def init(_), do: {:ok, %{next: 0, buffer: ""}}

  @impl true
  def setup(_socket, state), do: {:ok, state}

  @impl true
  def handle_request(command, %{next: id} = state),
    do: {:ok, id, "#{id} #{command}\n", %{state | next: id + 1}}

  @impl true
  def handle_data(data, %{buffer: buffer} = state) do
    lines = String.split(buffer <> data, "\n")
    {complete, [rest]} = Enum.split(lines, -1)

    replies =
      for line <- complete, line != "" do
        [id, reply] = String.split(line, " ")
        {String.to_integer(id), reply}
      end

    {:ok, replies, %{state | buffer: rest}}
  end

  @impl true
  def terminate(_state), do: :ok
end

defmodule OtpDebugMcp.Fixtures.TelemetryShop do
  @moduledoc """
  Telemetry handlers of every kind on a shop's [:shop, :order, :stop]
  events: `attach/1` a cheap counter (:counter, and :counter_again, the
  same function under another id), one that calls a slow reporter
  (:slow), one that raises on orders without a coupon (:fragile), one
  whose module doesn't exist (:missing), an anonymous fun (:local).
  `orders/2` keeps processes emitting orders; with `leak: true`, each
  order also attaches a handler of its own, never detached.
  """
  use GenServer

  def start do
    {:ok, _} = GenServer.start(__MODULE__, nil, name: __MODULE__)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(:shop_orders, [:named_table, :public])
    :ets.insert(:shop_orders, {:count, 0})
    {:ok, nil}
  end

  # The reporter: 5 ms a report, one at a time.
  @impl true
  def handle_call(:report, _from, state) do
    Process.sleep(5)
    {:reply, :ok, state}
  end

  @order [:shop, :order, :stop]

  def attach(:counter), do: :telemetry.attach(:counter, @order, &__MODULE__.count/4, nil)

  def attach(:counter_again),
    do: :telemetry.attach({:counter, :again}, @order, &__MODULE__.count/4, nil)

  def attach(:slow), do: :telemetry.attach(:reporter, @order, &__MODULE__.report/4, nil)
  def attach(:fragile), do: :telemetry.attach(:audit, @order, &__MODULE__.audit/4, nil)

  # Made at run time: the compiler would rightly warn about it.
  def attach(:missing) do
    handler = Function.capture(:otpdbg_no_such_module, :handle, 4)
    :telemetry.attach(:refunds, [:shop, :refund], handler, nil)
  end

  def attach(:local), do: :telemetry.attach(:inline, @order, fn _, _, _, _ -> :ok end, nil)

  def attach({:many, n}) do
    for i <- 1..n, do: :ok = :telemetry.attach({:many, i}, @order, &__MODULE__.count/4, nil)
    :ok
  end

  def count(_event, _measurements, _metadata, _config),
    do: :ets.update_counter(:shop_orders, :count, 1)

  def report(_event, _measurements, _metadata, _config), do: GenServer.call(__MODULE__, :report)

  def audit(_event, _measurements, %{coupon: coupon}, _config),
    do: :ets.insert(:shop_orders, {:last_coupon, String.upcase(coupon)})

  def orders(n, opts \\ []) do
    for i <- 1..n, do: spawn(fn -> order(i, opts) end)
    :ok
  end

  defp order(i, opts) do
    if opts[:leak],
      do:
        :telemetry.attach(
          {:request, make_ref()},
          [:shop, :order, :start],
          &__MODULE__.count/4,
          nil
        )

    coupon = if rem(i, 2) == 0, do: "spring", else: nil
    :telemetry.execute(@order, %{duration: 1}, %{coupon: coupon})
    Process.sleep(Keyword.get(opts, :every, 5))
    order(i, opts)
  end
end

defmodule OtpDebugMcp.Fixtures.MnesiaShop do
  @moduledoc """
  Mnesia, in RAM, with a shop's tables: :stock, one row counting what's
  sold, and :orders. `orders/2` keeps processes placing orders, each a
  transaction that reads the stock row for a write lock, does `slow_ms`
  of work holding it, and writes. `join/1` adds another node's Mnesia;
  `remote_table/2` creates a table with its only copy there.
  """

  # Mnesia is OTP's, but not one of this project's applications.
  @compile {:no_warn_undefined, [:mnesia, :mnesia_lib]}

  def start(dir) do
    :ok = :application.set_env(:mnesia, :dir, String.to_charlist(dir))
    :ok = :mnesia.start()
    {:atomic, :ok} = :mnesia.create_table(:stock, attributes: [:item, :sold])
    {:atomic, :ok} = :mnesia.create_table(:orders, attributes: [:id, :item])
    :ok = :mnesia.dirty_write({:stock, :total, 0})
    :ok
  end

  def start_bare(dir) do
    :ok = :application.set_env(:mnesia, :dir, String.to_charlist(dir))
    :mnesia.start()
  end

  def join(node) do
    {:ok, [^node]} = :mnesia.change_config(:extra_db_nodes, [node])
    :ok
  end

  def remote_table(table, node) do
    {:atomic, :ok} = :mnesia.create_table(table, ram_copies: [node], attributes: [:k, :v])
    :ok
  end

  def orders(n, slow_ms) do
    for _ <- 1..n, do: spawn(fn -> order(slow_ms) end)
    :ok
  end

  defp order(slow_ms) do
    :mnesia.transaction(fn -> place(slow_ms) end)
    order(slow_ms)
  end

  def place(slow_ms) do
    [{:stock, :total, sold}] = :mnesia.read(:stock, :total, :write)
    # The slow part: done while holding the stock row's write lock.
    if slow_ms > 0, do: Process.sleep(slow_ms)
    :mnesia.write({:stock, :total, sold + 1})
    :mnesia.write({:orders, make_ref(), :kettle})
  end

  def overload,
    do: :mnesia_lib.report_system_event({:mnesia_overload, {:dump_log, :write_threshold}})
end

defmodule OtpDebugMcp.Fixtures.PgShop do
  @moduledoc """
  A Postgrex pool, :shop_db, and a stock table with one row. `writers/2`
  keep processes in transactions that update the row and hold their
  connection `hold_ms` before committing; `readers/1` keep processes
  reading it.
  """

  def start(opts, pool_size) do
    parent = self()

    spawn(fn ->
      {:ok, _} = Postgrex.start_link(opts ++ [name: :shop_db, pool_size: pool_size])
      send(parent, :started)
      Process.sleep(:infinity)
    end)

    receive do
      :started -> :ok
    end

    Postgrex.query!(
      :shop_db,
      "CREATE TABLE IF NOT EXISTS stock (item int PRIMARY KEY, n int)",
      []
    )

    Postgrex.query!(:shop_db, "INSERT INTO stock VALUES (1, 1000000) ON CONFLICT DO NOTHING", [])
    :ok
  end

  def writers(n, hold_ms) do
    for _ <- 1..n, do: spawn(fn -> write(hold_ms) end)
    :ok
  end

  defp write(hold_ms) do
    try do
      Postgrex.transaction(:shop_db, fn conn -> sell(conn, hold_ms) end)
    rescue
      _ -> :error
    end

    write(hold_ms)
  end

  def sell(conn, hold_ms) do
    Postgrex.query!(conn, "UPDATE stock SET n = n - 1 WHERE item = 1", [])
    # Slow work, holding the connection and the row's lock.
    Process.sleep(hold_ms)
    :ok
  end

  def readers(n) do
    for _ <- 1..n, do: spawn(fn -> read() end)
    :ok
  end

  defp read do
    try do
      Postgrex.query(:shop_db, "SELECT n FROM stock WHERE item = 1", [])
    rescue
      _ -> :error
    end

    Process.sleep(10)
    read()
  end
end
