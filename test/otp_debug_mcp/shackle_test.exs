defmodule OtpDebugMcp.ShackleTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.ShackleShop

  defp shackle(params), do: call_tool_json(Tools.Shackle, params)

  defp target do
    target = TestTarget.start(shackle: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # shackle warns on every reconnect.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    target
  end

  test "a pool, its connections, callers and reply times" do
    target = target()
    port = TestTarget.call(target, ShackleShop, :start, [[pool_size: 4, backlog_size: 32], 0])
    :ok = TestTarget.call(target, ShackleShop, :lookups, [4, 1_000])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = shackle(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert [p] = r["pools"]
    assert p["pool"] == ":shop_pool"
    assert p["client"] == "OtpDebugMcp.Fixtures.ShackleShop"
    assert p["backend"] == "127.0.0.1:#{port}"

    assert %{"pool_size" => 4, "backlog_size" => 32, "max_retries" => 0, "connections_up" => 4} =
             p

    assert length(p["connections"]) == 4

    assert %{} = w = p["window"]
    assert w["replies"] > 50
    # In ms, from shackle's microseconds: a local backend answers in well
    # under 20 ms, but not in none.
    assert w["reply_ms"]["p50"] < 20
    assert w["reply_ms"]["max"] > 0
  end

  test "a slow request holding up one connection" do
    target = target()
    _port = TestTarget.call(target, ShackleShop, :start, [[pool_size: 4, backlog_size: 4], 3_000])
    :ok = TestTarget.call(target, ShackleShop, :slow, [1])
    :ok = TestTarget.call(target, ShackleShop, :lookups, [10, 200])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = shackle(%{duration_ms: 1_500})
    assert r["status"] == "critical"
    assert [p] = r["pools"]
    assert p["window"]["timeout"] > 0
    assert p["window"]["backlog_full"] > 0

    assert Enum.any?(
             r["findings"],
             &(&1 =~ "critical: pool :shop_pool" and &1 =~ "refused with {error, no_server}" and
                 &1 =~ "backlog_size 4 reached")
           )

    assert Enum.any?(r["findings"], &(&1 =~ "timed out"))
    assert Enum.any?(r["findings"], &(&1 =~ "while the others had at most"))
    assert %{"in_flight" => n} = p["held_up"]
    assert n >= 4

    # The callers waiting, by where they called from.
    assert %{"count" => n, "in" => in_code} = r["callers_waiting"]
    assert n > 0
    codes = Enum.map(in_code, & &1["in_your_code"])
    assert "OtpDebugMcp.Fixtures.ShackleShop.slow_call/0" in codes
  end

  test "a backend gone: every connection down" do
    target = target()
    _port = TestTarget.call(target, ShackleShop, :start, [[pool_size: 2], 0])
    :ok = TestTarget.call(target, ShackleShop, :backend_down, [])
    :ok = TestTarget.call(target, ShackleShop, :lookups, [2, 200])
    Process.sleep(300)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = shackle(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    assert [p] = r["pools"]
    assert p["connections_up"] == 0
    assert Enum.sort(p["down_through_window"]) == [1, 2]
    assert [first | _] = r["findings"]
    assert first =~ "none of its 2 connections is up"
  end

  test "explains a node without shackle" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Shackle, %{})
    assert text =~ "shackle isn't running"
  end
end
