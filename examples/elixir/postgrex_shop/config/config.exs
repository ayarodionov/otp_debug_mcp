import Config

# DBConnection logs every checkout it drops; the demo is about finding them.
config :logger, level: :error

# The demo's own PostgreSQL, started by run.sh (trusting local connections).
config :postgrex_shop, :db,
  hostname: "127.0.0.1",
  port: 5544,
  username: "postgres",
  database: "postgres",
  pool_size: 5
