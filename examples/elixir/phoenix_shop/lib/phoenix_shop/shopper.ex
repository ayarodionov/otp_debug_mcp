# A customer that searches the catalog and opens a product every 500 ms,
# over HTTP, and counts the status codes it gets.
defmodule PhoenixShop.Shopper do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def statuses, do: GenServer.call(__MODULE__, :statuses)

  @impl true
  def init(statuses) do
    Process.send_after(self(), :shop, 1_000)
    {:ok, statuses}
  end

  @impl true
  def handle_info(:shop, statuses) do
    statuses =
      for {kind, path} <- [search: ~c"/api/products/search?q=lamp", show: ~c"/api/products/2"],
          reduce: statuses do
        acc -> Map.update(acc, {kind, get(path)}, 1, &(&1 + 1))
      end

    Process.send_after(self(), :shop, 500)
    {:noreply, statuses}
  end

  @impl true
  def handle_call(:statuses, _from, statuses), do: {:reply, statuses, statuses}

  defp get(path) do
    case :httpc.request(:get, {~c"http://127.0.0.1:4040" ++ path, []}, [timeout: 5_000], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> status
      {:error, reason} -> reason
    end
  end
end
