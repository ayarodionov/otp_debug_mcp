defmodule OtpDebugMcp.Amqp do
  @moduledoc """
  Just enough AMQP 0-9-1 for the RabbitMQ tests: connect and open a
  channel, declare a queue, publish, consume with or without a
  prefetch limit, and a reader that takes deliveries and never acks
  them.
  """

  def connect(port, user, password) do
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)
    :ok = :gen_tcp.send(s, "AMQP" <> <<0, 0, 9, 1>>)
    expect(s, 0, 10, 10)

    method(
      s,
      0,
      10,
      11,
      longstr("") <> shortstr("PLAIN") <> longstr("\0#{user}\0#{password}") <> shortstr("en_US")
    )

    expect(s, 0, 10, 30)
    method(s, 0, 10, 31, <<16::16, 131_072::32, 0::16>>)
    method(s, 0, 10, 40, shortstr("/") <> shortstr("") <> <<0>>)
    expect(s, 0, 10, 41)
    method(s, 1, 20, 10, shortstr(""))
    expect(s, 1, 20, 11)
    s
  end

  def declare(s, queue) do
    method(s, 1, 50, 10, <<0::16>> <> shortstr(queue) <> <<0>> <> longstr(""))
    expect(s, 1, 50, 11)
  end

  def qos(s, prefetch) do
    method(s, 1, 60, 10, <<0::32, prefetch::16, 0>>)
    expect(s, 1, 60, 11)
  end

  def publish(s, queue, body) do
    method(s, 1, 60, 40, <<0::16>> <> shortstr("") <> shortstr(queue) <> <<0>>)
    frame(s, 2, 1, <<60::16, 0::16, byte_size(body)::64, 0::16>>)
    frame(s, 3, 1, body)
  end

  def consume(s, queue) do
    method(s, 1, 60, 20, <<0::16>> <> shortstr(queue) <> shortstr("") <> <<0>> <> longstr(""))
    expect(s, 1, 60, 21)
  end

  @doc "Read everything the broker sends, acking nothing, until closed."
  def drain(s) do
    case :gen_tcp.recv(s, 0) do
      {:ok, _} -> drain(s)
      _ -> :closed
    end
  end

  defp method(s, channel, class, meth, args),
    do: frame(s, 1, channel, <<class::16, meth::16>> <> args)

  defp frame(s, kind, channel, payload),
    do:
      :ok = :gen_tcp.send(s, <<kind, channel::16, byte_size(payload)::32>> <> payload <> <<0xCE>>)

  # The next method frame on `channel` must be `class`.`meth`; other frames
  # (a delivery's header and body) are skipped.
  defp expect(s, channel, class, meth) do
    {:ok, <<kind, ch::16, size::32>>} = :gen_tcp.recv(s, 7, 5_000)
    {:ok, <<payload::binary-size(size), 0xCE>>} = :gen_tcp.recv(s, size + 1, 5_000)

    case {kind, ch, payload} do
      {1, ^channel, <<^class::16, ^meth::16, _::binary>>} ->
        :ok

      {1, _, <<10::16, 50::16, _::binary>>} ->
        raise "the broker closed the connection: #{inspect(payload)}"

      _ ->
        expect(s, channel, class, meth)
    end
  end

  defp shortstr(s), do: <<byte_size(s)>> <> s
  defp longstr(s), do: <<byte_size(s)::32>> <> s
end
