defmodule LiveShopWeb.OrdersLive do
  @moduledoc "The orders dashboard: today's figures, and the latest orders as they come in."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(LiveShop.PubSub, "orders")
    {:ok, assign(socket, orders: [], stats: nil)}
  end

  @impl true
  def handle_info({:order, order}, socket) do
    {:noreply, assign(socket, orders: [order | socket.assigns.orders])}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, stats: LiveShop.Stats.today())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Orders</h1>
    <p :if={@stats}>Today: {@stats.orders} orders, {@stats.revenue_cents} cents</p>
    <button phx-click="refresh">Refresh</button>
    <p>{length(@orders)} orders since you opened this page</p>
    <ul>
      <li :for={order <- Enum.take(@orders, 10)}>#{order.id} {order.customer}: {length(order.lines)} lines</li>
    </ul>
    """
  end
end
