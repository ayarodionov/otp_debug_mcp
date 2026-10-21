defmodule DemoShop.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: DemoShop.Registry},
      DemoShop.Cache,
      {DynamicSupervisor, name: DemoShop.WorkerSup, strategy: :one_for_one},
      DemoShop.Payments.Supervisor,
      {Task, fn -> for i <- 1..3, do: DynamicSupervisor.start_child(DemoShop.WorkerSup, {DemoShop.Worker, i}) end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DemoShop.Supervisor)
  end
end

defmodule DemoShop.Cache do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{hits: 0}, name: __MODULE__)
  def init(s), do: {:ok, s}
end

defmodule DemoShop.Worker do
  use GenServer, restart: :transient
  def start_link(i), do: GenServer.start_link(__MODULE__, i)
  def init(i), do: {:ok, %{id: i}}
end

defmodule DemoShop.Payments.Supervisor do
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    Supervisor.init([DemoShop.Payments.Gateway, DemoShop.Payments.Ledger], strategy: :one_for_all)
  end
end

defmodule DemoShop.Payments.Gateway do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(s), do: {:ok, s}
end

defmodule DemoShop.Payments.Ledger do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(s), do: {:ok, s}
end
