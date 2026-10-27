defmodule OtpDebugMcp.TestTarget do
  @moduledoc """
  Disposable target nodes for tests, started with `:peer`.

  The peer is controlled over its standard io, not over distribution, so
  the test node isn't connected to it in advance: `OtpDebugMcp.Target`
  connects as a hidden node exactly as it does against a real system.
  Each peer gets its own cookie, and the fixture modules in
  `OtpDebugMcp.Fixtures` are loaded into it. recon is on its code path
  only with `recon: true`.
  """

  @fixtures [
    OtpDebugMcp.Fixtures.Ticker,
    OtpDebugMcp.Fixtures.Busy,
    OtpDebugMcp.Fixtures.Mailbox,
    OtpDebugMcp.Fixtures.Operator,
    OtpDebugMcp.Fixtures.App,
    OtpDebugMcp.Fixtures.Worker,
    OtpDebugMcp.Fixtures.Crasher,
    OtpDebugMcp.Fixtures.CrashSup,
    OtpDebugMcp.Fixtures.DyingApp,
    OtpDebugMcp.Fixtures.Caller,
    OtpDebugMcp.Fixtures.Parser,
    OtpDebugMcp.Fixtures.Emitter,
    OtpDebugMcp.Fixtures.FakeRepo,
    OtpDebugMcp.Fixtures.Spawner,
    OtpDebugMcp.Fixtures.Fragmenter,
    OtpDebugMcp.Fixtures.Hog,
    OtpDebugMcp.Fixtures.AtomLeak,
    OtpDebugMcp.Fixtures.ProcLeak,
    OtpDebugMcp.Fixtures.SliceKeeper,
    OtpDebugMcp.Fixtures.Fussy,
    OtpDebugMcp.Fixtures.EtsOwner,
    OtpDebugMcp.Fixtures.OldLoop,
    OtpDebugMcp.Fixtures.WebShop,
    OtpDebugMcp.Fixtures.RiakShop
  ]

  defstruct [:peer, :node, :cookie, :name, :opts]

  # Bandit and what it runs on, for `bandit: true`.
  @bandit_apps [
    :bandit,
    :thousand_island,
    :plug,
    :plug_crypto,
    :mime,
    :websock,
    :hpax,
    :telemetry,
    :eex
  ]

  @doc """
  Start a target node. Options: `:name`, `:cookie`, `longnames: true` (as
  `name@127.0.0.1`), `:env` (environment variables, as `{name, value}`),
  `telemetry: true` (the telemetry application started), `bandit: true`
  (Bandit and what it needs started), `riak: true` (riak_core started, alone), `recon: true`
  (recon application loaded, as in a
  release that depends on it), `:args` (more VM flags, as charlists),
  `erlang: true` (the Elixir application isn't started, so the node looks
  like a plain Erlang node; fixtures still load, but only those that need
  no running Elixir work there).
  """
  def start(opts \\ []) do
    name =
      Keyword.get_lazy(opts, :name, fn -> :"target_#{System.unique_integer([:positive])}" end)

    cookie =
      Keyword.get_lazy(opts, :cookie, fn -> "cookie_#{System.unique_integer([:positive])}" end)

    paths =
      elixir_paths() ++
        [fixtures_dir()] ++
        if(opts[:recon], do: [lib_ebin(:recon)], else: []) ++
        if(opts[:telemetry], do: [lib_ebin(:telemetry)], else: []) ++
        if(opts[:bandit], do: Enum.map(@bandit_apps, &lib_ebin/1), else: []) ++
        if(opts[:riak], do: Enum.map([:riak_core, :poolboy, :riak_dt], &lib_ebin/1), else: [])

    peer_opts = %{
      name: name,
      connection: :standard_io,
      args:
        [~c"-setcookie", ~c"#{cookie}"] ++
          Enum.flat_map(paths, &[~c"-pa", &1]) ++ Keyword.get(opts, :args, []),
      env: for({k, v} <- Keyword.get(opts, :env, []), do: {~c"#{k}", ~c"#{v}"})
    }

    # Always say which: otherwise :peer takes the name mode of the test
    # node, which is longnames after a longnames test, and a long name from
    # the hostname depends on DNS resolving it.
    peer_opts =
      if opts[:longnames],
        do: Map.merge(peer_opts, %{longnames: true, host: ~c"127.0.0.1"}),
        else: Map.put(peer_opts, :longnames, false)

    {:ok, peer, node} = :peer.start(peer_opts)
    target = %__MODULE__{peer: peer, node: node, cookie: cookie, name: name, opts: opts}

    unless opts[:erlang],
      do: {:ok, _} = call(target, :application, :ensure_all_started, [:elixir])

    if opts[:recon], do: :ok = call(target, :application, :load, [:recon])

    if opts[:telemetry],
      do: {:ok, _} = call(target, :application, :ensure_all_started, [:telemetry])

    if opts[:bandit],
      do: {:ok, _} = call(target, :application, :ensure_all_started, [:bandit])

    if opts[:riak], do: start_riak(target)

    for mod <- @fixtures do
      {^mod, bin, _} = :code.get_object_code(mod)
      file = String.to_charlist(Path.join(fixtures_dir(), "#{mod}.beam"))
      {:module, ^mod} = call(target, :code, :load_binary, [mod, file, bin])
    end

    target
  end

  # The fixtures' .beam files, written once per test run to a directory on
  # every target's code path, so that they're loaded from the code path as
  # a real node's modules are (the stale_code check looks there).
  defp fixtures_dir do
    case :persistent_term.get({__MODULE__, :fixtures_dir}, nil) do
      nil ->
        dir = Path.join(System.tmp_dir!(), "otpdbg_fixtures_#{System.pid()}")
        File.mkdir_p!(dir)

        for mod <- @fixtures do
          {^mod, bin, _} = :code.get_object_code(mod)
          File.write!(Path.join(dir, "#{mod}.beam"), bin)
        end

        :persistent_term.put({__MODULE__, :fixtures_dir}, String.to_charlist(dir))
        String.to_charlist(dir)

      dir ->
        dir
    end
  end

  @doc """
  Start `n` targets sharing a cookie, connected to each other as `links`
  says: `:full`, or a list of `{i, j}` index pairs. They don't connect
  transitively (`-connect_all false`), so a missing link stays missing.
  """
  def start_cluster(n, links \\ :full, opts \\ []) do
    cookie = "cluster_#{System.unique_integer([:positive])}"

    targets =
      for _ <- 1..n,
          do: start(Keyword.merge(opts, cookie: cookie, args: [~c"-connect_all", ~c"false"]))

    pairs =
      if links == :full,
        do: for(i <- 0..(n - 1), j <- (i + 1)..(n - 1)//1, do: {i, j}),
        else: links

    for {i, j} <- pairs do
      true = call(Enum.at(targets, i), :net_kernel, :connect_node, [Enum.at(targets, j).node])
    end

    targets
  end

  # riak_core with its ring files in a directory of its own, a free
  # handoff port, and a small ring.
  defp start_riak(target) do
    # Its warnings at start (no ring file yet) would print in the tests.
    _ = call(target, :logger, :remove_handler, [:default])
    dir = Path.join(System.tmp_dir!(), "otpdbg_riak_#{target.name}")
    File.rm_rf!(dir)
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    :ok = call(target, :application, :load, [:riak_core])
    # riak_core starts os_mon; its disk and memory alarms are noise here.
    :ok = call(target, :application, :load, [:os_mon])

    for key <- [:start_disksup, :start_memsup, :start_cpu_sup],
        do: :ok = call(target, :application, :set_env, [:os_mon, key, false])

    for {key, value} <- [
          ring_state_dir: to_charlist(Path.join(dir, "ring")),
          platform_data_dir: to_charlist(dir),
          handoff_port: port,
          ring_creation_size: 8,
          # Hand a vnode off after half a second idle, not a minute.
          vnode_inactivity_timeout: 500,
          vnode_check_interval: 500,
          # Look for ownership handoffs to start every second, not every 10.
          vnode_management_timer: 1_000
        ],
        do: :ok = call(target, :application, :set_env, [:riak_core, key, value])

    {:ok, _} = call(target, :application, :ensure_all_started, [:riak_core])
  end

  @doc "Stop the target and wait until our node has noticed it's gone."
  def stop(%__MODULE__{peer: peer, node: node}) do
    :peer.stop(peer)
    wait_until(fn -> node not in Node.list(:hidden) end)
  end

  @doc "Stop the target and start a fresh one with the same name and cookie."
  def restart(%__MODULE__{} = target) do
    stop(target)
    start(Keyword.merge(target.opts, name: target.name, cookie: target.cookie))
  end

  @doc "Run `mod.fun(args)` on the target, over the peer control channel."
  def call(%__MODULE__{peer: peer}, mod, fun, args), do: :peer.call(peer, mod, fun, args, 15_000)

  @doc "Connect `OtpDebugMcp.Target` to the target."
  def connect(%__MODULE__{node: node, cookie: cookie}),
    do: OtpDebugMcp.Target.connect(Atom.to_string(node), cookie)

  def wait_until(fun, timeout \\ 5_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        raise "condition not met in time"

      true ->
        Process.sleep(50)
        wait_until(fun, timeout - 50)
    end
  end

  defp elixir_paths, do: Enum.map([:elixir, :logger], &lib_ebin/1)

  defp lib_ebin(app), do: app |> :code.lib_dir() |> Path.join("ebin") |> to_charlist()
end
