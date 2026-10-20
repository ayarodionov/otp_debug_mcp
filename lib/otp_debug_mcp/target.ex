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
  @spawns :otp_debug_mcp_target_spawns
  # The debugger's own footprint on the target: atoms known to exist there,
  # functions already called there, and what first-time calls added.
  @known_atoms :otp_debug_mcp_known_atoms
  @called :otp_debug_mcp_called
  @footprint :otp_debug_mcp_footprint

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

  @doc "The target node, or nil before the first connect. Never reconnects."
  @spec connected_node() :: node() | nil
  def connected_node, do: GenServer.call(__MODULE__, :connected_node)

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
        case with_stderr_group_leader(fn -> call(target, mod, fun, args, timeout) end) do
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
  Record that we spawned `n` processes on the target. Each rpc spawns one
  there; `OtpDebugMcp.ProcessContext` discounts them when it estimates a
  process's age from the pids spawned since.
  """
  def note_spawns(n \\ 1) do
    now = System.monotonic_time(:microsecond)
    for i <- 1..n//1, do: :ets.insert(@spawns, {{now, i, make_ref()}})
    :ok
  end

  @doc """
  How many seconds before monotonic time `at_us` each of our spawns on the
  target happened, most recent first; spawns up to `slack_us` after it
  count as 0. Forgets spawns older than an hour.
  """
  def own_spawn_ages(at_us, slack_us \\ 0) do
    cutoff = at_us - 3_600_000_000
    :ets.select_delete(@spawns, [{{{:"$1", :_, :_}}, [{:<, :"$1", cutoff}], [true]}])

    for {{t, _, _}} <- :ets.tab2list(@spawns), t <= at_us + slack_us do
      max(at_us - t, 0) / 1_000_000
    end
    |> Enum.sort()
  end

  @doc """
  Run `fun`, which sends `term` to the target, and log what it adds there.

  Atoms are never freed, and sending a term creates its atoms on the
  receiving node; calling a module for the first time may load it. So the
  first time `signature` is used, or when `term` holds atoms we haven't
  sent before, the target's atom count and code memory are read before and
  after, and the difference is logged for `footprint_since/1`, which
  snapshot diffs subtract. Repeat calls cost nothing extra.
  """
  def with_footprint(target, signature, term, fun) do
    new_atoms =
      Enum.reject(atoms_in(term, MapSet.new()), &:ets.member(@known_atoms, {target, &1}))

    first_call? = :ets.insert_new(@called, {{target, signature}})

    if first_call? or new_atoms != [] do
      before = footprint_reading(target)
      result = fun.()
      for atom <- new_atoms, do: :ets.insert(@known_atoms, {{target, atom}})
      record_footprint(before, footprint_reading(target))
      result
    else
      fun.()
    end
  end

  @doc """
  What this tool added to the target since monotonic time `since_us`:
  `%{atoms: count, code_bytes: bytes}`.
  """
  def footprint_since(since_us) do
    :ets.select(@footprint, [
      {{{:"$1", :_}, :"$2", :"$3"}, [{:>=, :"$1", since_us}], [{{:"$2", :"$3"}}]}
    ])
    |> Enum.reduce(%{atoms: 0, code_bytes: 0}, fn {atoms, code}, acc ->
      %{atoms: acc.atoms + atoms, code_bytes: acc.code_bytes + code}
    end)
  end

  defp footprint_reading(target) do
    with atoms when is_integer(atoms) <- raw_call(target, :erlang, :system_info, [:atom_count]),
         code when is_integer(code) <- raw_call(target, :erlang, :memory, [:code]) do
      {atoms, code}
    else
      _ -> nil
    end
  end

  defp record_footprint({atoms0, code0}, {atoms1, code1})
       when atoms1 > atoms0 or code1 > code0 do
    key = {System.monotonic_time(:microsecond), make_ref()}
    :ets.insert(@footprint, {key, max(atoms1 - atoms0, 0), max(code1 - code0, 0)})
  end

  defp record_footprint(_, _), do: :ok

  defp atoms_in(atom, acc) when is_atom(atom), do: MapSet.put(acc, atom)
  defp atoms_in([head | tail], acc), do: atoms_in(tail, atoms_in(head, acc))
  defp atoms_in(tuple, acc) when is_tuple(tuple), do: atoms_in(Tuple.to_list(tuple), acc)

  defp atoms_in(map, acc) when is_map(map),
    do: map |> :maps.to_list() |> atoms_in(acc)

  defp atoms_in(_other, acc), do: acc

  # A target that restarted has none of the atoms or code we added.
  defp forget_footprint(target) do
    :ets.match_delete(@known_atoms, {{target, :_}})
    :ets.match_delete(@called, {{target, :_}})
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
  def init(_opts) do
    :ets.new(@spawns, [:named_table, :public, :ordered_set, write_concurrency: true])

    for table <- [@known_atoms, @called],
        do: :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    :ets.new(@footprint, [:named_table, :public, :ordered_set])
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:connect, node_str, cookie}, _from, state) do
    target = String.to_atom(node_str)

    # An existing connection would make Node.connect succeed whatever the
    # cookie, so a wrong cookie would be reported as connected (and break
    # the next reconnect). Start over so the cookie is always checked.
    if target in Node.list(:hidden), do: Node.disconnect(target)
    forget_footprint(target)

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
  def handle_call(:connected_node, _from, state), do: {:reply, state.node, state}

  def handle_call(:target, _from, %{connected: false} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:target, _from, %{node: node} = state) do
    cond do
      node in Node.list(:hidden) ->
        {:reply, {:ok, node}, state}

      Node.connect(node) ->
        forget_footprint(node)
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
          call(target, :code, :which, [mod], @rpc_timeout) == :non_existing,
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
    target_app = call(target, :application, :get_key, [:recon, :vsn], @rpc_timeout)

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
    case call(target, :recon, :module_info, [], @rpc_timeout) do
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
          :ok ->
            {:cont, acc}

          {:error, reason} ->
            {:halt, {:error, "could not load #{mod} into the target: #{reason}"}}
        end
      end)
    end
  end

  defp load_method(target) do
    ours = :erlang.system_info(:otp_release) |> to_string()
    theirs = call(target, :erlang, :system_info, [:otp_release], @rpc_timeout) |> to_string()

    cond do
      otp_major(theirs) >= otp_major(ours) ->
        {:ok, :loaded}

      call(target, :code, :which, [:compile], @rpc_timeout) != :non_existing ->
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
           call(target, :compile, :forms, [forms, [:binary, :return_errors]], 15_000) do
      load_binary(target, mod, ~c"#{mod}.erl", compiled)
    else
      {:error, :beam_lib, _} -> {:error, "this tool's copy has no debug_info to compile from"}
      {:error, errors, _warnings} -> {:error, "compile failed: #{inspect(errors)}"}
      other -> {:error, inspect(other)}
    end
  end

  defp call(target, mod, fun, args, timeout) do
    with_footprint(target, {mod, fun, length(args)}, [mod, fun | args], fn ->
      raw_call(target, mod, fun, args, timeout)
    end)
  end

  # Every rpc spawns a process on the target to run it.
  defp raw_call(target, mod, fun, args, timeout \\ @rpc_timeout) do
    note_spawns()
    :rpc.call(target, mod, fun, args, timeout)
  end

  defp load_binary(target, mod, file, bin) do
    case call(target, :code, :load_binary, [mod, file, bin], @rpc_timeout) do
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
