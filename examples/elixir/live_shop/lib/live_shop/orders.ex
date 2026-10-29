defmodule LiveShop.Orders do
  @moduledoc """
  The shop's orders as they come in, about 10 a second, each broadcast on
  the "orders" topic for the dashboards.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  @impl true
  def init(n) do
    :timer.send_interval(100, :order)
    {:ok, n}
  end

  @impl true
  def handle_info(:order, n) do
    Phoenix.PubSub.broadcast(LiveShop.PubSub, "orders", {:order, order(n)})
    {:noreply, n + 1}
  end

  defp order(n) do
    %{
      id: n,
      customer: "customer-#{rem(n * 7919, 5000)}",
      placed_at: DateTime.utc_now(),
      lines:
        for i <- 1..(5 + rem(n, 15)) do
          %{
            sku: "SKU-#{rem(n + i * 31, 900)}",
            name: "Product #{rem(n + i, 900)}",
            qty: 1 + rem(i, 3),
            price_cents: 199 + rem(n * i, 9800)
          }
        end
    }
  end
end
