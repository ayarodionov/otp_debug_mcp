defmodule LiveShop.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LiveShop.PubSub},
      LiveShopWeb.Endpoint,
      LiveShop.Orders
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LiveShop.Supervisor)
  end

  @doc "The shop's dashboards, simulated (see LiveShop.Dashboards)."
  def traffic, do: LiveShop.Dashboards.start("http://127.0.0.1:4050/")
end
