defmodule LiveShopWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/", LiveShopWeb do
    pipe_through(:browser)
    live("/", OrdersLive)
  end
end
