# Elixir book, chapter 2, section 4.1: parsing by catching exceptions.
# A gateway parses the port of each upstream it's asked to connect to.
defmodule Gateway do
  use GenServer

  def start, do: GenServer.start(__MODULE__, nil, name: __MODULE__)

  def parse_port(s) do
    try do
      {:ok, String.to_integer(s)}
    rescue
      ArgumentError -> {:error, :invalid}
    end
  end

  @impl true
  def init(nil) do
    send(self(), :tick)
    {:ok, %{ok: 0, invalid: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 10)
    port = Enum.random(["443", "8080", "80", "8443", "", "http", "80 ", "65536x"])

    case parse_port(port) do
      {:ok, _} -> {:noreply, %{state | ok: state.ok + 1}}
      {:error, :invalid} -> {:noreply, %{state | invalid: state.invalid + 1}}
    end
  end
end
