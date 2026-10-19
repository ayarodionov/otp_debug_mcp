defmodule Shop.PriceCache do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(s), do: {:ok, s}
  # Bug: every update does slow "work" while callers cast faster than it can drain.
  def handle_cast({:update, sku, price}, s) do
    Process.sleep(5)
    {:noreply, Map.put(s, sku, price)}
  end
end
{:ok, _} = Shop.PriceCache.start_link([])
spawn(fn ->
  Stream.iterate(1, &(&1 + 1)) |> Enum.each(fn i ->
    GenServer.cast(Shop.PriceCache, {:update, rem(i, 1000), i})
    if rem(i, 50) == 0, do: Process.sleep(1)
  end)
end)
