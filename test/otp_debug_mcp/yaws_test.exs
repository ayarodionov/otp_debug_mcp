defmodule OtpDebugMcp.YawsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.YawsShop

  defp yaws(params), do: call_tool_json(Tools.Yaws, params)

  defp target do
    target = TestTarget.start(yaws: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # The node's console handler would print every crashed request here.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    target
  end

  test "a server, its virtual servers, and its acceptors" do
    target = target()
    port = TestTarget.call(target, YawsShop, :start, [[max_connections: 10], 0])
    :ok = TestTarget.call(target, YawsShop, :clients, [port, 2, "/"])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = yaws(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert r["findings"] == []
    assert [s] = r["servers"]
    assert s["listening"] == "127.0.0.1:#{port}"

    assert [%{"name" => name, "appmods" => ["/ -> OtpDebugMcp.Fixtures.YawsShop"]}] =
             s["virtual_servers"]

    assert name == "shop:#{port}"
    assert %{"max_connections" => 10, "open" => open} = s["connections"]
    assert open in 1..3
    assert s["acceptors"]["accepting"] == 1
    assert r["config"]["keepalive_timeout"] == 30_000
  end

  test "at max_connections, and requests running through the window" do
    target = target()
    port = TestTarget.call(target, YawsShop, :start, [[max_connections: 4], 5_000])
    :ok = TestTarget.call(target, YawsShop, :clients, [port, 6, "/slow"])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = yaws(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    assert [first | _] = r["findings"]
    assert first =~ "critical: Yaws on 127.0.0.1:#{port}"
    assert first =~ "at max_connections (4)"

    assert [s] = r["servers"]

    assert %{"requests" => n, "in" => [%{"in_your_code" => code} | _]} =
             s["running_through_window"]

    assert n >= 3
    assert code == "OtpDebugMcp.Fixtures.YawsShop.out/1"
  end

  test "a cookie session started on every request" do
    target = target()
    port = TestTarget.call(target, YawsShop, :start, [[], 0])
    :ok = TestTarget.call(target, YawsShop, :clients, [port, 3, "/session"])
    Process.sleep(300)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = yaws(%{duration_ms: 1_000})
    assert r["status"] == "warning"
    s = r["sessions"]
    assert s["count"] > 50
    assert s["new_per_s"] > 1
    assert s["used_once"] == s["sampled"]
    assert s["ttl_seconds"] == [1800]
    assert [first | _] = r["findings"]
    assert first =~ "cookie sessions"
    assert first =~ "100% of a sample were never used again"
  end

  test "explains a node without Yaws" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Yaws, %{})
    assert text =~ "Yaws isn't running"
  end
end
