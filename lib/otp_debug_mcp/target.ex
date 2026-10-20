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
  target* even though the target never declared recon as a dependency. A
  target on an older OTP release than ours can't load our compiled code, so
  there recon is compiled on the target from its abstract code.

  All remote calls go through `rpc/4`, which enforces a timeout so a stuck
  target can never hang an MCP tool call indefinitely.
  """

  use GenServer
  require Logger

  @rpc_timeout 5_000
  @recon_modules [:recon, :recon_alloc, :recon_lib, :recon_map, :recon_rec, :recon_trace]
  @injected_marker :otp_debug_mcp_injected

  defstruct node: nil, connected: false, recon: nil

  # -- Client API --------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Connect to `node` (e.g. `:\"myapp@127.0.0.1\"`), using `cookie` if given."
  @spec connect(String.t(), String.t() | nil) :: {:ok, %{recon: map()}} | {:error, term()}
  def connect(node, cookie \\ nil), do: GenServer.call(__MODULE__, {:connect, node, cookie})

  @doc """
  The connected target node. If the connection dropped (e.g. the target
  restarted), one reconnect is attempted, re-injecting recon on success.
  """
  @spec target() :: {:ok, node()} | {:error, :not_connected | {:connection_lost, node()}}
  def target, do: GenServer.call(__MODULE__, :target)

  @doc """
  Run `mod.fun(args)` on the target node with a bounded timeout.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec rpc(module(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def rpc(mod, fun, args, timeout \\ @rpc_timeout) do
    case target() do
      {:error, _} = err ->
        err

      {:ok, target} ->
        case with_stderr_group_leader(fn -> :rpc.call(target, mod, fun, args, timeout) end) do
          {:badrpc, {:EXIT, {:undef, [{m, f, a, _} | _]}}} when m in @recon_modules ->
            {:error, missing_recon_message(m, f, length(a))}

          {:badrpc, reason} ->
            {:error, {:badrpc, reason}}

          result ->
            {:ok, result}
        end
    end
  end

  @doc "Why a recon function is undefined on the target, given how recon got there."
  def missing_recon_message(m, f, arity) do
    case GenServer.call(__MODULE__, :recon) do
      %{source: "unavailable", reason: reason} ->
        "#{m}:#{f}/#{arity} is not available: #{reason}"

      %{source: "target"} ->
        "#{m}:#{f}/#{arity} is not available in the target's own recon version, " <>
          "which is used as-is so that its running recon sessions are left " <>
          "untouched. Other checks still work."

      _ ->
        "#{m}:#{f}/#{arity} is not available on the target, although recon was " <>
          "injected. Call connect again to re-inject it."
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
      recon = inject_recon(target)
      Logger.info("connected to #{target} (hidden), recon: #{inspect(recon)}")
      {:reply, {:ok, %{recon: recon}}, %{state | node: target, connected: true, recon: recon}}
    else
      # Keep the previous target only if a mode switch didn't drop it.
      {:error, _} = err ->
        state = if state.node in Node.list(:hidden), do: state, else: %__MODULE__{}
        {:reply, err, state}
    end
  end

  def handle_call(:recon, _from, state), do: {:reply, state.recon, state}

  def handle_call(:target, _from, %{connected: false} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:target, _from, %{node: node} = state) do
    cond do
      node in Node.list(:hidden) ->
        {:reply, {:ok, node}, state}

      Node.connect(node) ->
        recon = inject_recon(node)
        Logger.info("reconnected to #{node}, recon: #{inspect(recon)}")
        {:reply, {:ok, node}, %{state | recon: recon}}

      true ->
        {:reply, {:error, {:connection_lost, node}}, state}
    end
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

      true ->
        # Switching modes: connect means "debug this target now", so dropping
        # connections made in the other mode is the intended effect.
        if Node.alive?() do
          Enum.each(Node.list(:connected), &Node.disconnect/1)
          :net_kernel.stop()
        end

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

  # Push recon's BEAM code into the target so checks can call it remotely,
  # but only modules the target doesn't already have (loaded or on its code
  # path). Loading over an existing module would make the target's version
  # "old", and the next load hard-purges it, killing any process still
  # running it, such as an operator's recon_trace session. This also makes
  # repeat connects and reconnects load nothing.
  defp inject_recon(target) do
    _ = Application.load(:recon)

    missing =
      for mod <- Application.spec(:recon, :modules) || [],
          :rpc.call(target, :code, :which, [mod], @rpc_timeout) == :non_existing,
          do: mod

    case load_recon(target, missing) do
      {:ok, how} -> describe_recon(target, missing, how)
      {:error, reason} -> %{source: "unavailable", reason: reason}
    end
  end

  defp describe_recon(target, injected, how) do
    ours =
      %{source: "injected", version: to_string(Application.spec(:recon, :vsn))}
      |> Map.merge(if how == :compiled, do: %{compiled_on_target: true}, else: %{})

    # A target that depends on recon has the application loaded (releases
    # load every app); our injection loads bare modules only.
    target_app = :rpc.call(target, :application, :get_key, [:recon, :vsn], @rpc_timeout)

    cond do
      :recon in injected ->
        ours

      match?({:ok, _}, target_app) ->
        {:ok, vsn} = target_app
        %{source: "target", version: to_string(vsn), injected_missing_modules: injected}

      # Present without its application: injected by an earlier connect.
      injected_by_us?(target) ->
        ours

      true ->
        %{source: "target", version: "unknown", injected_missing_modules: injected}
    end
  end

  defp injected_by_us?(target) do
    case :rpc.call(target, :recon, :module_info, [], @rpc_timeout) do
      info when is_list(info) ->
        info[:md5] == :recon.module_info(:md5) or
          Keyword.has_key?(info[:attributes] || [], @injected_marker)

      _ ->
        false
    end
  end

  # Code compiled by a newer OTP generally can't be loaded by an older one
  # (OTP 28's atom table encoding is unreadable to OTP 26, for one). So for
  # an older target, recon is compiled *there*, from the abstract code in
  # our copy's debug_info, with the target's own compiler. Compiled modules
  # get a marker attribute (@injected_marker) so a later connect recognizes
  # them as ours.

  defp load_recon(_target, []), do: {:ok, :none}

  defp load_recon(target, modules) do
    with {:ok, how} <- load_method(target) do
      Enum.reduce_while(modules, {:ok, how}, fn mod, acc ->
        case load_module(target, mod, how) do
          :ok -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, "could not load #{mod} into the target: #{reason}"}}
        end
      end)
    end
  end

  defp load_method(target) do
    ours = :erlang.system_info(:otp_release) |> to_string()
    theirs = :rpc.call(target, :erlang, :system_info, [:otp_release], @rpc_timeout) |> to_string()

    cond do
      otp_major(theirs) >= otp_major(ours) ->
        {:ok, :loaded}

      :rpc.call(target, :code, :which, [:compile], @rpc_timeout) != :non_existing ->
        {:ok, :compiled}

      true ->
        {:error,
         "the target runs OTP #{theirs}, older than this tool's OTP #{ours}, so recon has " <>
           "to be compiled on the target, but it has no compiler application. Checks " <>
           "that need recon fail; the others work."}
    end
  end

  # "26" -> 26; pre-OTP 17 names like "R16B03" sort as older than anything.
  defp otp_major(release) do
    case Integer.parse(release) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp load_module(target, mod, :loaded) do
    {^mod, bin, file} = :code.get_object_code(mod)
    load_binary(target, mod, file, bin)
  end

  defp load_module(target, mod, :compiled) do
    {^mod, bin, _file} = :code.get_object_code(mod)

    with {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(bin, [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, mod, data, []),
         forms = add_marker(forms),
         {:ok, ^mod, compiled} <-
           :rpc.call(target, :compile, :forms, [forms, [:binary, :return_errors]], 15_000) do
      load_binary(target, mod, ~c"#{mod}.erl", compiled)
    else
      {:error, :beam_lib, _} -> {:error, "this tool's copy has no debug_info to compile from"}
      {:error, errors, _warnings} -> {:error, "compile failed: #{inspect(errors)}"}
      other -> {:error, inspect(other)}
    end
  end

  defp load_binary(target, mod, file, bin) do
    case :rpc.call(target, :code, :load_binary, [mod, file, bin], @rpc_timeout) do
      {:module, ^mod} -> :ok
      other -> {:error, inspect(other)}
    end
  end

  defp add_marker(forms) do
    Enum.flat_map(forms, fn
      {:attribute, anno, :module, _} = form -> [form, {:attribute, anno, @injected_marker, true}]
      form -> [form]
    end)
  end
end
