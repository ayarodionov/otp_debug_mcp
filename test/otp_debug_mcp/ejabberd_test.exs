defmodule OtpDebugMcp.EjabberdTest do
  @moduledoc """
  Against a running ejabberd node, given by EJABBERD_NODE and
  EJABBERD_COOKIE, with XMPP clients on EJABBERD_C2S_PORT (default 5222),
  e.g. from Docker:

      docker run -d --name ejabberd -e ERLANG_NODE_ARG=ejabberd@localhost \\
        -e ERLANG_COOKIE=secret -e ERL_DIST_PORT=5210 \\
        -p 5222:5222 -p 5210:5210 ghcr.io/processone/ejabberd:26.09
      EJABBERD_NODE=ejabberd@localhost EJABBERD_COOKIE=secret \\
        ERL_FLAGS="-erl_epmd_port 5210 -dist_listen false" mix test --only ejabberd

  ejabberd listens for distribution on 5210 and runs without epmd, so the
  test VM connects there directly. The tests make their own users.
  """
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, Target, TestTarget, Tools, Xmpp}

  defp port, do: String.to_integer(System.get_env("EJABBERD_C2S_PORT", "5222"))

  defp connect do
    {:ok, _} =
      call_tool_json(Tools.Connect, %{
        node: System.fetch_env!("EJABBERD_NODE"),
        cookie: System.fetch_env!("EJABBERD_COOKIE")
      })
  end

  defp ejabberd(params), do: call_tool_json(Tools.Ejabberd, params)

  defp user(what) do
    name = "otpdbg-#{what}-#{System.unique_integer([:positive])}"
    {:ok, _} = Target.rpc(:ejabberd_admin, :register, [name, "localhost", "secret"])

    on_exit(fn ->
      # A session can outlive its socket (see the slow client's test).
      {:ok, _} =
        Checks.remote_eval(
          ~S"""
          [exit(element(2, element(2, S)), kill)
           || S <- mnesia:dirty_match_object({session, '_', '_', '_', '_', '_'}),
              element(4, S) =:= {U, <<"localhost">>}].
          """,
          U: name
        )

      Target.rpc(:ejabberd_admin, :unregister, [name, "localhost"])
    end)

    name
  end

  # `n` chat messages to `to`, routed inside ejabberd, the way a busy
  # sender's would be, without one's shaper slowing them down. Routing to
  # a user offline stores each message on the way, so it's done in a
  # process of its own.
  defp route(to, n) do
    {:ok, :ok} =
      Checks.remote_eval(
        ~S"""
        Xml = <<"<message xmlns='jabber:client' from='otpdbg-sender@localhost/x' to='",
                To/binary, "@localhost' type='chat'><body>",
                (binary:copy(<<"order confirmed ">>, 16))/binary, "</body></message>">>,
        Pkt = xmpp:decode(fxml_stream:parse_element(Xml)),
        spawn(fun() -> lists:foreach(fun(_) -> ejabberd_router:route(Pkt) end, lists:seq(1, N)) end),
        ok.
        """,
        To: to,
        N: n
      )
  end

  defp wait_until(fun, tries \\ 120) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(500) && wait_until(fun, tries - 1)
    end
  end

  @tag :ejabberd
  test "the server: version, hosts, cluster, sessions" do
    connect()
    name = user("plain")
    client = Xmpp.connect(port(), name, "secret")
    on_exit(fn -> Xmpp.close(client) end)

    assert {:ok, r} = ejabberd(%{duration_ms: 500})
    assert r["version"] =~ ~r/^\d+\./
    assert "localhost" in r["hosts"]
    assert [_ | _] = r["cluster"]["running"]
    assert r["sessions"]["users_online"] >= 1
  end

  @tag :ejabberd
  test "a client that doesn't read: its c2s process backs up" do
    connect()
    name = user("slow")
    client = Xmpp.connect(port(), name, "secret")
    on_exit(fn -> Xmpp.close(client) end)

    # More than the socket's buffers hold, so the c2s process blocks
    # sending and the rest wait in its queue, on its heap.
    route(name, 10_000)
    Process.sleep(1_000)

    assert {:ok, r} = ejabberd(%{duration_ms: 500})

    assert %{"queued" => queued, "mailbox" => mailbox, "socket_open" => true} =
             Enum.find(r["backed_up_clients"] || [], &String.starts_with?(&1["jid"], name <> "@"))

    assert queued + mailbox > 1_000
    assert Enum.any?(r["findings"], &(&1 =~ ~r"client connections? (is|are) backed up"))
  end

  @tag :ejabberd
  test "a user offline: their queue fills, then messages bounce" do
    connect()
    name = user("away")
    route(name, 120)

    wait_until(fn ->
      {:ok, n} = Target.rpc(:mod_offline, :count_offline_messages, [name, "localhost"])
      n >= 100
    end)

    assert {:ok, r} = ejabberd(%{duration_ms: 500})

    assert %{"messages" => 100, "limit" => 100, "full" => true} =
             Enum.find(r["offline"]["most"], &(&1["user"] == name <> "@localhost"))

    assert Enum.any?(r["findings"], &(&1 =~ "bounced back to its sender"))
  end

  test "explains a node without ejabberd" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Ejabberd, %{})
    assert text =~ "doesn't run ejabberd"
  end
end
