defmodule OtpDebugMcp.PostgrexTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{PgServer, TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.PgShop

  @moduletag :postgres

  defp postgrex(params), do: call_tool_json(Tools.Postgrex, params)

  defp target(pool_size) do
    {opts, dir} = PgServer.start()
    target = TestTarget.start(postgrex: true)
    on_exit(fn -> TestTarget.stop(target) end)
    # DBConnection logs every connection it loses and every checkout it drops.
    _ = TestTarget.call(target, :logger, :remove_handler, [:default])
    :ok = TestTarget.call(target, PgShop, :start, [opts, pool_size])
    {target, dir}
  end

  test "a pool, its connections and the server's version" do
    {target, _} = target(3)
    :ok = TestTarget.call(target, PgShop, :readers, [2])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = postgrex(%{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert [p] = r["pools"]
    assert p["pool"] == ":shop_db"
    assert p["database"] == "postgres"
    assert p["module"] == "Postgrex.Protocol"
    assert p["pool_size"] == 3
    assert %{"up" => 3, "down" => 0} = p["connections"]
    assert p["server_version"] =~ ~r/^\d+/
  end

  test "a pool exhausted by connections held in a transaction" do
    {target, _} = target(2)
    :ok = TestTarget.call(target, PgShop, :writers, [2, 3_000])
    :ok = TestTarget.call(target, PgShop, :readers, [4])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = postgrex(%{duration_ms: 1_000})
    assert r["status"] == "critical"
    assert [p] = r["pools"]
    assert p["callers_waiting"] >= 1
    assert p["longest_wait_ms"] in 0..5_000
    assert %{"idle" => 0} = p["connections"]

    # One writer sleeps in its transaction, holding the row; the other
    # waits on the server for it, in its query.
    assert %{"in_your_code" => code} =
             Enum.find(p["checked_out"], &(&1["in_transaction"] && !&1["running_a_query"]))

    assert code =~ "OtpDebugMcp.Fixtures.PgShop.sell/2"

    assert Enum.any?(r["findings"], &(&1 =~ "callers waiting for a connection"))
    assert Enum.any?(r["findings"], &(&1 =~ "held by the same caller through the whole"))

    assert Enum.any?(
             r["findings"],
             &(&1 =~ "in a transaction while their callers do something else")
           )
  end

  test "server: queries waiting for a row lock another connection holds" do
    {target, _} = target(3)
    :ok = TestTarget.call(target, PgShop, :writers, [3, 3_000])
    Process.sleep(500)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = postgrex(%{duration_ms: 500, server: true})
    assert %{"backends" => n, "blocked" => [blocked | _]} = r["server"]
    assert n >= 3
    assert blocked["query"] =~ "UPDATE stock"
    assert [_ | _] = blocked["blocked_by"]

    assert Enum.any?(
             r["findings"],
             &(&1 =~ "on the server, backend" and &1 =~ "for a lock held by backend" and
                 &1 =~ "PgShop.sell/2")
           )
  end

  test "the database gone: connections down" do
    {target, dir} = target(2)
    :ok = TestTarget.call(target, PgShop, :readers, [1])
    :ok = PgServer.stop(dir)
    Process.sleep(1_000)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = postgrex(%{duration_ms: 500})
    assert r["status"] == "critical"
    assert [p] = r["pools"]
    assert %{"up" => 0, "down" => 2} = p["connections"]
    assert Enum.any?(r["findings"], &(&1 =~ "2 of 2 connections are down"))
  end

  @tag postgres: false
  test "explains a node without a pool" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Postgrex, %{})
    assert text =~ "no DBConnection pool runs on this node"
  end
end
