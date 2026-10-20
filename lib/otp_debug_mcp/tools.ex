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
          Tools.json_response(frame, %{
            connected: node,
            recon: recon,
            hint: "Run the `diagnose` tool next for a full health check."
          })

        {:error, reason} ->
          Tools.error_response(frame, "#{inspect(reason)}. " <> connect_hints())
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
          "One of: message_queues, supervisor_restarts, binary_leak, memory_breakdown, " <>
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

    alias OtpDebugMcp.{ProcessContext, Target, Tools}

    schema do
      field(:pid, {:required, :string},
        description: "Pid as printed, e.g. <0.123.0>, or a registered name, e.g. MyApp.Worker"
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
        state =
          if params[:include_state] do
            case Target.rpc(:sys, :get_state, [pid, 2_000], 3_000) do
              {:ok, s} ->
                Format.inspect(s, limit: 100, pretty: true)

              {:error, {:badrpc, {:EXIT, {:timeout, _}}}} ->
                "unavailable: the process did not answer sys:get_state within 2s. " <>
                  "This is a symptom, not a tool failure: the process is blocked " <>
                  "or its mailbox is backed up, so system messages wait in line too."

              {:error, e} ->
                "unavailable: #{Format.inspect(e)}"
            end
          end

        Tools.json_response(
          frame,
          Map.merge(context, %{
            pid: pid_str,
            info: Format.inspect(info, limit: :infinity, pretty: true),
            state: state
          })
        )
      else
        err -> Tools.error_response(frame, err)
      end
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
        description: "Stop after this many calls (default 20, max 100)"
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
             (params[:max_events] || 20) |> min(100) |> max(1),
             (params[:duration_ms] || 10_000) |> min(60_000) |> max(100),
             force: params[:force] == true
           ) do
        {:ok, result} ->
          Tools.json_response(frame, Map.reject(result, fn {_k, v} -> is_nil(v) end))

        {:error, reason} ->
          Tools.error_response(frame, reason)
      end
    end
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
