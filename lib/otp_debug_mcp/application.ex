defmodule OtpDebugMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # load_module's approvals come back in a signed request state, so sign
    # with a key of this run's own.
    unless Application.get_env(:anubis_mcp, :request_state_secret),
      do: Application.put_env(:anubis_mcp, :request_state_secret, :crypto.strong_rand_bytes(32))

    children =
      [OtpDebugMcp.Target, OtpDebugMcp.Snapshotter] ++
        if Application.get_env(:otp_debug_mcp, :mcp_server, true) do
          # stdio transport: Claude Code launches this process and speaks MCP
          # over stdin/stdout. Everything else must log to stderr only.
          # trace_calls may legitimately run for up to 60s.
          [
            {OtpDebugMcp.Server, transport: :stdio, request_timeout: 90_000},
            {OtpDebugMcp.StdinWatcher,
             Anubis.Server.Registry.transport_name(OtpDebugMcp.Server, :stdio)}
          ]
        else
          []
        end

    opts = [strategy: :one_for_one, name: OtpDebugMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
