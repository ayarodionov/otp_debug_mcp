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
    OtpDebugMcp.Fixtures.Mailbox,
    OtpDebugMcp.Fixtures.Operator,
    OtpDebugMcp.Fixtures.App,
    OtpDebugMcp.Fixtures.Worker,
    OtpDebugMcp.Fixtures.Crasher,
    OtpDebugMcp.Fixtures.CrashSup,
    OtpDebugMcp.Fixtures.Spawner,
    OtpDebugMcp.Fixtures.Fragmenter,
    OtpDebugMcp.Fixtures.Hog,
    OtpDebugMcp.Fixtures.AtomLeak,
    OtpDebugMcp.Fixtures.ProcLeak,
    OtpDebugMcp.Fixtures.SliceKeeper,
    OtpDebugMcp.Fixtures.Fussy
  ]

  defstruct [:peer, :node, :cookie, :name, :opts]

  @doc """
  Start a target node. Options: `:name`, `:cookie`, `longnames: true` (as
  `name@127.0.0.1`), `recon: true` (recon application loaded, as in a
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

    paths = elixir_paths() ++ if(opts[:recon], do: [lib_ebin(:recon)], else: [])

    peer_opts = %{
      name: name,
      connection: :standard_io,
      args:
        [~c"-setcookie", ~c"#{cookie}"] ++
          Enum.flat_map(paths, &[~c"-pa", &1]) ++ Keyword.get(opts, :args, [])
    }

    peer_opts =
      if opts[:longnames],
        do: Map.merge(peer_opts, %{longnames: true, host: ~c"127.0.0.1"}),
        else: peer_opts

    {:ok, peer, node} = :peer.start(peer_opts)
    target = %__MODULE__{peer: peer, node: node, cookie: cookie, name: name, opts: opts}

    unless opts[:erlang],
      do: {:ok, _} = call(target, :application, :ensure_all_started, [:elixir])

    if opts[:recon], do: :ok = call(target, :application, :load, [:recon])

    for mod <- @fixtures do
      {^mod, bin, file} = :code.get_object_code(mod)
      {:module, ^mod} = call(target, :code, :load_binary, [mod, file, bin])
    end

    target
  end

  @doc """
  Start `n` targets sharing a cookie, connected to each other as `links`
  says: `:full`, or a list of `{i, j}` index pairs. They don't connect
  transitively (`-connect_all false`), so a missing link stays missing.
  """
  def start_cluster(n, links \\ :full) do
    cookie = "cluster_#{System.unique_integer([:positive])}"
    targets = for _ <- 1..n, do: start(cookie: cookie, args: [~c"-connect_all", ~c"false"])

    pairs =
      if links == :full,
        do: for(i <- 0..(n - 1), j <- (i + 1)..(n - 1)//1, do: {i, j}),
        else: links

    for {i, j} <- pairs do
      true = call(Enum.at(targets, i), :net_kernel, :connect_node, [Enum.at(targets, j).node])
    end

    targets
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
