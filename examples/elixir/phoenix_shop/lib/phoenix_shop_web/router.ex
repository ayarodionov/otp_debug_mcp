defmodule PhoenixShopWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PhoenixShopWeb do
    pipe_through :api

    resources "/products", ProductController, only: [:index, :show]
    get "/products/search", ProductController, :search
  end
end
