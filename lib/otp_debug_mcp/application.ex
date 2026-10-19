defmodule OtpDebugMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Hermes.Server.Registry,
      OtpDebugMcp.Target,
      OtpDebugMcp.Snapshotter,
      # stdio transport: Claude Code launches this process and speaks MCP
      # over stdin/stdout. Everything else must log to stderr only.
      {OtpDebugMcp.Server, transport: :stdio}
    ]

    opts = [strategy: :one_for_one, name: OtpDebugMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
