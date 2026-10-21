defmodule OtpDebugMcp.ClusterTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, Cluster, Target, TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.{Hog, Mailbox}

  defp start_cluster(links \\ :full) do
    targets = TestTarget.start_cluster(3, links)
    on_exit(fn -> Enum.each(targets, &TestTarget.stop/1) end)
    {:ok, _} = TestTarget.connect(hd(targets))
    targets
  end

  defp nodes(targets), do: Enum.map(targets, & &1.node)

  test "finds the cluster from the current target, which stays current" do
    [a, _, _] = targets = start_cluster()

    assert {:ok, members, []} = Cluster.members()
    assert hd(members) == a.node
    assert Enum.sort(members) == Enum.sort(nodes(targets))
    assert Target.connected_node() == a.node
  end

  test "runs calls against another member with Target.on" do
    [_, b, _] = start_cluster()
    {:ok, _, _} = Cluster.members()

    assert {:ok, b.node} == Target.on(b.node, fn -> Target.rpc(:erlang, :node, []) end)
  end

  test "compare singles out the node that differs" do
    [_, b, _] = start_cluster()
    _ = TestTarget.call(b, Mailbox, :start, [:stuck_mailbox, 5_000])
    :ok = TestTarget.call(b, Hog, :start, [:hog, 200])
    {:ok, _, _} = Cluster.members()

    {:ok, :ok} =
      Target.on(b.node, fn ->
        Checks.remote_eval(
          "[list_to_atom(\"extra_\" ++ integer_to_list(I)) || I <- lists:seq(1, 8000)], ok."
        )
      end)

    assert {:ok, %{status: :warning, nodes: rows, outliers: outliers, partitions: []}} =
             Cluster.compare()

    assert length(rows) == 3
    flagged = for %{node: node, metric: metric} <- outliers, do: {node, metric}
    assert {b.node, :max_message_queue} in flagged
    assert {b.node, :memory_total_mb} in flagged
    assert {b.node, :atom_count} in flagged
    assert Enum.all?(outliers, &(&1.node == b.node))
  end

  test "finds a member only another one sees, and reports the partition" do
    # a - b - c, with no link between a and c.
    [a, _, c] = start_cluster([{0, 1}, {1, 2}])

    assert {:ok, %{status: :critical, nodes: rows, partitions: partitions}} = Cluster.compare()
    assert length(rows) == 3

    assert %{node: a.node, does_not_see: [c.node]} in partitions
    assert %{node: c.node, does_not_see: [a.node]} in partitions
  end

  test "diagnose reports each node's problems, the worst node first" do
    [a, b, _] = start_cluster()
    _ = TestTarget.call(b, Mailbox, :start, [:stuck_mailbox, 5_000])

    assert {:ok, %{nodes: [first | rest], interpretations: interpretations}} = Cluster.diagnose()
    assert %{node: node, worst: :warning, problems: problems} = first
    assert node == b.node
    assert Enum.any?(problems, &(&1.check == :message_queues))
    assert Map.has_key?(interpretations, :message_queues)
    assert Enum.find(rest, &(&1.node == a.node)).worst == :ok
  end

  test "snapshots show which node grows" do
    [_, _, c] = start_cluster()

    assert {:ok, %{taken: taken}} = Cluster.snapshot_take()
    assert length(taken) == 3
    :ok = TestTarget.call(c, Hog, :start, [:hog, 100])

    assert {:ok, %{growth: [top | _]}} = Cluster.snapshot_diff()
    assert top.node == c.node
    assert top.memory_total_delta_mb > 90
  end

  test "a given node list can include nodes that aren't reachable" do
    [a, b, _] = start_cluster()
    given = [Atom.to_string(a.node), Atom.to_string(b.node), "nosuch@#{host()}"]

    nosuch = :"nosuch@#{host()}"
    assert {:ok, members, [%{node: ^nosuch}]} = Cluster.members(given)
    assert members == [a.node, b.node]
  end

  test "the tools: connect points at the cluster, and cluster answers in JSON" do
    [a | _] = start_cluster()
    params = %{node: Atom.to_string(a.node), cookie: a.cookie}

    assert {:ok, %{"cluster" => %{"other_nodes" => [_, _]}}} =
             call_tool_json(Tools.Connect, params)

    assert {:ok, %{"status" => "ok", "nodes" => [_, _, _]}} = call_tool_json(Tools.Cluster, %{})
    assert {:error, text} = call_tool(Tools.Cluster, %{action: "nope"})
    assert text =~ "unknown_action"
  end

  defp host, do: :inet.gethostname() |> elem(1) |> to_string()
end
