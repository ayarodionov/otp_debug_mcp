defmodule OtpDebugMcp.Tools do
  @moduledoc """
  MCP tool components. Each tool is a thin schema + dispatch layer; the real
  logic lives in `OtpDebugMcp.Checks`, `OtpDebugMcp.Target`,
  `OtpDebugMcp.Tracer` and `OtpDebugMcp.Snapshot`.
  """

  alias Anubis.Server.Response
  alias OtpDebugMcp.Format

  @doc "Encode any term as a JSON tool response (falling back to inspect for non-JSON terms)."
  def json_response(frame, term) do
    text =
      try do
        JSON.encode!(term)
      rescue
        _ -> Format.inspect(term, pretty: true, limit: 200)
      end

    {:reply, Response.text(Response.tool(), text), frame}
  end

  def error_response(frame, reason) do
    message =
      cond do
        is_binary(reason) -> reason
        is_map(reason) -> JSON.encode!(reason)
        true -> Format.inspect(reason)
      end

    {:reply, Response.error(Response.tool(), message), frame}
  end

  defmodule Connect do
    @moduledoc "Connect to a running OTP node as a hidden node. Call this first."
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Target, Tools}

    schema do
      field(:node, {:required, :string},
        description: "Target node name, e.g. myapp@127.0.0.1 or myapp@hostname"
      )

      field(:cookie, :string,
        description:
          "Erlang cookie. Omit to use the server's OTP_DEBUG_MCP_COOKIE if set, " <>
            "else this machine's ~/.erlang.cookie"
      )
    end

    @impl true
    def execute(%{node: node} = params, frame) do
      case Target.connect(node, params[:cookie]) do
        {:ok, %{recon: recon}} ->
          Tools.json_response(
            frame,
            Map.merge(
              %{
                connected: node,
                recon: recon,
                hint: "Run the `diagnose` tool next for a full health check."
              },
              cluster_hint()
            )
          )

        {:error, reason} ->
          Tools.error_response(frame, "#{inspect(reason)}. " <> connect_hints())
      end
    end

    # A node in a cluster: say so, since comparing the members often finds
    # the odd one out faster than diagnosing one.
    defp cluster_hint do
      case Target.rpc(:erlang, :nodes, []) do
        {:ok, [_ | _] = others} ->
          %{
            cluster: %{
              other_nodes: Enum.map(others, &Atom.to_string/1),
              hint: "This node is in a cluster; the cluster tool compares all its nodes."
            }
          }

        _ ->
          %{}
      end
    end

    defp connect_hints do
      """
      Connection failed. Common causes: wrong cookie (check ~/.erlang.cookie \
      on the target host or the release's RELEASE_COOKIE); target not started \
      with a node name (--sname/--name); shortname vs longname mismatch; \
      epmd or the distribution port not reachable; the target uses TLS \
      distribution and this server doesn't, or the other way round (both \
      need -proto_dist inet_tls and an ssl_dist optfile; see \
      docs/production.md).
      """
    end
  end

  defmodule Diagnose do
    @moduledoc """
    Run the full diagnostic battery (message queues, supervisor restarts and
    crash loops, binary leaks, memory and allocator fragmentation,
    process/atom/port limits, ETS, schedulers, CPU hogs). Findings come back
    ranked worst-first, each with an interpretation and suggested next step.
    This should be the FIRST tool called after connect.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Checks, Tools}

    schema do
    end

    @impl true
    def execute(_params, frame), do: Tools.json_response(frame, Checks.run_all())
  end

  defmodule RunCheck do
    @moduledoc "Run a single named diagnostic check (cheaper than the full battery)."
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Checks, Tools}

    schema do
      field(:check, {:required, :string},
        description:
          "One of: message_queues, supervisor_restarts, binary_leak (force-GCs every " <>
            "process), memory_breakdown, " <>
            "allocator_fragmentation, process_count, atom_table, ets_tables, ports, " <>
            "schedulers, top_reductions"
      )
    end

    @impl true
    def execute(%{check: check}, frame) do
      case Enum.find(Checks.all_checks(), &(Atom.to_string(&1) == check)) do
        nil -> Tools.error_response(frame, {:unknown_check, check, Checks.all_checks()})
        name -> Tools.json_response(frame, Checks.run(name))
      end
    end
  end

  defmodule ProcessInfo do
    @moduledoc """
    Deep-inspect one process: process_info, current stacktrace, an estimate
    of its age, the restart history of its supervisor, and (for gen_*
    processes) its state via sys:get_state with a short timeout.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Checks, ProcessContext, Target, Tools}

    schema do
      field(:pid, {:required, :string},
        description:
          "Pid as printed, e.g. <0.123.0>, or a registered name, e.g. MyApp.Worker, " <>
            "my_server or 'my-server'"
      )

      field(:include_state, :boolean,
        description:
          "Also fetch sys:get_state (safe for gen_server/gen_statem; " <>
            "skipped automatically if the process doesn't respond in 2s)"
      )
    end

    @impl true
    def execute(%{pid: pid_str} = params, frame) do
      # Context first: its age estimate counts the processes spawned since,
      # and every rpc spawns one on the target.
      with {:ok, pid} <- resolve(pid_str),
           {:ok, context} <- context(pid),
           {:ok, info} <- Target.rpc(:recon, :info, [pid]) do
        {state, state_summary} =
          cond do
            !params[:include_state] ->
              {"not requested: set include_state to fetch it", nil}

            not sys_safe?(pid) ->
              {"skipped: the process isn't waiting in the loop of an OTP behaviour " <>
                 "(gen_server, gen_statem, gen_event) or a Gleam actor, so it may not " <>
                 "understand sys:get_state, and asking could crash it", nil}

            true ->
              fetch_state(pid)
          end

        binary_bytes =
          case Target.rpc(:recon, :info, [pid, :binary_memory]) do
            {:ok, {:binary_memory, bytes}} -> bytes
            _ -> nil
          end

        Tools.json_response(
          frame,
          context
          |> Map.merge(%{
            pid: Format.inspect(pid),
            info: Format.inspect(info, limit: :infinity, pretty: true),
            binary_memory_bytes: binary_bytes,
            state: state
          })
          |> Map.merge(if pid_str =~ ~r/^[^<#]/, do: %{name: pid_str}, else: %{})
          |> Map.merge(if state_summary, do: %{state_summary: state_summary}, else: %{})
        )
      else
        err -> Tools.error_response(frame, err)
      end
    end

    defp sys_safe?(pid) do
      code = Checks.sys_safe_fun() <> "SysSafe(Pid)."
      Checks.remote_eval(code, Pid: pid) == {:ok, true}
    end

    defp fetch_state(pid) do
      case Target.rpc(:sys, :get_state, [pid, 2_000], 3_000) do
        {:ok, s} ->
          {Format.inspect(s, limit: 100, pretty: true), summarize(s)}

        {:error, {:badrpc, {:EXIT, {:timeout, _}}}} ->
          {"unavailable: the process did not answer sys:get_state within 2s. " <>
             "This is a symptom, not a tool failure: the process is blocked " <>
             "or its mailbox is backed up, so system messages wait in line too.", nil}

        {:error, e} ->
          {"unavailable: #{Format.inspect(e)}", nil}
      end
    end

    # The state's shape and size, which a printout cut off at a depth hides.
    defp summarize(state) do
      kind =
        cond do
          is_list(state) -> %{kind: "list", length: length(state)}
          is_map(state) -> %{kind: "map", size: map_size(state)}
          is_tuple(state) -> %{kind: "tuple", size: tuple_size(state)}
          is_binary(state) -> %{kind: "binary", bytes: byte_size(state)}
          true -> %{kind: "other"}
        end

      Map.put(kind, :words, :erts_debug.flat_size(state))
    end

    # A process that exited is reported by recon:info right after.
    defp context(pid) do
      case ProcessContext.describe(pid) do
        {:ok, context} -> {:ok, context}
        {:error, reason} -> {:ok, %{age: "unavailable: #{Format.inspect(reason)}"}}
      end
    end

    # Pids arrive as "<0.107.0>", as the target and our tools print them
    # (see OtpDebugMcp.Format), which must be parsed on the target, or in
    # our node's form, "#PID<39943.107.0>" or "<39943.107.0>", from an
    # agent that got one elsewhere, which is already valid locally.
    defp resolve("#PID" <> rest), do: resolve(rest)

    defp resolve("<0." <> _ = pid_str) do
      Target.rpc(:erlang, :list_to_pid, [String.to_charlist(pid_str)])
    end

    defp resolve("<" <> _ = pid_str) do
      {:ok, :erlang.list_to_pid(String.to_charlist(pid_str))}
    rescue
      ArgumentError -> {:error, {:invalid_pid, pid_str}}
    end

    # A name may come quoted, as Erlang prints atoms like 'log-index'.
    defp resolve("'" <> quoted) do
      case String.split(quoted, "'") do
        [name, ""] -> resolve(name)
        _ -> {:error, {:no_such_process, "'" <> quoted}}
      end
    end

    defp resolve(name) do
      candidates = [String.to_atom(name), Module.concat([name])]

      Enum.find_value(candidates, {:error, {:no_such_process, name}}, fn atom ->
        case Target.rpc(:erlang, :whereis, [atom]) do
          {:ok, pid} when is_pid(pid) -> {:ok, pid}
          _ -> nil
        end
      end)
    end
  end

  defmodule SupervisionTree do
    @moduledoc """
    Render the supervision tree of one application on the target node, with
    each supervisor's strategy and restart history (restarts within its
    max_seconds window, the last restart, and whether it is at its limit).
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Checks, Target, Tools}

    schema do
      field(:app, {:required, :string}, description: "OTP application name, e.g. my_app")

      field(:depth, :integer, description: "Max tree depth (default 5)")
    end

    @impl true
    def execute(%{app: app} = params, frame) do
      depth = params[:depth] || 5

      with {:ok, masters} <-
             Target.rpc(:application_controller, :get_master, [String.to_atom(app)]),
           true <- is_pid(masters) || {:error, {:app_not_running, app}},
           {:ok, {root, _app}} <- Target.rpc(:application_master, :get_child, [masters]) do
        Tools.json_response(frame, tree(root, depth))
      else
        err -> Tools.error_response(frame, err)
      end
    end

    @max_children 50

    defp tree(pid, depth) do
      %{supervisor: Format.inspect(pid)}
      |> Map.merge(Checks.restart_history(pid))
      |> Map.merge(children(pid, depth))
    end

    defp children(_pid, 0), do: %{children: "not expanded: depth limit reached"}

    defp children(pid, depth) do
      case Target.rpc(:supervisor, :which_children, [pid], 3_000) do
        {:ok, children} when is_list(children) ->
          shown =
            for {id, child, type, _mods} <- Enum.take(children, @max_children) do
              base = %{id: Format.inspect(id), pid: Format.inspect(child), type: type}

              if type == :supervisor and is_pid(child) do
                base
                |> Map.merge(Checks.restart_history(child))
                |> Map.merge(children(child, depth - 1))
              else
                base
              end
            end

          result = %{child_count: length(children), children: shown}

          if length(children) > @max_children,
            do: Map.put(result, :note, "only the first #{@max_children} children are listed"),
            else: result

        other ->
          %{children: "unavailable: #{Format.inspect(other)}"}
      end
    end
  end

  defmodule TraceCalls do
    @moduledoc """
    Trace calls to a module/function on the target, safely: hard caps on
    event count and duration, and an early stop if calls arrive too fast,
    so this cannot flood a production node.

    On OTP 27+ targets the trace runs in its own isolated trace session and
    never affects other tracing on the node. On older targets it uses
    recon_trace and refuses if other tracing is active (e.g. someone's
    recon_trace session), because starting this trace would end it; ask the
    user before retrying with force: true.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Tools, Tracer}

    schema do
      field(:module, {:required, :string}, description: "Module, e.g. Elixir.MyApp.Worker or ets")

      field(:function, :string, description: "Function name; omit for all functions")

      field(:max_events, :integer,
        description:
          "Stop after this many events (default 20, max 100); a call and its " <>
            "return or exception are two events"
      )

      field(:duration_ms, :integer,
        description: "Stop after this long regardless (default 10000, max 60000)"
      )

      field(:force, :boolean,
        description:
          "Pre-OTP 27 targets only: trace even though other tracing is active " <>
            "on the node, ending it. Only with the user's explicit permission."
      )
    end

    @impl true
    def execute(%{module: mod} = params, frame) do
      case Tracer.trace(
             mod,
             params[:function],
             max_events(params),
             (params[:duration_ms] || 10_000) |> min(60_000) |> max(100),
             force: params[:force] == true
           ) do
        {:ok, result} ->
          result =
            result
            |> Map.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.put(:stopped_by, stopped_by(result.events, max_events(params)))

          Tools.json_response(frame, result)

        {:error, reason} ->
          Tools.error_response(frame, reason)
      end
    end

    defp max_events(params), do: (params[:max_events] || 20) |> min(100) |> max(1)

    # The events say which limit ended the trace: a call and its return or
    # exception are two events.
    defp stopped_by(events, max) do
      cond do
        Enum.any?(events, &String.starts_with?(&1, "trace stopped early")) -> "overload"
        Enum.any?(events, &(&1 =~ "rate limit tripped")) -> "overload"
        length(events) >= max -> "max_events (a call and its return count as two)"
        true -> "duration"
      end
    end
  end

  defmodule Cluster do
    @moduledoc """
    Look at every node of the current target's cluster at once: the nodes it
    sees, and the nodes those see (or the nodes given). Actions:

    - compare (default): one row of key metrics per node, the nodes that
      stand out from the others, and partitions (members that don't see
      each other)
    - diagnose: the full diagnose on every node, keeping what isn't ok
    - snapshot_take, then snapshot_diff: which node grows

    Nodes are attached with the current target's cookie. To drill into one
    node, connect to it and use the other tools.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.Tools

    schema do
      field(:action, :string,
        description: "compare (default), diagnose, snapshot_take or snapshot_diff"
      )

      field(:nodes, {:list, :string},
        description: "Nodes to include; omit to use the current target's cluster"
      )
    end

    @actions %{
      "compare" => :compare,
      "diagnose" => :diagnose,
      "snapshot_take" => :snapshot_take,
      "snapshot_diff" => :snapshot_diff
    }

    @impl true
    def execute(params, frame) do
      action = params[:action] || "compare"

      with {:ok, fun} <- Map.fetch(@actions, action) |> or_unknown(action),
           {:ok, result} <- apply(OtpDebugMcp.Cluster, fun, [params[:nodes]]) do
        Tools.json_response(frame, result)
      else
        {:error, reason} -> Tools.error_response(frame, reason)
      end
    end

    defp or_unknown(:error, action), do: {:error, {:unknown_action, action, Map.keys(@actions)}}
    defp or_unknown(ok, _action), do: ok
  end

  defmodule Snapshot do
    @moduledoc """
    Capture a system snapshot, or diff against the previous one. Growth over
    time (memory, process count, queue lengths, ETS sizes) is far more
    diagnostic than any point-in-time number: take a snapshot, wait, diff.
    Diffs exclude the atoms and code this tool itself adds to the node.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Snapshotter, Tools}

    schema do
      field(:action, {:required, :string}, description: "\"take\" or \"diff\"")
    end

    @impl true
    def execute(%{action: "take"}, frame) do
      case Snapshotter.take() do
        {:ok, summary} -> Tools.json_response(frame, summary)
        err -> Tools.error_response(frame, err)
      end
    end

    def execute(%{action: "diff"}, frame) do
      case Snapshotter.diff() do
        {:ok, diff} -> Tools.json_response(frame, diff)
        err -> Tools.error_response(frame, err)
      end
    end

    def execute(%{action: other}, frame),
      do: Tools.error_response(frame, {:unknown_action, other})
  end

  defmodule RemoteEval do
    @moduledoc """
    Evaluate an Erlang expression on the target node. POWERFUL AND UNSAFE:
    disabled unless the server was started with OTP_DEBUG_MCP_ALLOW_EVAL=true.
    Prefer the purpose-built tools; use this only when they can't answer.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Checks, Tools}

    schema do
      field(:code, {:required, :string},
        description: "Erlang expression(s), e.g. \"erlang:statistics(run_queue).\""
      )
    end

    @impl true
    def execute(%{code: code}, frame) do
      if System.get_env("OTP_DEBUG_MCP_ALLOW_EVAL") == "true" do
        case Checks.remote_eval(code) do
          {:ok, value} -> Tools.json_response(frame, %{value: erlang_term(value)})
          {:error, reason} -> Tools.error_response(frame, describe_error(reason))
        end
      else
        Tools.error_response(
          frame,
          "remote_eval is disabled; start the server with OTP_DEBUG_MCP_ALLOW_EVAL=true to enable it"
        )
      end
    end

    # The input is Erlang, so answer in Erlang syntax too (depth-limited).
    defp erlang_term(term), do: Format.erlang(~c"~tP", [term, 40])

    defp describe_error({_loc, mod, desc}) when is_atom(mod),
      do: "syntax error: #{mod.format_error(desc)}"

    defp describe_error({:error, {_loc, mod, desc}, _end_loc}) when is_atom(mod),
      do: "syntax error: #{mod.format_error(desc)}"

    defp describe_error({:badrpc, {:EXIT, {reason, _stack}}}),
      do: "evaluation raised: #{erlang_term(reason)}"

    defp describe_error({:badrpc, :timeout}), do: "evaluation timed out after 15s"
    defp describe_error(other), do: Format.inspect(other)
  end
end
