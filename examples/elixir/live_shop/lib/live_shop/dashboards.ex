defmodule LiveShop.Dashboards do
  @moduledoc """
  The shop's staff, simulated: 15 people with the orders dashboard open
  in a browser tab all day, 3 of whom press Refresh every second or so.
  """
  alias LiveShop.LiveClient

  def start(url) do
    for i <- 1..15, do: spawn(fn -> tab(url, rem(i, 5) == 0) end)
    :ok
  end

  defp tab(url, clicker?) do
    try do
      client = LiveClient.open(url)
      :ok = LiveClient.active(client)
      :timer.send_interval(1_000, :tick)
      watch(client, clicker?, 0)
    catch
      _, _ -> :ok
    end

    Process.sleep(1_000)
    tab(url, clicker?)
  end

  # What the server sends is dropped, as a browser would after rendering it.
  defp watch(client, clicker?, ticks) do
    receive do
      {:tcp, _, _} ->
        watch(client, clicker?, ticks)

      {:tcp_closed, _} ->
        :closed

      :tick ->
        client = if clicker?, do: LiveClient.click(client, "refresh"), else: client
        client = if rem(ticks, 20) == 19, do: LiveClient.heartbeat(client), else: client
        watch(client, clicker?, ticks + 1)
    end
  end
end
