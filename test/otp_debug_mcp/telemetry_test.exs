defmodule OtpDebugMcp.TelemetryTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.Emitter

  setup_all do
    target = TestTarget.start(telemetry: true)
    :ok = TestTarget.call(target, Emitter, :start, [10])
    plain = TestTarget.start()

    on_exit(fn ->
      TestTarget.stop(target)
      TestTarget.stop(plain)
    end)

    %{target: target, plain: plain}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp telemetry(params), do: call_tool_json(Tools.Telemetry, params)

  defp handlers(target),
    do:
      target
      |> TestTarget.call(:telemetry, :list_handlers, [[]])
      |> Enum.map(& &1.id)
      |> Enum.uniq()

  test "lists what the node's handlers listen to, and its repos' queries" do
    assert {:ok, %{"events" => events}} = telemetry(%{list: true})

    assert %{"event" => "phoenix.router_dispatch.stop", "from" => "handlers"} in events
    assert %{"event" => "shop.repo.query", "from" => "ecto"} in events
  end

  test "groups requests by route and queries by query, slowest first", %{target: target} do
    assert {:ok, r} = telemetry(%{duration_ms: 1_000})
    assert "shop.repo.query" in r["listened_to"]

    by_event = Map.new(r["by_event"], &{&1["event"], &1})
    dispatch = by_event["phoenix.router_dispatch.stop"]
    assert [search, show] = dispatch["groups"]
    assert search["key"] == "GET /search"
    assert show["key"] == "GET /products/:id"
    assert search["duration_ms"]["p50"] >= 39
    assert show["duration_ms"]["p95"] < 5
    assert search["count"] > 5

    # The slowest example, without the conn's big assign.
    assert search["slowest"]["metadata"] =~ ~s(plug_opts: :search)
    assert search["slowest"]["metadata"] =~ ~s(request_path: "/search")
    refute search["slowest"]["metadata"] =~ "xxxx"

    [query] = by_event["shop.repo.query"]["groups"]
    assert query["key"] == "products: SELECT p0.id FROM products AS p0 WHERE (p0.id = $1)"
    assert query["queue_time_ms"]["p50"] >= 0.9
    assert query["total_time_ms"]["max"] >= 38

    assert [%{"event" => "phoenix.router_dispatch.exception", "kind" => ":error"} = e] =
             r["exceptions"]

    assert e["reason"] == "ArgumentError: bad id"
    assert e["key"] =~ "GET /"

    # Detached afterwards; the node's own handler stays.
    assert handlers(target) == ["fixture-logger"]
  end

  test "listens to the events given, and says which didn't happen" do
    assert {:ok, r} =
             telemetry(%{
               events: ["shop.repo.query", "[:oban, :job, :stop]"],
               duration_ms: 300
             })

    assert r["listened_to"] == ["shop.repo.query", "oban.job.stop"]
    assert [%{"event" => "shop.repo.query"}] = r["by_event"]
    assert r["not_seen"] == ["oban.job.stop"]
  end

  test "attaching logs nothing on the node", %{target: target} do
    {:ok, :started} = OtpDebugMcp.Errors.start(:debug, 5_000)
    {:ok, _} = telemetry(%{events: ["shop.repo.query"], duration_ms: 200})
    {:ok, report} = OtpDebugMcp.Errors.read(true)
    refute Enum.any?(report.entries, &(&1.text =~ "local function"))

    assert TestTarget.call(target, :logger, :get_primary_config, []).filters
           |> Keyword.keys()
           |> Enum.all?(&(&1 != :otp_debug_mcp_quiet))
  end

  test "explains a node without telemetry", %{plain: plain} do
    {:ok, _} = TestTarget.connect(plain)
    assert {:error, text} = call_tool(Tools.Telemetry, %{})
    assert text =~ "telemetry isn't loaded"
  end
end
