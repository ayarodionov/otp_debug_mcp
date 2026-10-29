defmodule Shop.Checkout do
  @moduledoc """
  A checkout: charges the order, and reports how long the payment took,
  heard from the payment's telemetry.
  """
  require Logger

  def run(order) do
    :ok =
      :telemetry.attach(
        {__MODULE__, make_ref()},
        [:shop, :payment, :stop],
        &__MODULE__.payment_done/4,
        %{checkout: self(), order: order}
      )

    :ok = Shop.Payments.charge(order)

    receive do
      {:payment_ms, ms} -> ms
    after
      1_000 -> :unknown
    end
  end

  # Every checkout's handler hears every payment: only its own counts.
  def payment_done(_event, %{duration: duration}, %{order: order}, %{checkout: pid, order: order}),
    do: send(pid, {:payment_ms, System.convert_time_unit(duration, :native, :millisecond)})

  def payment_done(_event, _measurements, _metadata, _config), do: :ok
end
