defmodule OtpDebugMcp.EmqxTest do
  @moduledoc """
  Against a running EMQX 5 node, given by EMQX_NODE and EMQX_COOKIE, with
  MQTT on EMQX_MQTT_PORT (default 1883), e.g. from Docker:

      docker run -d --name emqx -e EMQX_NODE__NAME=emqx@127.0.0.1 \\
        -e EMQX_NODE__COOKIE=secret -p 1883:1883 -p 4370:4370 emqx/emqx:5.8.6
      EMQX_NODE=emqx@127.0.0.1 EMQX_COOKIE=secret \\
        ERL_FLAGS="-erl_epmd_port 4370 -dist_listen false" mix test --only emqx

  EMQX listens for distribution on 4370 and runs without epmd, so the
  test VM connects there directly.
  """
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Mqtt, Target, TestTarget, Tools}

  defp port, do: String.to_integer(System.get_env("EMQX_MQTT_PORT", "1883"))

  defp connect do
    {:ok, _} =
      call_tool_json(Tools.Connect, %{
        node: System.fetch_env!("EMQX_NODE"),
        cookie: System.fetch_env!("EMQX_COOKIE")
      })
  end

  defp emqx(params), do: call_tool_json(Tools.Emqx, params)

  defp id(what), do: "otpdbg-#{what}-#{System.unique_integer([:positive])}"

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(500) && wait_until(fun, tries - 1)
    end
  end

  @tag :emqx
  test "the broker: version, listeners, clients" do
    connect()
    socket = Mqtt.connect(port(), id("plain"))
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:ok, r} = emqx(%{duration_ms: 500})
    assert r["version"] =~ ~r/^5\./
    assert %{"running" => true} = Enum.find(r["listeners"], &(&1["listener"] == "tcp:default"))
    assert r["clients"]["connections"] >= 1
    assert [_ | _] = r["cluster"]["running"]
  end

  @tag :emqx
  test "a client that never acknowledges: in flight, queued, dropped" do
    connect()
    client = id("slow")
    topic = "otpdbg/#{client}"
    reader = Mqtt.connect(port(), client)
    Mqtt.subscribe(reader, "#{topic}/#")
    spawn(fn -> Mqtt.drain(reader) end)
    on_exit(fn -> :gen_tcp.close(reader) end)

    publisher = Mqtt.connect(port(), id("pub"))
    on_exit(fn -> :gen_tcp.close(publisher) end)

    for i <- 1..1_500,
        do: Mqtt.publish(publisher, "#{topic}/t", "reading #{i}", rem(i, 65_000) + 1)

    # EMQX refreshes a channel's stats in its table every so often.
    wait_until(fn ->
      {:ok, rows} =
        Target.rpc(:ets, :select, [:emqx_channel_info, [{{{client, :_}, :_, :"$1"}, [], [:"$1"]}]])

      Enum.any?(rows, &((&1[:mqueue_dropped] || 0) > 0))
    end)

    assert {:ok, r} = emqx(%{duration_ms: 500})

    assert %{"in_flight" => "32 of 32", "dropped" => dropped} =
             Enum.find(r["slow_consumers"], &(&1["client_id"] == client))

    assert dropped > 0
    assert Enum.any?(r["findings"], &(&1 =~ "can't keep up"))
  end

  @tag :emqx
  test "two clients with one client id, kicking each other off" do
    connect()
    client = id("twin")

    twins =
      for _ <- 1..2 do
        spawn(fn -> twin(client) end)
      end

    on_exit(fn -> Enum.each(twins, &Process.exit(&1, :kill)) end)
    Process.sleep(1_000)

    assert {:ok, r} = emqx(%{duration_ms: 2_000})
    assert r["window"]["sessions_discarded_per_s"] + r["window"]["sessions_taken_over_per_s"] >= 1
    assert client in r["reconnecting"]["some"]
    assert Enum.any?(r["findings"], &(&1 =~ "sessions a second taken over or discarded"))
  end

  defp twin(client) do
    try do
      socket = Mqtt.connect(port(), client)
      Mqtt.drain(socket)
    rescue
      _ -> :ok
    end

    Process.sleep(100)
    twin(client)
  end

  test "explains a node without EMQX" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Emqx, %{})
    assert text =~ "doesn't run EMQX"
  end
end
