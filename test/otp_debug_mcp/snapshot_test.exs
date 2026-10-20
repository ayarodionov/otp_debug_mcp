defmodule OtpDebugMcp.SnapshotTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Snapshotter, Target, TestTarget, Tracer}
  alias OtpDebugMcp.Fixtures.Ticker

  setup do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    {:ok, _} = TestTarget.call(target, Ticker, :start, [:ticker, 1_000])
    %{target: target}
  end

  test "atoms and code this tool adds to the node don't count as growth" do
    # Cold: the snapshot's own first calls add to the node as well.
    {:ok, _} = Snapshotter.take()

    # Each of these adds to the target: atoms for new variable names and a
    # function name it doesn't have, and the code of a module not loaded yet.
    {:ok, 3} = Checks.remote_eval("Zq1 = 1, Zq2 = 2, Zq1 + Zq2.")

    {:error, _} =
      Tracer.trace(
        "OtpDebugMcp.Fixtures.Ticker",
        "fn_#{System.unique_integer([:positive])}",
        1,
        500
      )

    {:ok, false} = Target.rpc(:code, :is_loaded, [:erl_tar])
    {:ok, :erl_tar} = Target.rpc(:erl_tar, :module_info, [:module])

    {:ok, diff} = Snapshotter.diff()

    assert diff.excluded_footprint_of_this_tool.atoms >= 3
    assert diff.excluded_footprint_of_this_tool.code_mb > 0
    assert diff.atom_count_delta == 0
    assert_in_delta diff.memory_delta_mb.code, 0.0, 0.01
  end

  # The first snapshot on a node loads erl_eval there, among others, which
  # is footprint too; these tests start from a node that has seen one.
  defp warm_up do
    {:ok, _} = Snapshotter.take()
    {:ok, _} = Snapshotter.diff()
  end

  test "the node's own atoms still count", %{target: target} do
    warm_up()
    {:ok, _} = Snapshotter.take()
    for i <- 1..50, do: TestTarget.call(target, :erlang, :binary_to_atom, ["own_#{i}"])

    {:ok, diff} = Snapshotter.diff()
    assert diff.atom_count_delta >= 50
    assert diff.excluded_footprint_of_this_tool.atoms == 0
  end

  test "repeat calls are free once their atoms are known" do
    warm_up()
    {:ok, 3} = Checks.remote_eval("Zr1 = 1, Zr2 = 2, Zr1 + Zr2.")
    {:ok, _} = Snapshotter.take()
    {:ok, 3} = Checks.remote_eval("Zr1 = 1, Zr2 = 2, Zr1 + Zr2.")

    {:ok, diff} = Snapshotter.diff()
    assert diff.excluded_footprint_of_this_tool == %{atoms: 0, code_mb: 0.0}
  end
end
