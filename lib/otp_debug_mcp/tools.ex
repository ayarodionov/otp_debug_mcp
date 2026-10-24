defmodule OtpDebugMcp.Tools do
  @moduledoc """
  MCP tool components. Each tool is a thin schema + dispatch layer; the real
  logic lives in `OtpDebugMcp.Checks`, `OtpDebugMcp.Target`,
  `OtpDebugMcp.Tracer` and `OtpDebugMcp.Snapshot`.
  """

  alias Anubis.Server.Response
  alias OtpDebugMcp.{Format, Target}

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

  # Pids arrive as "<0.107.0>", as the target and our tools print them
  # (see OtpDebugMcp.Format), which must be parsed on the target, or in
  # our node's form, "#PID<39943.107.0>" or "<39943.107.0>", from an
  # agent that got one elsewhere, which is already valid locally.
  @doc "A process given as a tool argument: a pid as printed, or a registered name."
  def resolve_process("#PID" <> rest), do: resolve_process(rest)

  def resolve_process("<0." <> _ = pid_str) do
    Target.rpc(:erlang, :list_to_pid, [String.to_charlist(pid_str)])
  end

  def resolve_process("<" <> _ = pid_str) do
    {:ok, :erlang.list_to_pid(String.to_charlist(pid_str))}
  rescue
    ArgumentError -> {:error, {:invalid_pid, pid_str}}
  end

  # A name may come quoted, as Erlang prints atoms like 'log-index'.
  def resolve_process("'" <> quoted) do
    case String.split(quoted, "'") do
      [name, ""] -> resolve_process(name)
      _ -> {:error, {:no_such_process, "'" <> quoted}}
    end
  end

  def resolve_process(name) do
    candidates = [String.to_atom(name), Module.concat([name])]

    Enum.find_value(candidates, {:error, {:no_such_process, name}}, fn atom ->
      case Target.rpc(:erlang, :whereis, [atom]) do
        {:ok, pid} when is_pid(pid) -> {:ok, pid}
        _ -> nil
      end
    end)
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
      with {:ok, pid} <- Tools.resolve_process(pid_str),
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

  defmodule Profile do
    @moduledoc """
    Profile where the time goes, by function: calls, own time and memory
    allocated per function over a short window, from the runtime's
    call_time and call_memory counters (as eprof and tprof use). Give a
    module (and optionally one function), and optionally one process. Run
    it when schedulers are busy or a process is slow, to find which
    functions use the time.

    Counting slows down every profiled call, so keep the scope small on
    production nodes. all_modules profiles every function on the node,
    which is much more expensive: use it only with the user's permission
    there. On OTP 27+ the profile runs in its own isolated trace session and
    never affects other tracing. On older nodes it refuses if other tracing
    is active, because it would end it; ask the user before retrying with
    force: true.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.{Profiler, Tools}

    schema do
      field(:module, :string,
        description:
          "Module to profile, e.g. Elixir.MyApp.Worker or my_worker; required unless all_modules"
      )

      field(:function, :string, description: "Only this function of the module, every arity")

      field(:process, :string,
        description:
          "Only this process's calls: a pid as printed, e.g. <0.123.0>, or a registered " <>
            "name. Default: every process"
      )

      field(:duration_ms, :integer,
        description: "How long to count (default 5000, max 30000, or 10000 with all_modules)"
      )

      field(:all_modules, :boolean,
        description:
          "Every function of every loaded module, instead of one module. Much more " <>
            "expensive: only with the user's explicit permission on production nodes."
      )

      field(:top, :integer, description: "Functions in each ranking (default 15, max 50)")

      field(:force, :boolean,
        description:
          "Pre-OTP 27 targets only: profile even though other tracing is active on " <>
            "the node, ending it. Only with the user's explicit permission."
      )
    end

    @impl true
    def execute(params, frame) do
      all? = params[:all_modules] == true
      max = if all?, do: 10_000, else: 30_000

      with {:ok, scope} <- scope(params[:module], params[:function], all?),
           {:ok, process} <- process(params[:process]),
           {:ok, result} <-
             Profiler.profile(
               scope,
               (params[:duration_ms] || 5_000) |> min(max) |> max(100),
               process: process,
               top: (params[:top] || 15) |> min(50) |> max(1),
               force: params[:force] == true
             ) do
        Tools.json_response(frame, result)
      else
        {:error, reason} -> Tools.error_response(frame, reason)
      end
    end

    defp scope(nil, _function, true), do: {:ok, :all_modules}
    defp scope(nil, _function, false), do: {:error, "give a module, or all_modules: true"}
    defp scope(_module, _function, true), do: {:error, "give a module or all_modules, not both"}
    defp scope(module, function, false), do: {:ok, {:module, module, function}}

    defp process(nil), do: {:ok, nil}
    defp process(name), do: Tools.resolve_process(name)
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

  defmodule ModuleCode do
    @moduledoc """
    What a module on the target really contains, including the functions
    macros generated (use GenServer, routers, schemas, DSLs), which its
    source doesn't show. Without function or at: every function with
    where it came from, written in the module or generated by a macro (and
    which macro, and where it was called). With function: that function's
    code as it runs, after macro expansion. With at: which function a
    stack frame's file:line is in, e.g. gen_server.ex:887 from a crash
    report. Generated functions can then be traced and profiled like any
    other.
    """
    use Anubis.Server.Component, type: :tool

    alias OtpDebugMcp.Tools

    schema do
      field(:module, {:required, :string},
        description: "Module, e.g. Elixir.MyApp.Router, MyApp.Router or my_module"
      )

      field(:function, :string,
        description: "Show this function's code: a name, e.g. handle_call, or name/arity"
      )

      field(:at, :string,
        description: "Find the function a stack frame is in: file:line, e.g. gen_server.ex:887"
      )
    end

    @max_code 20_000

    @impl true
    def execute(%{module: module} = params, frame) do
      with {:ok, info} <- OtpDebugMcp.ModuleCode.fetch(module),
           {:ok, result} <- run(info, params) do
        Tools.json_response(frame, Map.merge(about(info), result))
      else
        {:error, reason} -> Tools.error_response(frame, reason)
      end
    end

    defp run(info, %{function: function}) when is_binary(function) do
      with {:ok, name, arity} <- parse_function(function),
           {:ok, rendered} <- OtpDebugMcp.ModuleCode.code(info, name, arity) do
        {:ok,
         %{
           code:
             for r <- rendered do
               f = Enum.find(info.functions, &(OtpDebugMcp.ModuleCode.label(&1) == r.function))

               r
               |> Map.update!(:code, &cap/1)
               |> Map.put(:origin, OtpDebugMcp.ModuleCode.origin(info, f))
             end
         }}
      end
    end

    defp run(info, %{at: at}) when is_binary(at) do
      case Regex.run(~r/^(.+):(\d+)$/, String.trim(at)) do
        [_, file, line] ->
          case OtpDebugMcp.ModuleCode.at(info, file, String.to_integer(line)) do
            [] ->
              {:error, "no function of #{inspect(info.module)} has code at #{at}"}

            functions ->
              {:ok,
               %{
                 at: at,
                 in:
                   for f <- functions do
                     Map.put(OtpDebugMcp.ModuleCode.origin(info, f), :function, label(f))
                   end
               }}
          end

        nil ->
          {:error, "give at as file:line, e.g. gen_server.ex:887"}
      end
    end

    defp run(info, _params) do
      {compiler, functions} =
        Enum.split_with(info.functions, &compiler?(OtpDebugMcp.ModuleCode.origin(info, &1)))

      listed =
        for f <- functions do
          %{function: label(f), exported: f.exported}
          |> Map.merge(OtpDebugMcp.ModuleCode.origin(info, f))
        end

      result = %{
        functions: listed,
        compiler_generated: Enum.map(compiler, &label/1),
        hint:
          "Call module_code with function: to see a function's code, or with at: file:line " <>
            "to find which function a stack frame is in. Generated functions can be traced " <>
            "and profiled like any other."
      }

      {:ok,
       if info.source == nil do
         Map.put(result, :by_file, by_file(info.functions))
       else
         result
       end}
    end

    defp parse_function(function) do
      case String.split(String.trim(function), "/") do
        [name] ->
          {:ok, name, nil}

        [name, arity] ->
          case Integer.parse(arity) do
            {n, ""} -> {:ok, name, n}
            _ -> {:error, "give function as a name or name/arity, e.g. handle_call/3"}
          end

        _ ->
          {:error, "give function as a name or name/arity, e.g. handle_call/3"}
      end
    end

    defp about(info) do
      %{
        module: label_module(info.module),
        beam_file: info.beam_file,
        disassembled:
          case info.disassembled do
            :here ->
              "here"

            :target ->
              "on the node, whose OTP is newer than this server's"

            :no ->
              "couldn't: the node's OTP is newer than this server's and it has no compiler application, so the functions' lines are unknown"
          end,
        loaded: info.loaded,
        source: info.source || "unknown: the .beam was stripped of its compile info",
        debug_info:
          case info.debug_info do
            :elixir ->
              "elixir: the code after macro expansion, with where each function came from"

            :erlang ->
              "erlang: the abstract code"

            :none ->
              "none: the .beam has no debug info (a release strips it by default), so only the " <>
                "line table says where each function's code is from, and code is BEAM assembly. " <>
                "A function " <>
                "defined in another file than the module's own came from a macro. To keep the " <>
                ~s(code, build the release with strip_beams: [keep: ["Dbgi"]].)
          end
      }
    end

    defp compiler?(%{generated_by: "the compiler" <> _}), do: true
    defp compiler?(%{generated_by: "the Elixir compiler"}), do: true
    defp compiler?(_), do: false

    # Functions by the file they're defined in, when the module's own isn't
    # known: the project's file is the module's, a library's is a macro's.
    defp by_file(functions) do
      functions
      |> Enum.reject(&(&1.lines == []))
      |> Enum.group_by(fn %{lines: [{file, _} | _]} -> file end, &label/1)
    end

    defp label(f), do: OtpDebugMcp.ModuleCode.label(f)

    defp label_module(mod) do
      case Atom.to_string(mod) do
        "Elixir." <> elixir -> elixir
        erlang -> erlang
      end
    end

    defp cap(code) when byte_size(code) > @max_code,
      do: binary_part(code, 0, @max_code) <> "\n… (truncated at #{@max_code} bytes)"

    defp cap(code), do: code
  end

  defmodule LoadModule do
    @moduledoc """
    Load a fixed module onto the target, replacing the version it runs, to
    try a fix on the live node; or revert one. The user is asked to approve
    every load, in a dialog from their MCP client: this tool can't load
    anything without that. The node's files aren't changed, so the new code
    lasts until the node restarts. Compile the fix first (mix compile,
    rebar3 compile, erlc) and pass the .beam file.
    """
    use Anubis.Server.Component,
      type: :tool,
      annotations: %{"readOnlyHint" => false, "destructiveHint" => true}

    require Logger

    alias Anubis.Protocol.Registry
    alias Anubis.Server.{Frame, InputRequired}
    alias OtpDebugMcp.{CodeLoad, Format, Target, Tools, Tracer}

    schema do
      field(:path, :string,
        description:
          "Absolute path of the fixed module's .beam file on the machine running this server, " <>
            "compiled by the target's OTP major version or an older one"
      )

      field(:revert, :string,
        description:
          "Instead of path: a module to reload from the node's own code path, " <>
            "undoing an earlier load, e.g. Elixir.MyApp.Worker or my_worker"
      )
    end

    @impl true
    def execute(params, frame) do
      with :ok <- can_ask(frame),
           {:ok, target} <- Target.target(),
           {:ok, change} <- change(params),
           {:ok, plan} <- CodeLoad.plan(change.module),
           {:ok, change} <- complete(change, plan) do
        case approval(frame, target, change) do
          :approved -> load(frame, target, change, plan)
          :ask -> ask(frame, target, change, plan)
          {:declined, how} -> Tools.error_response(frame, declined(change, how))
        end
      else
        {:done, result} -> Tools.json_response(frame, result)
        {:error, reason} -> Tools.error_response(frame, reason)
      end
    end

    # The approval is the user's answer to a form the client shows them,
    # which only clients of the stateless protocol era (MCP 2026-07-28) can
    # be sent mid-call. Without one there's no way to ask, so no loading.
    defp can_ask(frame) do
      if Registry.era(frame.context.protocol_version || "") == {:ok, :stateless} and
           Frame.client_supports?(frame, "elicitation") do
        :ok
      else
        {:error,
         "load_module needs an MCP client that can ask the user to approve each load " <>
           "(form elicitation, MCP 2026-07-28), and this one can't. Nothing was loaded."}
      end
    end

    defp change(%{path: path}) when is_binary(path) do
      with {:ok, beam} <- CodeLoad.read_beam(path) do
        {:ok,
         %{module: beam.module, md5: beam.md5, source: {beam.file, beam.binary}, file: beam.file}}
      end
    end

    defp change(%{revert: mod}) when is_binary(mod),
      do: {:ok, %{module: mod |> String.trim("'") |> Tracer.resolve_module(), source: :on_disk}}

    defp change(_), do: {:error, "give either path (a .beam file to load) or revert (a module)"}

    defp complete(%{module: mod}, %{sticky: true}) do
      {:error,
       "#{name(mod)} is one of OTP's own modules (in a sticky directory); " <>
         "this tool doesn't replace those"}
    end

    defp complete(%{source: :on_disk} = change, plan) do
      case plan do
        %{on_disk: :none} ->
          {:error,
           "#{name(change.module)} isn't on the node's code path, so there's no version to revert to"}

        %{on_disk: {_file, md5}, loaded: {_, md5}} ->
          {:done,
           %{
             module: name(change.module),
             unchanged: "the node already runs the version on its code path"
           }}

        %{on_disk: {file, md5}} ->
          {:ok, Map.merge(change, %{md5: md5, file: to_string(file)})}
      end
    end

    defp complete(%{md5: md5} = change, %{loaded: {_, md5}}),
      do:
        {:done,
         %{module: name(change.module), unchanged: "the node already runs this code (same md5)"}}

    defp complete(change, _plan), do: {:ok, change}

    # Approved means the user accepted a form for this very code on this
    # node: the state the form went out with says which, signed and bound
    # to this call's arguments. If the file has changed since, ask again.
    defp approval(frame, target, change) do
      case Frame.input_response(frame, "approve") do
        %{"action" => "accept", "content" => %{"load" => true}} ->
          if Frame.request_state(frame) == {target, change.module, change.md5},
            do: :approved,
            else: :ask

        %{"action" => "accept"} ->
          {:declined, "accepted without ticking the box"}

        %{"action" => action} when action in ["decline", "cancel"] ->
          {:declined, action}

        _ ->
          :ask
      end
    end

    defp ask(frame, target, change, plan) do
      form = %{
        "type" => "object",
        "properties" => %{
          "load" => %{
            "type" => "boolean",
            "title" => if(change.source == :on_disk, do: "Revert it", else: "Load it"),
            "description" => "Every process at once, until the node restarts"
          }
        },
        "required" => ["load"]
      }

      input =
        InputRequired.new()
        |> InputRequired.elicit("approve", question(target, change, plan), form)
        |> InputRequired.state({target, change.module, change.md5})

      {:reply, input, frame}
    end

    # Clients show only the first lines of the message, and may cut long
    # ones short: so the most important facts first, one per line, each
    # md5 before its path.
    defp question(target, change, plan) do
      {verb, label} =
        if change.source == :on_disk,
          do: {"Revert", "Back to"},
          else: {"Load new code for", "New code"}

      now =
        case plan.loaded do
          :not_loaded -> "not loaded on the node"
          {file, md5} -> "md5 #{CodeLoad.hex(md5)}, #{CodeLoad.file_name(file)}"
        end

      running =
        case plan.running do
          {0, _} -> ""
          {1, _} -> "\n1 process is executing it right now."
          {n, _} -> "\n#{n} processes are executing it right now."
        end

      """
      #{verb} #{name(change.module)} on #{target}?
      #{label}: md5 #{CodeLoad.hex(change.md5)}, #{change.file}
      Running now: #{now}#{running}\
      """
    end

    defp load(frame, target, change, plan) do
      case CodeLoad.load(change.module, change.source, change.md5) do
        {:ok, %{file: file, old_code_users: {n, pids}}} ->
          Logger.notice(
            "load_module: approved by the user, loaded #{name(change.module)} " <>
              "(md5 #{CodeLoad.hex(change.md5)}, #{file}) on #{target}"
          )

          Tools.json_response(
            frame,
            %{
              loaded: name(change.module),
              node: target,
              file: file,
              md5: CodeLoad.hex(change.md5),
              replaced: replaced(plan.loaded),
              lasts: lasts(change, plan),
              still_on_old_code: old_code(n, pids),
              hint: "Check the fix: run diagnose, or trace_calls on the fixed function."
            }
            |> Map.reject(fn {_k, v} -> is_nil(v) end)
          )

        {:error, reason} ->
          Tools.error_response(frame, failed(change, reason, plan))
      end
    end

    defp replaced(:not_loaded), do: nil
    defp replaced({file, md5}), do: %{file: CodeLoad.file_name(file), md5: CodeLoad.hex(md5)}

    defp lasts(%{source: :on_disk}, _plan), do: "this is the node's own version again"

    defp lasts(change, %{on_disk: :none}) do
      "until the node restarts: its files aren't changed. The node has no " <>
        "#{name(change.module)} on its code path, so revert can't undo it; a restart does."
    end

    defp lasts(change, _plan) do
      "until the node restarts: its files aren't changed. " <>
        "load_module with revert: #{name(change.module)} undoes it."
    end

    defp old_code(0, _pids), do: nil

    defp old_code(n, pids) do
      %{
        processes: n,
        pids: Enum.map(pids, &Format.inspect/1),
        why:
          "they're in a function of the old version and switch only on their next fully " <>
            "qualified call (Module:function); until then, another load of this module is refused"
      }
    end

    defp declined(change, how) do
      "The user didn't approve (#{how}), so #{name(change.module)} wasn't loaded. " <>
        "Don't ask again unless the user asks for it."
    end

    defp failed(change, {:old_code_in_use, pids}, _plan) do
      "Processes still run code from an earlier load of #{name(change.module)} " <>
        "(#{Enum.map_join(pids, ", ", &Format.inspect/1)}), and loading again would kill them. " <>
        "They switch on their next fully qualified call. Nothing was loaded."
    end

    defp failed(change, :changed, _plan),
      do:
        "#{name(change.module)}'s code changed after the user approved it, so nothing was loaded."

    defp failed(change, :not_on_code_path, _plan),
      do: "#{name(change.module)} is no longer on the node's code path, so nothing was loaded."

    defp failed(_change, :sticky, _plan),
      do: "The module is in a sticky directory, so nothing was loaded."

    defp failed(_change, :badfile, plan) do
      "The node (OTP #{plan.otp_release}) rejected the file, usually because a newer OTP " <>
        "compiled it. Nothing was loaded."
    end

    defp failed(_change, :on_load_failure, _plan),
      do: "The module's -on_load function failed, so the node kept the version it had."

    defp failed(_change, reason, _plan), do: "Loading failed: #{Format.inspect(reason)}"

    defp name(mod) do
      case Atom.to_string(mod) do
        "Elixir." <> elixir -> elixir
        erlang -> erlang
      end
    end
  end
end
