defmodule OtpDebugMcp.Server do
  @moduledoc """
  The MCP server definition. Registers every tool an AI agent can call.

  Tool design philosophy: expose *diagnostic procedures*, not just raw
  primitives. `diagnose` should be the agent's first call; the lower-level
  tools (process_info, trace_calls, remote_eval) are for drilling into what
  `diagnose` surfaces.
  """

  use Anubis.Server,
    name: "otp-debug",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  alias OtpDebugMcp.Tools

  component(Tools.Connect)
  component(Tools.Diagnose)
  component(Tools.RunCheck)
  component(Tools.RecentErrors)
  component(Tools.CrashDump)
  component(Tools.Telemetry)
  component(Tools.Bandit)
  component(Tools.Cowboy)
  component(Tools.Yaws)
  component(Tools.Shackle)
  component(Tools.TelemetryHandlers)
  component(Tools.Mnesia)
  component(Tools.Postgrex)
  component(Tools.HotSpots)
  component(Tools.Benchmark)
  component(Tools.Emqx)
  component(Tools.Ejabberd)
  component(Tools.Ranch)
  component(Tools.Phoenix)
  component(Tools.CallLatency)
  component(Tools.Rabbitmq)
  component(Tools.SocketTuning)
  component(Tools.RiakCore)
  component(Tools.ProcessInfo)
  component(Tools.PortInfo)
  component(Tools.EtsTable)
  component(Tools.SupervisionTree)
  component(Tools.TraceCalls)
  component(Tools.TracePort)
  component(Tools.Profile)
  component(Tools.ModuleCode)
  component(Tools.Cluster)
  component(Tools.Snapshot)
  component(Tools.RemoteEval)
  component(Tools.LoadModule)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  # The playbook, for every client: the Claude Code skill
  # (skills/otp-debug/SKILL.md) has the long form, and only Claude Code
  # reads it. Kept short: a client holds this for the whole session.
  @instructions """
  Tools for debugging a running Erlang/Elixir/OTP node, or a dead one's crash dump.

  Workflow:
  1. connect(node, cookie?) first. A failure's hint is usually right: the cookie, or short against long names. For a node that already died, crash_dump(path) needs no connection.
  2. Then diagnose, always. Its conclusions state each problem once, worst first, from what several checks measured, with the next step; findings are the checks that aren't ok, in full. Report the conclusions before drilling in. On a node already in trouble, diagnose with quick: true reads it without collecting garbage or tracing. If connect reported a cluster, run cluster first: the node that differs is where to look. If nothing is wrong, say so: don't look for a cause the measurements don't show.
  3. Drill into what diagnose named with the purpose-built tool; don't re-scan:
     - a long mailbox, or a process others wait on: process_info, call_latency, then module_code for the code it is in
     - crashes and errors, also ones the numbers don't show: recent_errors; trace_calls with exceptions: true for the calls that raise and their arguments
     - calls that time out or hang: run_check call_chains (deadlocks, chains of calls)
     - CPU: run_check schedulers and scheduler_time (OS CPU% lies about the BEAM), then hot_spots or profile
     - memory: run_check binary_leak, ets_tables (ets_table for one table), allocator_fragmentation, native_memory
     - anything that grows: snapshot take, wait 30-60 s of real load, snapshot diff. One reading is a guess; a diff is evidence
     - slow requests where telemetry exists (Phoenix, Ecto, Oban): telemetry before any tracing
     - a library or server the node runs has its own tool: phoenix, bandit, cowboy, ranch, yaws, postgrex, mnesia, shackle, riak_core, rabbitmq, emqx, ejabberd
  4. A conclusion says only what was measured. Read the code (module_code) before proposing a fix, and say what you didn't verify.

  Safety, since the node may be production:
  - Keep trace_calls small (20 events, 10 s, one module), and never trace gen_server, gen or other hot standard-library modules themselves. Keep profile to one module and a few seconds.
  - When a trace or profile is refused because other tracing is active (nodes before OTP 27), someone may be debugging the node: show the user what was found and ask before force: true. Never set force yourself.
  - process_info with include_state sends the process a message: skip it for one with a huge mailbox.
  - remote_eval only when no other tool can answer and the user has enabled it; nothing that changes state without the user approving that exact expression.
  - load_module only when the user asks to try a fix; it asks them to approve, and the change lasts until the node restarts.
  - If the user declines a step, don't run it again: ask how to go on.
  """

  @impl true
  def server_instructions, do: @instructions
end
