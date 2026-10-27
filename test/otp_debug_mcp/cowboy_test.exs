defmodule OtpDebugMcp.CowboyTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.CowboyShop

  # 2 acceptors, each with a connection supervisor of 3 connections.
  @small %{num_acceptors: 2, max_connections: 3}

  defp cowboy(params), do: call_tool_json(Tools.Cowboy, params)

  defp target do
    target = TestTarget.start(cowboy: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # The node's console handler would print every crashed request here.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    target
  end

  test "a listener's limits, routes, and requests by status" do
    target = target()
    port = TestTarget.call(target, CowboyShop, :start, [@small, 2_000])
    :ok = TestTarget.call(target, CowboyShop, :clients, [port, 2, "/"])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = cowboy(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert [l] = r["listeners"]
    assert l["listener"] == ":cowboy_shop"
    assert l["listening"] == "127.0.0.1:#{port}"
    assert l["acceptors"] == 2
    assert l["telemetry"] == "cowboy_telemetry_h"
    assert l["routes"] == ["*/... -> OtpDebugMcp.Fixtures.CowboyShop"]

    assert %{
             "limit" => 6,
             "max_connections" => 3,
             "connection_supervisors" => 2,
             "active" => active
           } =
             l["connections"]

    assert active in 1..2
    assert l["accepted_per_s"] >= 0
    assert l["timeouts_ms"] == %{"idle" => 60_000, "request" => 5_000, "handshake" => 5_000}

    w = r["window"]
    assert w["requests"] > 5
    assert %{"2xx" => ok} = w["by_status"]
    assert ok == w["requests"]
    assert [%{"route" => "GET / -> 200"}] = w["slowest_routes"]
  end

  test "acceptors blocked at max_connections, and requests running through the window" do
    target = target()
    port = TestTarget.call(target, CowboyShop, :start, [@small, 5_000])
    # 10 clients on 6 connections, each request taking 5 s.
    :ok = TestTarget.call(target, CowboyShop, :clients, [port, 10, "/slow"])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = cowboy(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    assert [first | _] = r["findings"]
    assert first =~ "critical: :cowboy_shop"
    assert first =~ "acceptors waited the whole"
    assert first =~ "3 per connection supervisor, 2 supervisors, 6 connections active"

    assert [l] = r["listeners"]
    assert %{"active" => 6, "acceptors_waiting_through_window" => 2} = l["connections"]
    assert l["requests_in_flight"] == 6

    assert %{"requests" => 6, "in" => [%{"in_your_code" => code} | _]} =
             l["running_through_window"]

    assert code == "OtpDebugMcp.Fixtures.CowboyShop.init/2"
    assert Enum.any?(r["findings"], &(&1 =~ "6 requests ran through the whole"))
  end

  test "handler crashes" do
    target = target()
    port = TestTarget.call(target, CowboyShop, :start, [@small, 0])
    :ok = TestTarget.call(target, CowboyShop, :clients, [port, 2, "/boom"])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = cowboy(%{duration_ms: 1_000})
    assert r["status"] == "warning"
    assert %{"raised" => raised} = r["window"]["by_status"]
    assert raised > 0
    assert [%{"kind" => _, "reason" => reason} | _] = r["window"]["exceptions"]
    assert reason =~ "boom"
    assert Enum.any?(r["findings"], &(&1 =~ "requests failed"))
  end

  test "explains a node without Ranch" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Cowboy, %{})
    assert text =~ "Ranch isn't running"
  end
end
