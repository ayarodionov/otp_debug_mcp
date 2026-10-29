defmodule OtpDebugMcp.PhoenixTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.PhxShop

  defp phoenix(params), do: call_tool_json(Tools.Phoenix, params)

  defp target do
    target = TestTarget.start(phoenix: true)
    on_exit(fn -> TestTarget.stop(target) end)
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    port = TestTarget.call(target, PhxShop, :start, [])
    {target, port}
  end

  test "endpoints, sockets, and a route an earlier one shadows" do
    {target, port} = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = phoenix(%{duration_ms: 500})
    assert [e] = r["endpoints"]
    assert e["endpoint"] == "OtpDebugMcp.Fixtures.PhxShop.Endpoint"
    assert e["http"] == "127.0.0.1:#{port}"
    assert e["server"] == true
    assert "/live -> Phoenix.LiveView.Socket" in e["sockets"]

    assert [%{"routes" => 3, "live_routes" => 1, "shadowed" => [s]}] = r["routers"]
    assert s["route"] =~ "GET /products/search"
    assert s["unreachable_because_of"] =~ "GET /products/:id"
    assert Enum.any?(r["findings"], &(&1 =~ "routes can't be reached"))
  end

  test "LiveViews whose assigns grow with every broadcast" do
    {target, port} = target()
    for _ <- 1..3, do: TestTarget.call(target, PhxShop, :client, [port])
    {:ok, _} = TestTarget.connect(target)
    # 10 KB items, 100 a second, through the window and a bit before.
    :ok = TestTarget.call(target, PhxShop, :feed, [300, 10_000, 100])
    Process.sleep(300)

    assert {:ok, r} = phoenix(%{duration_ms: 2_000})
    assert [v] = r["live_views"]
    assert v["view"] == "OtpDebugMcp.Fixtures.PhxShop.FeedLive"
    assert v["processes"] == 3
    assert %{"growing" => 3, "processes_compared" => 3} = v["memory_growth"]
    assert [%{"assign" => "items", "length" => n} | _] = v["biggest_assigns"]
    assert n > 100
    assert [%{"topic" => "feed", "subscribers" => 3}] = hd(r["pubsub"])["topics_with_most"]
    assert [%{"grew_in_window" => %{"length" => _}} | _] = v["biggest_assigns"]
    assert Enum.any?(r["findings"], &(&1 =~ "assign items grew through the window"))
  end

  test "a slow handle_event, from Phoenix's telemetry" do
    {target, port} = target()
    tab = TestTarget.call(target, PhxShop, :client, [port])
    {:ok, _} = TestTarget.connect(target)

    clicker =
      spawn(fn ->
        for _ <- 1..6 do
          TestTarget.call(target, :erlang, :send, [tab, {:click, "slow"}])
          Process.sleep(250)
        end
      end)

    on_exit(fn -> Process.exit(clicker, :kill) end)

    assert {:ok, r} = phoenix(%{duration_ms: 2_000})

    assert [
             %{
               "what" => "OtpDebugMcp.Fixtures.PhxShop.FeedLive slow (handle_event)",
               "p95_ms" => p95
             }
             | _
           ] =
             r["window"]["live_view_callbacks"]

    assert p95 >= 300
    assert Enum.any?(r["findings"], &(&1 =~ "start_async"))
  end

  test "channel processes, by channel" do
    {target, port} = target()
    for room <- ~w(a b), do: TestTarget.call(target, PhxShop, :room, [port, room])
    Process.sleep(200)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = phoenix(%{duration_ms: 500})

    assert [
             %{
               "channel" => "OtpDebugMcp.Fixtures.PhxShop.RoomChannel",
               "processes" => 2,
               "topics" => 2
             }
           ] =
             r["channels"]

    assert r["sockets"]["OtpDebugMcp.Fixtures.PhxShop.UserSocket"] == 2
  end

  test "explains a node without Phoenix" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Phoenix, %{})
    assert text =~ "no Phoenix endpoint is running"
  end
end
