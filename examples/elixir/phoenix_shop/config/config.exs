import Config

# A JSON API only: no HTML, assets or database.
config :phoenix_shop, PhoenixShopWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  server: true,
  secret_key_base: String.duplicate("demo-only-not-a-secret-", 4),
  render_errors: [formats: [json: PhoenixShopWeb.ErrorJSON], layout: false]

config :phoenix, :json_library, Jason
config :logger, level: :warning
