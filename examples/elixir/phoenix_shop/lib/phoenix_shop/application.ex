defmodule PhoenixShop.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [PhoenixShopWeb.Endpoint, PhoenixShop.Shopper]
    Supervisor.start_link(children, strategy: :one_for_one, name: PhoenixShop.Supervisor)
  end
end
