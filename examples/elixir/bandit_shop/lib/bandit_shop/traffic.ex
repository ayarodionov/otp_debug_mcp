defmodule BanditShop.Traffic do
  # Clients, each on its own connection, sending one request after another
  # (HTTP/1.1 keep-alive), and reconnecting when the connection is closed.
  def start(port, opts) do
    for _ <- 1..opts[:recommendations], do: spawn(fn -> client(port, :recommend) end)
    Process.sleep(500)
    for _ <- 1..opts[:browsing], do: spawn(fn -> client(port, :browse) end)
    :ok
  end

  defp client(port, kind) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 10_000) do
      {:ok, socket} -> requests(socket, kind)
      _ -> :ok
    end

    Process.sleep(100)
    client(port, kind)
  end

  defp requests(socket, kind) do
    path = if kind == :browse, do: "/products/#{:rand.uniform(500)}", else: "/recommendations"

    with :ok <- :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: shop\r\n\r\n"),
         {:ok, _} <- :gen_tcp.recv(socket, 0, 10_000) do
      if kind == :browse, do: Process.sleep(200)
      requests(socket, kind)
    else
      _ -> :gen_tcp.close(socket)
    end
  end
end
