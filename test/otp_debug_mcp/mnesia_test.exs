defmodule OtpDebugMcp.MnesiaTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.MnesiaShop

  defp mnesia(params), do: call_tool_json(Tools.Mnesia, params)

  defp dir do
    dir = Path.join(System.tmp_dir!(), "otpdbg_mnesia_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp target do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    :ok = TestTarget.call(target, MnesiaShop, :start, [dir()])
    target
  end

  test "its tables, and transactions a second" do
    target = target()
    :ok = TestTarget.call(target, MnesiaShop, :orders, [1, 0])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = mnesia(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    me = Atom.to_string(target.node)
    assert r["nodes"] == %{"db_nodes" => [me], "running" => [me]}

    assert %{"storage" => ":ram_copies", "copies" => %{"ram" => [^me]}, "growing_per_s" => g} =
             Enum.find(r["tables"], &(&1["table"] == ":orders"))

    assert g > 10
    assert r["transactions"]["commits_per_s"] > 10
  end

  test "a hot record: transactions waiting for its lock, and who holds it" do
    target = target()
    :ok = TestTarget.call(target, MnesiaShop, :orders, [10, 50])
    Process.sleep(300)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = mnesia(%{duration_ms: 1_000})
    assert r["status"] == "warning"

    # Sampled through the window: waited for, and its lock held in the
    # transaction's code (or, restarting, the loop around it).
    assert [%{"record" => "{:stock, :total}", "waiting_at_most" => most} = hot | _] =
             r["contended"]

    assert most >= 2
    assert Enum.any?(hot["held_by_code"], &(&1 =~ "OtpDebugMcp.Fixtures.MnesiaShop."))
    assert Enum.any?(r["findings"], &(&1 =~ "lock on {:stock, :total}"))
  end

  test "an overload event in the window" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    overload =
      Task.async(fn ->
        Process.sleep(500)
        TestTarget.call(target, MnesiaShop, :overload, [])
      end)

    assert {:ok, r} = mnesia(%{duration_ms: 1_500})
    Task.await(overload)
    assert r["status"] == "warning"
    assert %{"by_kind" => [%{"event" => kind, "count" => 1}]} = r["system_events"]
    assert kind =~ "mnesia_overload"
    assert Enum.any?(r["findings"], &(&1 =~ "mnesia_overload"))
  end

  test "a table whose only copy was on a node now down" do
    [a, b] = TestTarget.start_cluster(2, :full)
    on_exit(fn -> TestTarget.stop(a) end)
    for t <- [a, b], do: :ok = TestTarget.call(t, MnesiaShop, :start_bare, [dir()])
    :ok = TestTarget.call(a, MnesiaShop, :join, [b.node])
    :ok = TestTarget.call(a, MnesiaShop, :remote_table, [:carts, b.node])
    TestTarget.stop(b)
    {:ok, _} = TestTarget.connect(a)

    assert {:ok, r} = mnesia(%{duration_ms: 500})
    assert r["status"] == "critical"
    gone = Atom.to_string(b.node)
    assert %{"down" => [^gone]} = r["nodes"]

    assert %{"unreachable" => true, "where_to_read" => "nowhere"} =
             Enum.find(r["tables"], &(&1["table"] == ":carts"))

    assert [first | _] = r["findings"]
    assert first =~ "critical: table :carts has no copy this node can reach"
    assert Enum.any?(r["findings"], &(&1 =~ "Mnesia isn't running on #{gone}"))
  end

  test "explains a node without Mnesia" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Mnesia, %{})
    assert text =~ "Mnesia isn't"
  end
end
