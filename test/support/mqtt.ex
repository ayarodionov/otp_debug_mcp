defmodule OtpDebugMcp.Mqtt do
  @moduledoc """
  Just enough MQTT 3.1.1 for the EMQX tests: connect, subscribe, publish
  at QoS 1, and a reader that takes what the broker sends and never
  acknowledges it.
  """

  def connect(port, client_id, clean \\ true) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    body =
      string("MQTT") <> <<4, if(clean, do: 0x02, else: 0x00), 60::16>> <> string(client_id)

    :ok = :gen_tcp.send(socket, <<0x10>> <> len(byte_size(body)) <> body)
    {:ok, <<0x20, 2, _, 0>>} = :gen_tcp.recv(socket, 4, 5_000)
    socket
  end

  def subscribe(socket, filter) do
    body = <<1::16>> <> string(filter) <> <<1>>
    :ok = :gen_tcp.send(socket, <<0x82>> <> len(byte_size(body)) <> body)
  end

  def publish(socket, topic, payload, id) do
    body = string(topic) <> <<id::16>> <> payload
    :gen_tcp.send(socket, <<0x32>> <> len(byte_size(body)) <> body)
  end

  @doc "Read everything the broker sends, acknowledging nothing, until closed."
  def drain(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _} -> drain(socket)
      _ -> :closed
    end
  end

  defp string(s), do: <<byte_size(s)::16>> <> s

  defp len(n) when n < 128, do: <<n>>
  defp len(n), do: <<rem(n, 128) + 128>> <> len(div(n, 128))
end
