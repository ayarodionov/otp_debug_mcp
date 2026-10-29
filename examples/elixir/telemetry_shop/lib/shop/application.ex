defmodule Shop.Application do
  @moduledoc "A shop's checkout, with telemetry on its payments."
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Shop.Supervisor)
  end

  @doc "5 shoppers checking out, one after another."
  def traffic do
    for n <- 1..5, do: spawn(fn -> shopper(n) end)
    :ok
  end

  defp shopper(n) do
    Shop.Checkout.run(%{shopper: n, total: :rand.uniform(100)})
    Process.sleep(100)
    shopper(n)
  end
end
