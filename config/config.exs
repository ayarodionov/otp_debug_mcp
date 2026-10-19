import Config

# MCP over stdio: stdout carries protocol messages only. Every log line,
# ours and anubis_mcp's, must go to stderr or it corrupts the stream.
config :logger, :default_handler, config: [type: :standard_error]

config :logger, level: :info
