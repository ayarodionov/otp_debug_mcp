defmodule OtpDebugMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OtpDebugMcp.Target,
      OtpDebugMcp.Snapshotter,
      # stdio transport: Claude Code launches this process and speaks MCP
      # over stdin/stdout. Everything else must log to stderr only.
      # trace_calls may legitimately run for up to 60s.
      {OtpDebugMcp.Server, transport: :stdio, request_timeout: 90_000}
    ]

    opts = [strategy: :one_for_one, name: OtpDebugMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
