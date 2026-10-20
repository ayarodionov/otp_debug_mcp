defmodule OtpDebugMcp.StdinWatcher do
  @moduledoc """
  Stops the VM with status 0 when the MCP client closes stdin.

  anubis_mcp's stdio transport stops with reason `:normal` at end of
  input, but it's a permanent child, so it would be restarted, read end of
  input again, and so on until the supervisors give up and the release,
  whose application is permanent, halts with status 1. A client closing
  stdin is how a session ends normally, so exit cleanly instead.
  """

  use GenServer
  require Logger

  def start_link(transport), do: GenServer.start_link(__MODULE__, transport, name: __MODULE__)

  @impl true
  def init(transport), do: {:ok, watch(%{transport: transport, ref: nil})}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{ref: ref} = state) do
    Logger.info("client closed stdin, stopping")
    System.stop(0)
    {:noreply, %{state | ref: nil}}
  end

  # Any other exit is a crash, which the supervisors restart; watch the
  # new transport once it's up.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state),
    do: {:noreply, watch(%{state | ref: nil})}

  def handle_info(:watch, state), do: {:noreply, watch(state)}

  defp watch(%{transport: transport} = state) do
    case Process.whereis(transport) do
      nil ->
        Process.send_after(self(), :watch, 100)
        state

      pid ->
        %{state | ref: Process.monitor(pid)}
    end
  end
end
