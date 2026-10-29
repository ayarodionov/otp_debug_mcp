defmodule Shop.Payments do
  @moduledoc "The payment provider: an HTTP call, about 300 ms."

  def charge(_order) do
    Process.sleep(300)
    :ok
  end
end
