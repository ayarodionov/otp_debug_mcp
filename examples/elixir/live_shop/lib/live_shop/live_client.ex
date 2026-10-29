defmodule LiveShop.LiveClient do
  @moduledoc """
  Just enough of a browser for a LiveView: the page over HTTP, then the
  LiveView socket over a WebSocket of its own (Phoenix's V2 protocol,
  JSON). `open/1` joins the page's LiveView; `click/2` sends a
  `phx-click` event; `heartbeat/1` keeps the socket alive. What the
  server sends arrives as `{:tcp, socket, data}` messages, to be read or
  dropped.
  """

  defstruct [:socket, :topic, ref: 1]

  def open(url) do
    %URI{host: host, port: port} = URI.parse(url)

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    [_, id] = Regex.run(~r/id="(phx-[^"]+)"/, body)
    [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, body)
    [_, static] = Regex.run(~r/data-phx-static="([^"]*)"/, body)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(
        socket,
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nhost: #{host}\r\nupgrade: websocket\r\n" <>
          "connection: Upgrade\r\nsec-websocket-key: #{key}\r\nsec-websocket-version: 13\r\n\r\n"
      )

    {:ok, "HTTP/1.1 101" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    client = %__MODULE__{socket: socket, topic: "lv:" <> id}

    push(client, "phx_join", %{
      url: url,
      session: session,
      static: static,
      params: %{"_mounts" => 0}
    })
  end

  def click(client, event), do: push(client, "event", %{type: "click", event: event, value: %{}})

  def heartbeat(client) do
    send_frame(client.socket, Jason.encode!([nil, "#{client.ref}", "phoenix", "heartbeat", %{}]))
    %{client | ref: client.ref + 1}
  end

  def active(client), do: :inet.setopts(client.socket, active: true)

  defp push(client, event, payload) do
    send_frame(client.socket, Jason.encode!(["1", "#{client.ref}", client.topic, event, payload]))
    %{client | ref: client.ref + 1}
  end

  # A text frame, masked, as a client's must be.
  defp send_frame(socket, text) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(text)

    len =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :ok = :gen_tcp.send(socket, [<<0x81>>, len, mask, masked(text, mask)])
  end

  defp masked(text, <<a, b, c, d>>) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(text)), into: <<>> do
      <<Bitwise.bxor(byte, elem({a, b, c, d}, rem(i, 4)))>>
    end
  end
end
