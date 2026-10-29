defmodule OtpDebugMcp.RanchTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.RanchShop

  # 2 acceptors, each with a connection supervisor of 3 connections.
  @small %{num_acceptors: 2, max_connections: 3}

  defp ranch(params), do: call_tool_json(Tools.Ranch, params)

  defp target do
    # Cowboy's applications start Ranch.
    target = TestTarget.start(cowboy: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # The node's console handler would print every crashed connection here.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    target
  end

  defp listener(r), do: Enum.find(r["listeners"], &(&1["listener"] == ":ranch_shop"))

  test "a listener's limits, and what its connections are doing" do
    target = target()
    port = TestTarget.call(target, RanchShop, :start, [@small])
    :ok = TestTarget.call(target, RanchShop, :chatty, [port, 2])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = ranch(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    l = listener(r)
    assert l["listening"] == "127.0.0.1:#{port}"
    assert l["transport"] == ":ranch_tcp"
    assert l["protocol"] == "OtpDebugMcp.Fixtures.RanchShop"
    assert l["acceptors"] == 2

    assert %{"limit" => 6, "max_connections" => 3, "connection_supervisors" => 2, "active" => 2} =
             l["connections"]

    assert [%{"connections" => 2, "in_protocol_code" => code} | _] = l["doing"]
    assert code =~ "OtpDebugMcp.Fixtures.RanchShop."
    refute l["idle_through_window"]
  end

  test "quiet clients held open fill max_connections" do
    target = target()
    port = TestTarget.call(target, RanchShop, :start, [@small])
    # 8 clients for 6 places: 2 wait in the backlog, and both acceptors for room.
    :ok = TestTarget.call(target, RanchShop, :quiet, [port, 8])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = ranch(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    l = listener(r)
    assert l["connections"]["acceptors_waiting_through_window"] == 2

    assert %{"connections" => 6, "of" => 6, "no_bytes_either" => 6, "waiting_in" => [w | _]} =
             l["idle_through_window"]

    assert w["in_protocol_code"] =~ "RanchShop.loop/2"
    assert Enum.any?(r["findings"], &(&1 =~ "acceptors waited for room through the whole window"))
    assert Enum.any?(r["findings"], &(&1 =~ "did nothing through the whole window"))
  end

  test "connection processes that crash, by reason" do
    target = target()
    port = TestTarget.call(target, RanchShop, :start, [@small])
    {:ok, _} = TestTarget.connect(target)
    :ok = TestTarget.call(target, RanchShop, :crashing, [port, 2])

    assert {:ok, r} = ranch(%{duration_ms: 1_500})

    assert %{"connections" => n, "reasons" => [%{"reason" => reason} | _]} =
             listener(r)["crashed_in_window"]

    assert n >= 5
    assert reason =~ "boom"
    assert Enum.any?(r["findings"], &(&1 =~ "connection processes crashed in the window"))
  end

  test "a client that doesn't read what it asked for" do
    target = target()
    port = TestTarget.call(target, RanchShop, :start, [@small])
    :ok = TestTarget.call(target, RanchShop, :unread, [port, 20_000_000])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = ranch(%{duration_ms: 1_000})

    assert %{"connections" => 1, "most" => [%{"bytes_waiting" => bytes}]} =
             listener(r)["slow_readers"]

    assert bytes > 0
    assert Enum.any?(r["findings"], &(&1 =~ "bytes waiting to be sent"))
  end

  test "explains a node without Ranch" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Ranch, %{})
    assert text =~ "Ranch isn't running"
  end
end
