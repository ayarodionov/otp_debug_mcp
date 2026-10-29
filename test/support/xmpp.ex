defmodule OtpDebugMcp.Xmpp do
  @moduledoc """
  Just enough XMPP for the ejabberd tests: a client that connects,
  upgrades to TLS (ejabberd requires STARTTLS by default), logs in with
  SASL PLAIN, binds a resource and sends its presence; and then, being a
  test, reads nothing more.
  """

  @domain "localhost"

  def connect(port, user, password, recbuf \\ 4096) do
    {:ok, tcp} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, recbuf: recbuf], 5_000)

    open(tcp, &:gen_tcp.send/2)
    until(tcp, &:gen_tcp.recv/3, "</stream:features>")
    :ok = :gen_tcp.send(tcp, "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    until(tcp, &:gen_tcp.recv/3, "<proceed")
    {:ok, tls} = :ssl.connect(tcp, [verify: :verify_none, active: false], 5_000)

    send = &:ssl.send/2
    recv = &:ssl.recv/3
    open(tls, send)
    until(tls, recv, "</stream:features>")
    plain = Base.encode64("\0#{user}\0#{password}")
    send.(tls, "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>#{plain}</auth>")
    until(tls, recv, "<success")
    open(tls, send)
    until(tls, recv, "</stream:features>")

    send.(
      tls,
      "<iq type='set' id='bind'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>test</resource></bind></iq>"
    )

    until(tls, recv, "</iq>")
    :ok = send.(tls, "<presence/>")
    tls
  end

  def close(tls), do: :ssl.close(tls)

  defp open(socket, send) do
    :ok =
      send.(
        socket,
        "<?xml version='1.0'?><stream:stream to='#{@domain}' xmlns='jabber:client' " <>
          "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
      )
  end

  # Reads until `marker`; what follows it in the same read is dropped,
  # which is fine for the steps above, each waiting for a server's reply.
  defp until(socket, recv, marker, acc \\ "") do
    if String.contains?(acc, marker) do
      :ok
    else
      {:ok, data} = recv.(socket, 0, 5_000)
      until(socket, recv, marker, acc <> data)
    end
  end
end
