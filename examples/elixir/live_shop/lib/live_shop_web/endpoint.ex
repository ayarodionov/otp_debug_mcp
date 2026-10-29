defmodule LiveShopWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :live_shop

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Session, store: :cookie, key: "_live_shop", signing_salt: "demo-only")
  plug(LiveShopWeb.Router)
end
