# A billing service whose routes are defined with a small macro DSL,
# Billing.Router. Every charge is recorded twice in the ledger, and the bug
# is in code a macro generates, so it isn't in any route's source. run.sh
# compiles this file to .beam files rather than running it as a script, so
# module_code can read the code after macro expansion.

defmodule Billing.Router do
  @moduledoc """
  A tiny routing DSL. `route/2` defines a clause of `handle/2`, and
  `timed/2` runs a block, logging it if it's slow.
  """

  defmacro __using__(_opts) do
    quote do
      import Billing.Router
      @before_compile Billing.Router
    end
  end

  defmacro route(path, do: body) do
    quote do
      def handle(unquote(path), var!(req)), do: unquote(body)
    end
  end

  defmacro timed(label, do: block) do
    quote do
      {micros, _} = :timer.tc(fn -> unquote(block) end)
      if micros > 50_000, do: IO.puts(:stderr, "#{unquote(label)} took #{micros} us")
      # The bug: the block runs again, to return its result.
      unquote(block)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle(_path, _req), do: {:error, :not_found}
    end
  end
end

defmodule Billing.API do
  use Billing.Router

  route "/charge" do
    timed "charge" do
      Billing.Ledger.record(req.account, req.amount)
    end
  end

  route "/balance" do
    Billing.Ledger.balance(req.account)
  end
end

defmodule Billing.Ledger do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def record(account, amount), do: GenServer.call(__MODULE__, {:record, account, amount})
  def balance(account), do: GenServer.call(__MODULE__, {:balance, account})

  @impl true
  def init(entries), do: {:ok, entries}

  @impl true
  def handle_call({:record, account, amount}, _from, entries),
    do: {:reply, :ok, Map.update(entries, account, [amount], &[amount | &1])}

  def handle_call({:balance, account}, _from, entries),
    do: {:reply, entries |> Map.get(account, []) |> Enum.sum(), entries}
end

# Charges acme 10 every 200 ms through the API, and counts what it charged.
defmodule Billing.Client do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def charged, do: GenServer.call(__MODULE__, :charged)

  @impl true
  def init(charged) do
    Process.send_after(self(), :charge, 200)
    {:ok, charged}
  end

  @impl true
  def handle_info(:charge, charged) do
    :ok = Billing.API.handle("/charge", %{account: "acme", amount: 10})
    Process.send_after(self(), :charge, 200)
    {:noreply, charged + 10}
  end

  @impl true
  def handle_call(:charged, _from, charged), do: {:reply, charged, charged}
end

defmodule Billing do
  # Started from `elixir -e`, whose process exits when the expression
  # returns: unlinked, so the supervisor outlives it.
  def start do
    {:ok, sup} =
      Supervisor.start_link([Billing.Ledger, Billing.Client],
        strategy: :one_for_one,
        name: Billing.Supervisor
      )

    Process.unlink(sup)
    {:ok, sup}
  end
end
