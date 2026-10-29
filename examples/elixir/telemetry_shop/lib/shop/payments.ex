defmodule Shop.Payments do
  @moduledoc "Charges an order: emits [:shop, :payment, :start | :stop]."

  def charge(order) do
    :telemetry.span([:shop, :payment], %{order: order}, fn ->
      Process.sleep(1)
      {:ok, %{order: order}}
    end)
  end
end
