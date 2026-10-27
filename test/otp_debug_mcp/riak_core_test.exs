defmodule OtpDebugMcp.RiakCoreTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.RiakShop

  defp riak_core, do: call_tool_json(Tools.RiakCore, %{})

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(200) && wait_until(fun, tries - 1)
    end
  end

  test "one node: the member, the ring it owns, its vnodes" do
    target = TestTarget.start(riak: true)
    on_exit(fn -> TestTarget.stop(target) end)
    :ok = TestTarget.call(target, RiakShop, :start, [])
    for k <- 1..20, do: :ok = TestTarget.call(target, RiakShop, :put, [k, k])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = riak_core()
    assert r["status"] == "ok"
    assert r["findings"] == []
    me = Atom.to_string(target.node)

    assert %{"claimant" => ^me, "num_partitions" => 8, "ring_ready" => true} = r["cluster"]

    assert [
             %{
               "node" => ^me,
               "status" => "valid",
               "reachable" => true,
               "owns" => 8,
               "this_node" => true
             }
           ] =
             r["cluster"]["members"]

    assert %{"OtpDebugMcp.Fixtures.RiakShop" => %{"primary" => n}} = r["vnodes"]["by_module"]
    assert n > 0
    assert r["vnodes"]["fallbacks"] == []
    assert %{"up_on" => [^me]} = Enum.find(r["services"], &(&1["service"] == ":riak_shop"))
  end

  test "a member gone: unreachable, its service down, fallbacks holding its writes" do
    [a, b] = TestTarget.start_cluster(2, :full, riak: true)
    on_exit(fn -> TestTarget.stop(a) end)
    for t <- [a, b], do: :ok = TestTarget.call(t, RiakShop, :start, [])

    :ok = TestTarget.call(b, :riak_core, :join, [a.node])

    # The claimant plans the join once gossip has brought it.
    wait_until(fn ->
      {:ok, ring} = TestTarget.call(a, :riak_core_ring_manager, :get_my_ring, [])
      {b.node, :joining} in TestTarget.call(a, :riak_core_ring, :all_member_status, [ring])
    end)

    {:ok, _, _} = TestTarget.call(a, :riak_core_claimant, :plan, [])
    :ok = TestTarget.call(a, :riak_core_claimant, :commit, [])

    # b owns half the ring once the handoffs are done.
    wait_until(fn ->
      {:ok, ring} = TestTarget.call(a, :riak_core_ring_manager, :get_my_ring, [])
      owners = TestTarget.call(a, :riak_core_ring, :all_owners, [ring])

      TestTarget.call(a, :riak_core_ring, :pending_changes, [ring]) == [] and
        Enum.any?(owners, &(elem(&1, 1) == b.node))
    end)

    # And a's vnodes for what b now owns have finished forwarding and gone.
    wait_until(fn ->
      {:ok, ring} = TestTarget.call(a, :riak_core_ring_manager, :get_my_ring, [])

      mine =
        for {i, n} <- TestTarget.call(a, :riak_core_ring, :all_owners, [ring]), n == a.node, do: i

      running =
        for {_, i, _} <- TestTarget.call(a, :riak_core_vnode_manager, :all_vnodes, []), do: i

      Enum.all?(running, &(&1 in mine))
    end)

    TestTarget.stop(b)
    # Once a's node watcher has seen b's service go, writes go to fallbacks.
    wait_until(fn ->
      TestTarget.call(a, :riak_core_node_watcher, :nodes, [:riak_shop]) == [a.node]
    end)

    # The first writes after it's gone may still be routed to it.
    for k <- 1..40, do: wait_until(fn -> TestTarget.call(a, RiakShop, :put, [k, k]) == :ok end)
    {:ok, _} = TestTarget.connect(a)

    assert {:ok, r} = riak_core()
    assert r["status"] == "critical"
    gone = Atom.to_string(b.node)
    assert [first | _] = r["findings"]
    assert first =~ "critical: " and first =~ gone and first =~ "isn't connected"

    assert %{"status" => "valid", "reachable" => false, "owns" => owns} =
             Enum.find(r["cluster"]["members"], &(&1["node"] == gone))

    assert owns > 0
    assert [_ | _] = fallbacks = r["vnodes"]["fallbacks"]
    assert Enum.all?(fallbacks, &(&1["owner"] == gone))
    assert Enum.any?(r["findings"], &(&1 =~ "fallback vnodes"))
    assert %{"down_on" => [^gone]} = Enum.find(r["services"], &(&1["service"] == ":riak_shop"))
  end

  test "a vnode with a backed-up mailbox" do
    target = TestTarget.start(riak: true)
    on_exit(fn -> TestTarget.stop(target) end)
    :ok = TestTarget.call(target, RiakShop, :start, [])
    :ok = TestTarget.call(target, RiakShop, :slow, [:hot, 3_000, 10])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = riak_core()
    assert r["status"] == "warning"
    assert [%{"queue" => queue, "role" => "primary"} | _] = r["vnodes"]["busiest"]
    assert queue >= 1_000
    assert Enum.any?(r["findings"], &(&1 =~ "messages in its mailbox"))
    me = Atom.to_string(target.node)
    assert [%{"node" => ^me, "queue" => ^queue} | _] = r["cluster_busiest_vnodes"]
  end

  test "a vnode module registered outside a running application" do
    target = TestTarget.start(riak: true)
    on_exit(fn -> TestTarget.stop(target) end)
    :ok = TestTarget.call(target, RiakShop, :start, [])
    # As riak_core:register/1 does from a process of no application.
    :ok = TestTarget.call(target, :riak_core, :register, [:undefined, [vnode_module: RiakShop]])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = riak_core()
    assert r["status"] == "critical"
    assert [first | _] = r["findings"]
    assert first =~ "registered under the application :undefined, which isn't running"
  end

  # A set updated once by each of `actors` actors, cycling through 5 items.
  defp set(actors) do
    Enum.reduce(1..actors, :riak_dt_orswot.new(), fn n, set ->
      {:ok, set} = :riak_dt_orswot.update({:add, rem(n, 5)}, "client-#{n}", set)
      set
    end)
  end

  test "crdts: sizes, too many actors, deferred removes, riak_dt binaries" do
    target = TestTarget.start(riak: true)
    on_exit(fn -> TestTarget.stop(target) end)
    :ok = TestTarget.call(target, RiakShop, :start, [])
    for k <- 1..10, do: :ok = TestTarget.call(target, RiakShop, :put, [{:cart, k}, set(2)])
    :ok = TestTarget.call(target, RiakShop, :put, [:favorites, set(300)])
    :ok = TestTarget.call(target, RiakShop, :put, [:encoded, :riak_dt_orswot.to_binary(set(40))])

    {:ok, map} =
      :riak_dt_map.update(
        {:update, [{:update, {"items", :riak_dt_orswot}, {:add, :y}}]},
        :a,
        :riak_dt_map.new()
      )

    :ok = TestTarget.call(target, RiakShop, :put, [:profile, map])

    # A remove whose add this replica never saw waits, deferred.
    {:ok, seen} = :riak_dt_orswot.update({:add, :x}, :a, :riak_dt_orswot.new())
    ctx = :riak_dt_orswot.precondition_context(seen)
    {:ok, waiting} = :riak_dt_orswot.update({:remove, :x}, :b, :riak_dt_orswot.new(), ctx)
    :ok = TestTarget.call(target, RiakShop, :put, [:returns, waiting])
    # As in a node whose code uses riak_dt.
    {:module, _} = TestTarget.call(target, :code, :ensure_loaded, [:riak_dt_orswot])
    {:ok, _} = TestTarget.connect(target)

    # Without crdts, only a hint that they can be measured.
    assert {:ok, r} = riak_core()
    refute Map.has_key?(r, "crdts")
    assert Enum.any?(r["findings"], &(&1 =~ "info: riak_dt is loaded here"))

    assert {:ok, r} = call_tool_json(Tools.RiakCore, %{crdts: true})
    assert r["status"] == "warning"
    c = r["crdts"]

    assert c["vnodes_scanned"] ==
             r["vnodes"]["by_module"]["OtpDebugMcp.Fixtures.RiakShop"]["total"]

    assert c["count"] == 14

    assert [
             %{"key" => "favorites", "type" => "orswot", "actors" => 300, "elements" => 5} = fav
             | _
           ] =
             c["largest"]

    assert fav["bytes"] > 1_000

    assert [%{"key" => "favorites"}, %{"key" => "encoded", "encoded" => true, "actors" => 40}] =
             c["most_actors"]

    assert Enum.any?(
             c["largest"],
             &match?(%{"key" => "profile", "type" => "map", "fields" => 1}, &1)
           )

    assert [%{"key" => "returns", "deferred_removes" => 1}] = c["deferred_removes"]
    assert [first | _] = r["findings"]
    assert first =~ "warning: 2 CRDTs have more actors than the ring has partitions (8)"
    assert first =~ "the orswot favorites"
    assert Enum.any?(r["findings"], &(&1 =~ "info: 1 CRDTs hold deferred removes"))
  end

  test "explains a node without riak_core" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.RiakCore, %{})
    assert text =~ "riak_core isn't running"
  end
end
