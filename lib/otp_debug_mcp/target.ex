defmodule OtpDebugMcp.Target do
  @moduledoc """
  Manages the connection to the target OTP node.

  We start our own node as a *hidden* node (`--hidden`), so connecting never
  changes the target's cluster topology: the target does not gossip our name
  to other nodes, and `Node.list/0` on the target stays clean. This means the
  tool works against any running Erlang/Elixir/Gleam/LFE system with zero code
  changes or added dependencies on the target side.

  At connect time we inject recon's object code into the target
  (`:code.load_binary/3` over rpc), so all recon-based checks run *on the
  target* even though the target never declared recon as a dependency.

  All remote calls go through `rpc/4`, which enforces a timeout so a stuck
  target can never hang an MCP tool call indefinitely.
  """

  use GenServer
  require Logger

  @rpc_timeout 5_000

  defstruct node: nil, connected: false

  # -- Client API --------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Connect to `node` (e.g. `:\"myapp@127.0.0.1\"`), using `cookie` if given."
  @spec connect(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def connect(node, cookie \\ nil), do: GenServer.call(__MODULE__, {:connect, node, cookie})

  @doc "The currently connected target node, or nil."
  @spec target_node() :: node() | nil
  def target_node, do: GenServer.call(__MODULE__, :node)

  @doc """
  Run `mod.fun(args)` on the target node with a bounded timeout.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec rpc(module(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def rpc(mod, fun, args, timeout \\ @rpc_timeout) do
    case target_node() do
      nil ->
        {:error, :not_connected}

      target ->
        case with_stderr_group_leader(fn -> :rpc.call(target, mod, fun, args, timeout) end) do
          {:badrpc, reason} -> {:error, {:badrpc, reason}}
          result -> {:ok, result}
        end
    end
  end

  @doc """
  Run `fun` with this process's group leader set to stderr.

  Remote processes (rpc workers, remote spawns) send their io to the caller's
  group leader. Over MCP stdio, stdout is the protocol stream, so any
  `io:format` on the target must never reach it.
  """
  def with_stderr_group_leader(fun) do
    original = Process.group_leader()
    Process.group_leader(self(), Process.whereis(:standard_error))

    try do
      fun.()
    after
      Process.group_leader(self(), original)
    end
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:connect, node_str, cookie}, _from, state) do
    target = String.to_atom(node_str)

    with :ok <- ensure_distribution(target),
         :ok <- set_cookie(target, cookie),
         true <- Node.connect(target) || {:error, :connection_failed} do
      inject_recon(target)
      Logger.info("connected to #{target} (hidden)")
      {:reply, :ok, %{state | node: target, connected: true}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:node, _from, state) do
    node = if state.connected and state.node in Node.list(:hidden), do: state.node
    {:reply, node, state}
  end

  # -- Internals ---------------------------------------------------------------

  # Distribution is started at connect time because shortnames and longnames
  # nodes cannot talk to each other: the mode must match the target's name.
  # Mix releases default to shortnames (app@host); `--name` / IPs use longnames.
  defp ensure_distribution(target) do
    want = name_domain(target)

    cond do
      Node.alive?() and current_name_domain() == want ->
        :ok

      Node.alive?() and Node.list(:connected) != [] ->
        {:error, {:name_mode_mismatch, "already connected using #{current_name_domain()}"}}

      true ->
        if Node.alive?(), do: :net_kernel.stop()
        start_distribution(target, want)
    end
  end

  defp start_distribution(target, name_domain) do
    # epmd must be running before a node can register itself.
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    base = "otp_debug_mcp_#{System.pid()}"

    name =
      case {name_domain, host(target)} do
        {:longnames, host} when host in ["127.0.0.1", "localhost"] -> :"#{base}@127.0.0.1"
        _ -> String.to_atom(base)
      end

    case :net_kernel.start(name, %{name_domain: name_domain, hidden: true}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:distribution_failed, reason}}
    end
  end

  defp host(target), do: target |> Atom.to_string() |> String.split("@") |> List.last()

  defp name_domain(target) do
    if host(target) =~ ~r/[.:]/, do: :longnames, else: :shortnames
  end

  defp current_name_domain do
    if :net_kernel.longnames(), do: :longnames, else: :shortnames
  end

  # Without an explicit cookie, use ~/.erlang.cookie (what `iex --sname` and
  # `erl -sname` use). Releases have their own cookie: pass RELEASE_COOKIE.
  defp set_cookie(target, nil) do
    path = Path.join(System.user_home!(), ".erlang.cookie")

    case File.read(path) do
      {:ok, cookie} -> set_cookie(target, String.trim(cookie))
      {:error, _} -> :ok
    end
  end

  defp set_cookie(target, cookie) do
    Node.set_cookie(target, String.to_atom(cookie))
    :ok
  end

  # Push recon's BEAM code into the target so checks can call it remotely.
  defp inject_recon(target) do
    _ = Application.load(:recon)

    for mod <- Application.spec(:recon, :modules) || [],
        {^mod, bin, file} <- [:code.get_object_code(mod)] do
      :rpc.call(target, :code, :load_binary, [mod, file, bin], @rpc_timeout)
    end

    :ok
  end
end
