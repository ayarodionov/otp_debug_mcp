defmodule BanditShop.Application do
  # A shop API on Bandit, and the traffic it gets: 120 clients browsing
  # products on keep-alive connections, and 30 asking for recommendations,
  # each of which waits 3 seconds on a slow upstream.
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:bandit_shop, :port)

    children = [
      {Bandit,
       plug: BanditShop.Router,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false,
       thousand_island_options: Application.fetch_env!(:bandit_shop, :thousand_island_options)},
      {Task, fn -> BanditShop.Traffic.start(port, browsing: 120, recommendations: 30) end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BanditShop.Supervisor)
  end
end
