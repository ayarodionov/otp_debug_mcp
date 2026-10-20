defmodule OtpDebugMcp do
  @moduledoc """
  An MCP server that lets AI agents connect to a running Erlang/Elixir/OTP
  node and debug it.

  `OtpDebugMcp.Target` manages the hidden-node connection,
  `OtpDebugMcp.Checks` holds the diagnostic battery, `OtpDebugMcp.Tracer`
  does safe call tracing, `OtpDebugMcp.Snapshotter` takes snapshot diffs,
  and `OtpDebugMcp.Tools` exposes them all as MCP tools.
  """
end
