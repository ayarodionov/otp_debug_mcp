defmodule Shop.Application do
  @moduledoc "A shop on PostgreSQL, through a Postgrex pool, :shop_db."
  use Application

  @impl true
  def start(_type, _args) do
    db = Application.fetch_env!(:postgrex_shop, :db)
    children = [{Postgrex, db ++ [name: :shop_db]}]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: Shop.Supervisor)
    Shop.Catalog.setup()
    {:ok, sup}
  end

  @doc "8 buyers checking out, and 20 shoppers browsing products."
  def traffic do
    for _ <- 1..8, do: spawn(fn -> buyer() end)
    for _ <- 1..20, do: spawn(fn -> browser() end)
    :ok
  end

  defp buyer do
    Shop.Checkout.place(%{product: Enum.random([1, 1, 1, 2, 3]), quantity: 1})
    Process.sleep(100)
    buyer()
  end

  defp browser do
    Shop.Catalog.show(:rand.uniform(100))
    Process.sleep(50)
    browser()
  end
end
