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
  @recon_modules [:recon, :recon_alloc, :recon_lib, :recon_trace]

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
        case :rpc.call(target, mod, fun, args, timeout) do
          {:badrpc, reason} -> {:error, {:badrpc, reason}}
          result -> {:ok, result}
        end
    end
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_distribution()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:connect, node_str, cookie}, _from, state) do
    target = String.to_atom(node_str)
    if cookie, do: Node.set_cookie(target, String.to_atom(cookie))

    if Node.connect(target) do
      inject_recon(target)
      Logger.info("connected to #{target} (hidden)")
      {:reply, :ok, %{state | node: target, connected: true}}
    else
      {:reply, {:error, :connection_failed}, state}
    end
  end

  def handle_call(:node, _from, state) do
    node = if state.connected and state.node in Node.list(:hidden), do: state.node
    {:reply, node, state}
  end

  # -- Internals ---------------------------------------------------------------

  # Start distribution lazily if the escript/release wasn't booted with --sname.
  # Failure is logged, not fatal: connect/2 will return a clear error later.
  defp ensure_distribution do
    unless Node.alive?() do
      # epmd must be running before a node can register itself.
      System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

      name = :"otp_debug_mcp_#{:erlang.unique_integer([:positive])}@127.0.0.1"

      case :net_kernel.start(name, %{name_domain: :longnames, hidden: true}) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("could not start distribution: #{inspect(reason)}")
      end
    end
  rescue
    e -> Logger.warning("could not start distribution: #{inspect(e)}")
  end

  # Push recon's BEAM code into the target so checks can call it remotely.
  defp inject_recon(target) do
    for mod <- @recon_modules,
        {^mod, bin, file} <- [:code.get_object_code(mod)] do
      :rpc.call(target, :code, :load_binary, [mod, file, bin], @rpc_timeout)
    end

    :ok
  end
end
