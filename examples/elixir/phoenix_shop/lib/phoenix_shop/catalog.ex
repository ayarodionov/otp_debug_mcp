defmodule PhoenixShop.Catalog do
  @products [
    %{id: 1, name: "Desk lamp", price: 35},
    %{id: 2, name: "Floor lamp", price: 89},
    %{id: 3, name: "Bookshelf", price: 120}
  ]

  def all, do: @products
  def get(id), do: Enum.find(@products, &(&1.id == id))

  def search(query) do
    q = String.downcase(query)
    Enum.filter(@products, &String.contains?(String.downcase(&1.name), q))
  end
end
