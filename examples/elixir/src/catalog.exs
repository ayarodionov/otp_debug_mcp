# A healthy node, for checking that an agent can say so: a price catalog
# under steady, modest load, a few hundred lookups and updates a second,
# well within what it can do. Nothing is wrong with it.

Logger.configure(level: :info)

defmodule Catalog.Prices do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def put(sku, price), do: GenServer.cast(__MODULE__, {:put, sku, price})
  def get(sku), do: GenServer.call(__MODULE__, {:get, sku})

  def init(nil) do
    :ets.new(:catalog_prices, [:named_table, read_concurrency: true])
    {:ok, nil}
  end

  def handle_cast({:put, sku, price}, state) do
    :ets.insert(:catalog_prices, {sku, price})
    {:noreply, state}
  end

  def handle_call({:get, sku}, _from, state),
    do: {:reply, :ets.lookup(:catalog_prices, sku), state}
end

defmodule Catalog.Shoppers do
  # Every 10 ms, a short-lived task looks up five prices and updates two,
  # among 500 products.
  def run do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.each(fn i ->
      Task.start(fn ->
        for k <- 0..4, do: Catalog.Prices.get(rem(i * 7 + k, 500))
        for k <- 0..1, do: Catalog.Prices.put(rem(i * 3 + k, 500), rem(i, 1000))
      end)

      Process.sleep(10)
    end)
  end
end

{:ok, _} =
  Supervisor.start_link([Catalog.Prices, {Task, &Catalog.Shoppers.run/0}],
    strategy: :one_for_one,
    name: Catalog.Supervisor
  )
