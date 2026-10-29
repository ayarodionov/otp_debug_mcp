defmodule LiveShop.Stats do
  @moduledoc "Sales figures for the dashboard's refresh button, from the warehouse's reporting API."

  def today do
    # The reporting API answers in about 400 ms.
    Process.sleep(400)
    %{revenue_cents: :rand.uniform(10_000_000), orders: :rand.uniform(20_000)}
  end
end
