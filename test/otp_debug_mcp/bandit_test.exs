defmodule OtpDebugMcp.BanditTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.WebShop

  # 2 acceptors × 3 connections each, refusing at once when full.
  @small [num_acceptors: 2, num_connections: 3, max_connections_retry_count: 0]

  defp bandit(params), do: call_tool_json(Tools.Bandit, params)

  defp target do
    target = TestTarget.start(bandit: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # The node's console handler would print every crashed request here.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    target
  end

  test "a server's listener, limits and requests by status" do
    target = target()
    port = TestTarget.call(target, WebShop, :start, [@small, 2_000])
    :ok = TestTarget.call(target, WebShop, :clients, [port, 2, "/"])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = bandit(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert [server] = r["servers"]
    assert server["listening"] == "127.0.0.1:#{port}"
    assert server["serves"] == "OtpDebugMcp.Fixtures.WebShop"
    assert server["acceptors"] == 2

    assert %{"limit" => 6, "per_acceptor_limit" => 3, "active" => active} = server["connections"]
    assert active in 1..2
    assert server["timeouts_ms"]["read"] == 60_000

    w = r["window"]
    assert w["requests"] > 10
    assert %{"2xx" => ok} = w["by_status"]
    assert ok == w["requests"]
    assert [%{"route" => "GET / -> 200"}] = w["slowest_routes"]
    assert w["refused_connections"] == 0
  end

  test "connections refused at the limit, and where the busy ones wait" do
    target = target()
    port = TestTarget.call(target, WebShop, :start, [@small, 5_000])
    # 10 clients on a 6-connection server, each holding its connection in /slow.
    :ok = TestTarget.call(target, WebShop, :clients, [port, 10, "/slow"])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = bandit(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    # Worst first.
    assert [first | _] = r["findings"]
    assert first =~ "critical: " and first =~ "connections refused"
    assert r["window"]["refused_connections"] > 0

    assert [server] = r["servers"]
    assert server["connections"]["active"] == 6
    # Without retries an acceptor refuses at once, so none waits.
    assert server["connections"]["acceptors_waiting_for_room"] == 0
    assert server["handling"] == 6
    assert [%{"connections" => 6, "in_your_code" => in_code}] = server["waiting_in"]
    assert in_code == "OtpDebugMcp.Fixtures.WebShop.call/2"
  end

  test "requests that raise" do
    target = target()
    port = TestTarget.call(target, WebShop, :start, [@small, 2_000])
    :ok = TestTarget.call(target, WebShop, :clients, [port, 1, "/boom"])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = bandit(%{duration_ms: 1_000})
    assert %{"raised" => raised} = r["window"]["by_status"]
    assert raised == r["window"]["requests"]
    assert Enum.any?(r["findings"], &(&1 =~ "requests failed"))

    assert [%{"count" => ^raised, "key" => "GET /boom -> nil", "reason" => reason}] =
             r["window"]["exceptions"]

    assert reason =~ "boom"
  end

  test "explains a node without Bandit" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Bandit, %{})
    assert text =~ "no Bandit or Thousand Island server"
  end
end
