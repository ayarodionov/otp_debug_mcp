# Elixir book, chapter 13, section 4.4: a handler that raises once and disappears.
defmodule Metrics do
  def setup do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    :ok = :telemetry.attach("db-metrics", [:repo, :query], &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:repo, :query], %{total_time: t}, %{source: source}, _) do
    observe("db.query", t, table: String.to_existing_atom(source))
  end

  def observe(name, value, table: table) do
    :ets.update_counter(__MODULE__, {name, table}, [{2, 1}, {3, value}], {{name, table}, 0, 0})
  end
end

defmodule Repo do
  # Queries on two tables, ten a second; a nightly report runs a raw SQL
  # query, with no :source, about 30 seconds after start.
  def start do
    Metrics.setup()
    spawn(fn -> queries(0) end)
    :ok
  end

  defp queries(n) do
    source = Enum.random(["orders", "users"])
    _ = String.to_atom(source)

    :telemetry.execute([:repo, :query], %{total_time: :rand.uniform(5_000)}, %{source: source})

    if n == 300 do
      :telemetry.execute([:repo, :query], %{total_time: 90_000}, %{query: "SELECT sum(total) FROM orders"})
    end

    Process.sleep(100)
    queries(n + 1)
  end
end
