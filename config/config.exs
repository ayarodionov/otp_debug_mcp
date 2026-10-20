import Config

# MCP over stdio: stdout carries protocol messages only. Every log line,
# ours and anubis_mcp's, must go to stderr or it corrupts the stream.
config :logger, :default_handler, config: [type: :standard_error]

config :logger, level: :info

# Tests drive the modules directly; a stdio server would read the test
# runner's stdin.
if config_env() == :test do
  config :otp_debug_mcp, mcp_server: false
  config :logger, level: :warning
end
