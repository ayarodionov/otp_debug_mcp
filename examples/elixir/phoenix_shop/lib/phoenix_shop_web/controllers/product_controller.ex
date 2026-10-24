defmodule PhoenixShopWeb.ProductController do
  use Phoenix.Controller, formats: [:json]

  alias PhoenixShop.Catalog

  def index(conn, _params), do: json(conn, %{products: Catalog.all()})

  def show(conn, %{"id" => id}) do
    with {n, ""} <- Integer.parse(id), %{} = product <- Catalog.get(n) do
      json(conn, %{product: product})
    else
      _ -> conn |> put_status(404) |> json(%{error: "product not found"})
    end
  end

  def search(conn, %{"q" => query}), do: json(conn, %{products: Catalog.search(query)})
end
