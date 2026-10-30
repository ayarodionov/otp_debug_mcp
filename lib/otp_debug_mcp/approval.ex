defmodule OtpDebugMcp.Approval do
  @moduledoc """
  Asking the user before each step of an investigation.

  With `OTP_DEBUG_MCP_CONFIRM=all`, every tool call shows the user a
  dialog first, through the client (form elicitation): what the step does,
  on which node, with which arguments; it runs only once they accept.
  With `OTP_DEBUG_MCP_CONFIRM=changes`, only the steps that do something
  on the node beyond reading it ask: tracing, profiling, attaching a
  handler, forcing garbage collections, connecting (which may load recon
  there), running code. Unset or `off`, nothing asks (`load_module` always
  does, by itself).

  The answer is bound to the call: the client repeats it with the user's
  answer, and the state the dialog went out with must match the tool and
  arguments. A client that can't ask the user gets an error instead, and
  nothing runs: the setting is the server's, so a client's "always allow"
  can't skip it.

  A tool opts in with `use OtpDebugMcp.Approval` and defines `perform/2` in
  place of `execute/2`.
  """

  alias Anubis.Protocol.Registry
  alias Anubis.Server.{Frame, InputRequired}
  alias OtpDebugMcp.Target

  defmacro __using__(_opts) do
    quote do
      @impl true
      def execute(params, frame), do: OtpDebugMcp.Approval.gate(__MODULE__, params, frame)
    end
  end

  @doc "The setting: `:off`, `:changes` or `:all`."
  def mode do
    case System.get_env("OTP_DEBUG_MCP_CONFIRM", "off") |> String.downcase() do
      "all" -> :all
      "changes" -> :changes
      _ -> :off
    end
  end

  @doc "Run the tool's step, once the user has approved it if they must."
  def gate(tool, params, frame) do
    name = tool_name(tool)
    {effect, what} = step(name, params)

    if asks?(mode(), effect) do
      with :ok <- can_ask(frame) do
        case answer(frame, name, params) do
          :approved -> tool.perform(params, frame)
          :ask -> ask(frame, name, params, what)
          {:declined, how} -> OtpDebugMcp.Tools.error_response(frame, declined(name, how))
        end
      else
        {:error, message} -> OtpDebugMcp.Tools.error_response(frame, message)
      end
    else
      tool.perform(params, frame)
    end
  end

  defp asks?(:all, _effect), do: true
  defp asks?(:changes, :changes), do: true
  defp asks?(_mode, _effect), do: false

  defp tool_name(tool), do: tool |> Module.split() |> List.last() |> Macro.underscore()

  # Same condition as load_module's: only clients of the stateless protocol
  # era (MCP 2026-07-28) can be sent a form mid-call.
  defp can_ask(frame) do
    if Registry.era(frame.context.protocol_version || "") == {:ok, :stateless} and
         Frame.client_supports?(frame, "elicitation") do
      :ok
    else
      {:error,
       "this server asks the user before #{if mode() == :all, do: "every step", else: "each step that changes something on the node"} " <>
         "(OTP_DEBUG_MCP_CONFIRM=#{mode()}), and this MCP client can't ask (form elicitation, " <>
         "MCP 2026-07-28). Nothing was run."}
    end
  end

  defp answer(frame, name, params) do
    case Frame.input_response(frame, "step") do
      %{"action" => "accept"} ->
        if Frame.request_state(frame) == {name, params}, do: :approved, else: :ask

      %{"action" => action} when action in ["decline", "cancel"] ->
        {:declined, action}

      _ ->
        :ask
    end
  end

  defp ask(frame, name, params, what) do
    form = %{"type" => "object", "properties" => %{}}

    input =
      InputRequired.new()
      |> InputRequired.elicit("step", question(name, params, what), form)
      |> InputRequired.state({name, params})

    {:reply, input, frame}
  end

  # The most important first, as clients may show only the first lines.
  defp question(name, params, what) do
    node =
      case Target.connected_node() do
        nil -> ""
        node -> " on #{node}"
      end

    args =
      case params |> Map.drop([:__struct__]) |> Enum.reject(fn {_k, v} -> is_nil(v) end) do
        [] ->
          ""

        list ->
          "\nArguments: " <> Enum.map_join(list, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
      end

    "Run #{name}#{node}?\n#{what}#{args}"
  end

  defp declined(name, how) do
    "The user #{if how == "cancel", do: "dismissed", else: "declined"} this step (#{name}): " <>
      "nothing was run. Don't run it again; ask the user how they'd like to go on."
  end

  # -- What each step does ---------------------------------------------------------

  # {:read, text} for steps that only read the node (or nothing of it),
  # {:changes, text} for those that do something there, if only briefly.
  @doc false
  def step(name, params)

  def step("connect", %{node: node}),
    do:
      {:changes,
       "Connects to #{node} as a hidden node, and loads recon's modules there if it lacks them."}

  def step("diagnose", _),
    do:
      {:changes,
       "Runs every check: reads the node's processes, memory, ports, ETS, logs and code; " <>
         "forces a garbage collection in every process (binary_leak); turns on microstate " <>
         "accounting for 2 s (scheduler_time); watches for long schedules in a trace session for 2 s."}

  def step("run_check", %{check: "binary_leak"}),
    do: {:changes, "Forces a garbage collection in every process, and reads what it frees."}

  def step("run_check", %{check: "scheduler_time"}),
    do: {:changes, "Turns on microstate accounting for 2 s, and reads where scheduler time goes."}

  def step("run_check", %{check: "long_schedules"}),
    do:
      {:changes,
       "Watches for long schedules, long GCs and busy ports for 2 s, in a trace session."}

  def step("run_check", %{check: check}), do: {:read, "Runs the #{check} check: reads the node."}

  def step("process_info", %{include_state: true} = p),
    do: {:changes, "Reads #{p[:pid]}, and asks it for its state (sys:get_state)."}

  def step("process_info", p), do: {:read, "Reads the process #{p[:pid]}."}

  def step("recent_errors", %{stop: true}), do: {:read, "Reads and ends the background watch."}

  def step("recent_errors", %{watch_minutes: m}) when is_integer(m),
    do: {:changes, "Adds a logger handler for #{m} min, catching the node's errors and warnings."}

  def step("recent_errors", _),
    do:
      {:changes,
       "Adds a logger handler for a few seconds, catching the node's errors and warnings, and reads its log files."}

  def step("crash_dump", %{path: path}),
    do: {:read, "Reads the crash dump #{path} on this machine; the node isn't touched."}

  def step("telemetry", %{list: true}), do: {:read, "Lists the telemetry events the node knows."}

  def step("telemetry", _),
    do:
      {:changes,
       "Attaches a telemetry handler to the node's events for the window, then detaches it."}

  def step("bandit", _),
    do:
      {:changes,
       "Reads the node's Bandit servers and connections, and attaches a telemetry handler for the window."}

  def step("cowboy", _),
    do:
      {:changes,
       "Reads the node's Cowboy (Ranch) listeners, connections and requests, and attaches a telemetry handler for the window."}

  def step("phoenix", _),
    do:
      {:read,
       "Reads the Phoenix endpoints, routes, LiveView and channel processes twice, a window apart, listening to Phoenix's telemetry between; the three biggest LiveViews' assigns are read with sys:get_state."}

  def step("ranch", _),
    do:
      {:read,
       "Reads Ranch's listeners and connection processes twice, a window apart, with a log watch for connection crashes meanwhile."}

  def step("rabbitmq", _),
    do:
      {:read, "Reads RabbitMQ's queues, channels, connections and alarms, twice, a window apart."}

  def step("ejabberd", _),
    do:
      {:read,
       "Reads ejabberd's sessions, offline queues, rooms and processes, twice, a window apart."}

  def step("emqx", _),
    do:
      {:read,
       "Reads EMQX's stats, counters, listeners, alarms, rules and channel table, twice, a window apart."}

  def step("hot_spots", _),
    do:
      {:read,
       "Samples the busiest processes' stacks through the window, to find where the CPU goes."}

  def step("benchmark", p),
    do:
      {:changes,
       "Calls #{Enum.join(p[:functions] || [], ", ")} with #{p[:args]} repeatedly, for real, in processes of its own: whatever those functions do, they do, many times."}

  def step("postgrex", %{server: true}),
    do:
      {:changes,
       "Reads the node's Postgrex pools, and opens a connection of its own to the database (with the pool's options) to read pg_stat_activity and lock waits, then closes it."}

  def step("postgrex", _),
    do: {:read, "Reads the node's Postgrex pools: their connections and the callers waiting."}

  def step("mnesia", _),
    do:
      {:changes,
       "Reads Mnesia's tables, locks and transactions, and subscribes to its system events for the window."}

  def step("telemetry_handlers", _),
    do:
      {:changes,
       "Reads the node's telemetry handlers, samples its processes' stacks through the window, and attaches a telemetry handler for the window."}

  def step("shackle", _),
    do:
      {:changes,
       "Reads the node's shackle pools and their connections, and attaches a telemetry handler for the window."}

  def step("yaws", _),
    do: {:read, "Reads the node's Yaws servers, their acceptors and its cookie sessions."}

  def step("riak_core", %{crdts: true}),
    do:
      {:changes,
       "Reads the riak_core ring, vnodes and handoffs, and asks each of this node's vnodes for its state (sys:get_state) to measure the CRDTs it holds."}

  def step("riak_core", _),
    do:
      {:read,
       "Reads the riak_core ring, vnodes and handoffs, here and on the members it reaches."}

  def step("ets_table", %{table: t}),
    do: {:read, "Reads the ETS table #{t}: its settings and some rows."}

  def step("supervision_tree", _), do: {:read, "Reads an application's supervision tree."}
  def step("port_info", %{port: p}), do: {:read, "Reads the port #{p}."}

  def step("module_code", %{module: m}),
    do: {:read, "Reads the module #{m}'s code from the node."}

  def step("snapshot", %{action: a}),
    do: {:read, "#{String.capitalize(to_string(a))}s a snapshot of the node's counts."}

  def step("call_latency", p),
    do:
      {:changes,
       "Traces #{p[:process]}'s messages, replies and callbacks for #{div(p[:duration_ms] || 5_000, 1000)} s: that process is a little slower meanwhile."}

  def step("trace_calls", p),
    do:
      {:changes,
       "Traces calls to #{p[:module] || "every exported function"}#{if p[:function], do: ".#{p[:function]}"}" <>
         "#{if p[:process], do: " made by #{p[:process]}"}: every call is a little slower meanwhile."}

  def step("trace_port", _),
    do: {:changes, "Traces a port's traffic, or ports opening and closing."}

  def step("profile", p),
    do:
      {:changes,
       "Counts calls and time in #{p[:module] || "every module"} for a few seconds: profiled calls are slower meanwhile."}

  def step("cluster", %{action: a}) when a in ["diagnose", "snapshot_take", "snapshot_diff"],
    do: {:changes, "Connects to every node of the cluster, and runs #{a} on each."}

  def step("cluster", _), do: {:changes, "Connects to every node of the cluster to compare them."}

  def step("remote_eval", %{code: code}),
    do: {:changes, "Runs this Erlang code on the node:\n#{String.slice(code, 0, 400)}"}

  def step(name, _), do: {:changes, "Runs #{name}."}
end
