# An application whose payments gateway parses its port from a malformed
# URL a second after each start, raises, and is restarted by its
# supervisor, about once a second, just under the restart limit (15
# restarts in 10s). Payments fail intermittently and nothing else looks
# wrong.

defmodule Payments.Ledger do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}
end

defmodule Payments.Gateway do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :connect, 1_000)
    {:ok, %{url: System.get_env("GATEWAY_URL", "https://pay.example.com:443x/v2")}}
  end

  def handle_info(:connect, %{url: url} = state) do
    %URI{host: host} = URI.parse(url)
    # The bug: "443x" isn't a port. URI.parse leaves it in the authority.
    [_, port] = Regex.run(~r/:(\w+)\//, url)
    {:noreply, Map.merge(state, %{host: host, port: String.to_integer(port)})}
  end
end

defmodule Payments.Application do
  use Application

  def start(_type, _args) do
    children = [Payments.Ledger, Payments.Gateway]
    opts = [strategy: :one_for_one, max_restarts: 15, max_seconds: 10, name: Payments.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

:ok =
  :application.load(
    {:application, :payments,
     [
       description: ~c"payments demo",
       vsn: ~c"1.0.0",
       modules: [Payments.Application, Payments.Ledger, Payments.Gateway],
       registered: [],
       applications: [:kernel, :stdlib, :elixir],
       mod: {Payments.Application, []}
     ]}
  )

{:ok, _} = Application.ensure_all_started(:payments)
