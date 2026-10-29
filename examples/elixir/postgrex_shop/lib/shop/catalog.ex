defmodule Shop.Catalog do
  @moduledoc "Products and their stock."

  def setup do
    Postgrex.query!(:shop_db, "CREATE TABLE IF NOT EXISTS products (id int PRIMARY KEY, name text, stock int)", [])

    Postgrex.query!(
      :shop_db,
      "INSERT INTO products SELECT i, 'product ' || i, 1000000 FROM generate_series(1, 100) i ON CONFLICT DO NOTHING",
      []
    )

    Postgrex.query!(:shop_db, "CREATE TABLE IF NOT EXISTS orders (id bigserial PRIMARY KEY, product int, quantity int)", [])
    :ok
  end

  @doc "A product's page: one query, a millisecond."
  def show(id) do
    case Postgrex.query(:shop_db, "SELECT name, stock FROM products WHERE id = $1", [id]) do
      {:ok, %{rows: [[name, stock]]}} -> {:ok, %{name: name, stock: stock}}
      {:error, error} -> {:error, error}
    end
  rescue
    error in DBConnection.ConnectionError -> {:error, error}
  end
end
