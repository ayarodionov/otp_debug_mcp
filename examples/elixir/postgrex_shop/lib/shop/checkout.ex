defmodule Shop.Checkout do
  @moduledoc "An order: the stock taken, the card charged, the order recorded, together."

  def place(%{product: product, quantity: quantity} = order) do
    Postgrex.transaction(:shop_db, fn conn ->
      Postgrex.query!(conn, "UPDATE products SET stock = stock - $1 WHERE id = $2", [quantity, product])
      :ok = Shop.Payments.charge(order)
      Postgrex.query!(conn, "INSERT INTO orders (product, quantity) VALUES ($1, $2)", [product, quantity])
    end)
  rescue
    error in DBConnection.ConnectionError -> {:error, error}
  end
end
