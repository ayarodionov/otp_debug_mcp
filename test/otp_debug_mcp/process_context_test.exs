defmodule OtpDebugMcp.ProcessContextTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{ProcessContext, Target, TestTarget}
  alias OtpDebugMcp.Fixtures.{CrashSup, Spawner}

  setup do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    %{target: target}
  end

  defp spawn_sleeper(target),
    do: TestTarget.call(target, :erlang, :spawn, [:timer, :sleep, [:infinity]])

  test "a process spawned a moment ago is estimated as fresh", %{target: target} do
    pid = spawn_sleeper(target)

    {:ok, %{age: age}} = ProcessContext.describe(pid)
    assert age.estimated_seconds < 1.0
  end

  test "the estimate and its bound bracket the true age", %{target: target} do
    {:ok, _} = Target.rpc(:erlang, :node, [])
    Process.sleep(200)
    pid = spawn_sleeper(target)
    spawned = System.monotonic_time(:millisecond)

    # Some of our own calls after it, which the estimate has to discount.
    Process.sleep(1_000)
    for _ <- 1..5, do: {:ok, _} = Target.rpc(:erlang, :node, [])
    Process.sleep(1_000)

    # Ages are as of the start of the call.
    true_age = (System.monotonic_time(:millisecond) - spawned) / 1000
    {:ok, %{age: age}} = ProcessContext.describe(pid)

    assert age.younger_than_seconds >= true_age - 0.1
    assert age.estimated_seconds <= age.younger_than_seconds
    assert age.estimated_seconds >= 1.0
    assert age.spawned_since_by_this_tool >= 5
  end

  test "on a busy node, the spawn rate gives the age", %{target: target} do
    TestTarget.call(target, Spawner, :start, [5])
    Process.sleep(300)
    pid = spawn_sleeper(target)
    spawned = System.monotonic_time(:millisecond)
    Process.sleep(1_500)

    true_age = (System.monotonic_time(:millisecond) - spawned) / 1000
    {:ok, %{age: age}} = ProcessContext.describe(pid)

    assert age.node_spawn_rate_per_second > 50
    assert age.estimated_seconds > true_age / 2 and age.estimated_seconds < true_age * 2
  end

  test "a process without a supervisor says so, and names its parent", %{target: target} do
    pid = spawn_sleeper(target)

    assert {:ok, %{supervisor: nil, parent: parent, supervision: note}} =
             ProcessContext.describe(pid)

    assert %{pid: "<0." <> _, alive: _} = parent
    assert note =~ "nothing restarts this process"
  end

  test "a long-running process is about as old as the node", %{target: target} do
    pid = TestTarget.call(target, :erlang, :whereis, [:init])
    {:ok, %{age: age, supervisor: nil}} = ProcessContext.describe(pid)
    assert age.estimated_seconds >= age.node_uptime_seconds - 1
  end

  test "reports a supervised child's supervisor, and that it exited during the check",
       %{target: target} do
    opts = [max_restarts: 1_000, max_seconds: 5]
    :ok = TestTarget.call(target, CrashSup, :start, [:loop_sup, [{:looper, 200}], opts])
    Process.sleep(700)

    [{:looper, pid, _, _}] = TestTarget.call(target, Supervisor, :which_children, [:loop_sup])
    {:ok, context} = ProcessContext.describe(pid)

    assert %{
             supervisor: ":loop_sup",
             child_id: ":looper",
             kind: :static,
             max_restarts: 1_000,
             restarts_in_window: restarts,
             last_restart_seconds_ago: ago
           } = context.supervisor

    assert restarts >= 2 and ago <= 1
    # The child crashes 200ms after each start; the check takes 500ms.
    assert context.exited_during_check
    assert context.age.estimated_seconds < 1.0
  end
end
