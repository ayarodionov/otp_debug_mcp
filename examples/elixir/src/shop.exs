# A price cache that can't keep up. Each update takes 5 ms, so it handles
# about 200 a second, while a producer casts tens of thousands a second:
# the cache's mailbox grows without bound, and anything that calls it waits
# behind it.

defmodule Shop.PriceCache do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(s), do: {:ok, s}
  # The bug: slow work for every message, with nothing slowing the sender.
  def handle_cast({:update, sku, price}, s) do
    Process.sleep(5)
    {:noreply, Map.put(s, sku, price)}
  end
end
{:ok, _} = Shop.PriceCache.start_link([])

# Fire-and-forget casts, with a pause every 50.
spawn(fn ->
  Stream.iterate(1, &(&1 + 1)) |> Enum.each(fn i ->
    GenServer.cast(Shop.PriceCache, {:update, rem(i, 1000), i})
    if rem(i, 50) == 0, do: Process.sleep(1)
  end)
end)
