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
  component(Tools.ProcessInfo)
  component(Tools.PortInfo)
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
end
