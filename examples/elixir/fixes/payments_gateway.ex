# A fix for the payments demo's crash loop, to try on the running node
# with load_module (docs/walkthroughs.md, walkthrough 4). The URL is
# parsed with URI.new/1, which rejects the malformed port instead of
# letting it through to String.to_integer/1. A bad URL is logged, and the
# gateway stays up without a connection instead of crashing every second.
defmodule Payments.Gateway do
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :connect, 1_000)
    {:ok, %{url: System.get_env("GATEWAY_URL", "https://pay.example.com:443x/v2")}}
  end

  def handle_info(:connect, %{url: url} = state) do
    case URI.new(url) do
      {:ok, %URI{host: host, port: port}} when is_binary(host) ->
        {:noreply, Map.merge(state, %{host: host, port: port})}

      # An error, or a URL without a host, such as "foo".
      other ->
        Logger.error("bad GATEWAY_URL #{inspect(url)}: #{inspect(other)}")
        {:noreply, Map.put(state, :error, {:bad_gateway_url, url})}
    end
  end
end
