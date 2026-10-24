defmodule PhoenixShopWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_shop

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug PhoenixShopWeb.Router
end
