import Config

# A LiveView dashboard only: no assets or database.
config :live_shop, LiveShopWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4050],
  server: true,
  secret_key_base: String.duplicate("demo-only-not-a-secret-", 4),
  live_view: [signing_salt: "demo-only"],
  pubsub_server: LiveShop.PubSub

config :phoenix, :json_library, Jason
config :logger, level: :warning
