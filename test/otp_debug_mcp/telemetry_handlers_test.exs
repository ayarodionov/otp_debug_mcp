defmodule OtpDebugMcp.TelemetryHandlersTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.TelemetryShop

  defp handlers(params), do: call_tool_json(Tools.TelemetryHandlers, params)

  defp target do
    target = TestTarget.start(telemetry: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # telemetry logs every handler it detaches.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    :ok = TestTarget.call(target, TelemetryShop, :start, [])
    target
  end

  test "handlers, what they're attached to, and what's wrong with them" do
    target = target()

    for kind <- [:counter, :counter_again, :missing, :local],
        do: :ok = TestTarget.call(target, TelemetryShop, :attach, [kind])

    :ok = TestTarget.call(target, TelemetryShop, :orders, [3])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = handlers(%{duration_ms: 1_000})
    assert r["status"] == "warning"
    assert r["handlers"] == 4
    assert %{"events_per_s" => rate} = Enum.find(r["busiest"], &(&1["id"] == "counter"))
    assert rate > 10

    assert [%{"event" => "shop.order.stop", "count" => 2, "function" => fun}] = r["duplicates"]
    assert fun == "OtpDebugMcp.Fixtures.TelemetryShop.count/4"

    assert %{"missing" => "module otpdbg_no_such_module doesn't exist"} =
             Enum.find(r["busiest"], &(&1["id"] == "refunds"))

    assert Enum.any?(r["findings"], &(&1 =~ "warning: handler refunds" and &1 =~ "detached"))
    assert Enum.any?(r["findings"], &(&1 =~ "under 2 ids"))
    assert Enum.any?(r["findings"], &(&1 =~ "info: 1 handlers are local or anonymous"))
  end

  test "a slow handler, and the emitters waiting in it" do
    target = target()
    :ok = TestTarget.call(target, TelemetryShop, :attach, [:slow])
    :ok = TestTarget.call(target, TelemetryShop, :orders, [10, [every: 1]])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = handlers(%{duration_ms: 2_000})
    assert r["status"] == "warning"

    assert [%{"handler" => "reporter", "processes_inside_on_average" => avg} = slow | _] =
             r["inside_handlers"]

    assert avg >= 1
    assert slow["function"] == "OtpDebugMcp.Fixtures.TelemetryShop.report/4"
    assert slow["ms_per_event"] > 1
    assert Enum.any?(slow["waiting_in"], &(&1 =~ "gen:do_call/4"))
    assert Enum.any?(r["findings"], &(&1 =~ "warning: handler reporter: on average"))
  end

  test "a handler that raises, detached in the window" do
    target = target()
    :ok = TestTarget.call(target, TelemetryShop, :orders, [2])
    {:ok, _} = TestTarget.connect(target)

    # Attached once the window has begun: the first order without a coupon
    # makes it raise.
    attach =
      Task.async(fn ->
        Process.sleep(500)
        TestTarget.call(target, TelemetryShop, :attach, [:fragile])
      end)

    assert {:ok, r} = handlers(%{duration_ms: 2_000})
    :ok = Task.await(attach)
    assert r["status"] == "critical"
    assert [%{"handler" => failed, "count" => 1}] = r["failures"]
    assert failed =~ "audit on [shop,order,stop]: error"
    assert [first | _] = r["findings"]
    assert first =~ "critical: handler audit on [shop,order,stop]"
    assert first =~ "detached it from all its events"
  end

  test "handlers attached per order, piling up" do
    target = target()
    :ok = TestTarget.call(target, TelemetryShop, :orders, [3, [leak: true, every: 20]])
    Process.sleep(300)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = handlers(%{duration_ms: 1_000})
    assert [%{"pattern" => pattern, "handlers" => n, "at_start" => start}] = r["id_patterns"]
    assert pattern =~ "request"
    assert n > start

    assert Enum.any?(
             r["findings"],
             &(&1 =~ "warning: " and &1 =~ "attached per process or per request")
           )
  end

  test "thousands of handlers on one event: the time goes to telemetry's dispatch" do
    target = target()
    :ok = TestTarget.call(target, TelemetryShop, :attach, [{:many, 3_000}])
    :ok = TestTarget.call(target, TelemetryShop, :orders, [5, [every: 0]])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = handlers(%{duration_ms: 2_000})
    assert r["handlers"] == 3_000
    assert %{"processes_on_average" => avg} = r["in_telemetry_dispatch"]
    assert avg >= 0.5
    assert Enum.any?(r["findings"], &(&1 =~ "telemetry's own dispatch" and &1 =~ "3000 handlers"))
    # A pile-up, not duplicates.
    refute r["duplicates"]
    assert [%{"pattern" => "{many,N}", "handlers" => 3_000}] = r["id_patterns"]
  end

  test "explains a node without telemetry" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.TelemetryHandlers, %{})
    assert text =~ "telemetry isn't loaded"
  end
end
