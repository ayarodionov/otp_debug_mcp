defmodule OtpDebugMcp.SupervisorRestartsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.{App, CrashSup}

  # Each test gets a fresh target, since restart history is the subject.
  setup do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    %{target: target}
  end

  defp check, do: Checks.run(:supervisor_restarts)

  defp restarted(name) do
    %{findings: %{restarted: restarted}} = check()
    Enum.find(restarted, &(&1.supervisor == inspect(name)))
  end

  test "is ok when no supervisor has restarted anything" do
    assert %{status: :ok, findings: %{supervisors_scanned: scanned, restarted: []}} = check()
    # kernel_sup, logger_sup and friends.
    assert scanned >= 3
  end

  test "reports a recent restart, without children restarting during the sample",
       %{target: target} do
    :ok =
      TestTarget.call(target, CrashSup, :start, [:crash_sup, [{:child, nil}], [max_restarts: 10]])

    :ok = TestTarget.call(target, CrashSup, :kill_child, [:crash_sup, :child])

    assert %{status: :warning} = check()

    assert %{
             kind: :static,
             strategy: :one_for_one,
             max_restarts: 10,
             max_seconds: 5,
             restarts_in_window: 1,
             at_limit: false,
             last_restart_seconds_ago: ago,
             restarting_children: []
           } = restarted(:crash_sup)

    assert ago <= 2
  end

  test "is critical when a supervisor is one crash away from giving up", %{target: target} do
    opts = [max_restarts: 3, max_seconds: 3600]
    :ok = TestTarget.call(target, CrashSup, :start, [:fragile_sup, [{:child, nil}], opts])

    for _ <- 1..3,
        do: :ok = TestTarget.call(target, CrashSup, :kill_child, [:fragile_sup, :child])

    assert %{status: :critical} = check()
    assert %{restarts_in_window: 3, max_restarts: 3, at_limit: true} = restarted(:fragile_sup)
  end

  test "names the child in a crash loop", %{target: target} do
    children = [{:stable, nil}, {:looper, 200}]
    opts = [max_restarts: 1_000, max_seconds: 5]
    :ok = TestTarget.call(target, CrashSup, :start, [:loop_sup, children, opts])
    Process.sleep(1_000)

    assert %{status: :warning} = check()
    assert %{restarts_in_window: n, restarting_children: [looper]} = restarted(:loop_sup)
    assert n >= 3
    assert %{id: ":looper", modules: "[OtpDebugMcp.Fixtures.Crasher]"} = looper
    assert looper.pid_before != looper.pid_now

    # The child seen to die during the sample reports why, and where.
    assert looper.exit_reason =~ "crash loop fixture"

    assert looper.exit_reason =~
             ~r/handle_info,2,\[\{file,"test\/support\/fixtures.ex"\},\{line,\d+\}/

    # Tools fall back to inspect() for terms JSON can't encode.
    assert is_binary(JSON.encode!(check()))
  end

  test "supervision_tree shows a restart where it happened", %{target: target} do
    :ok = TestTarget.call(target, App, :start, [3])
    :ok = TestTarget.call(target, :logger, :set_primary_config, [:level, :none])

    [{_, worker, _, _} | _] =
      TestTarget.call(target, DynamicSupervisor, :which_children, [OtpDebugMcp.Fixtures.Pool])

    true = TestTarget.call(target, :erlang, :exit, [worker, :kill])
    Process.sleep(100)

    {:ok, root} = call_tool_json(Tools.SupervisionTree, %{app: "fixture_app"})
    assert %{"restarts_in_window" => 0} = root["restarts"]

    pool = Enum.find(root["children"], &(&1["name"] == "OtpDebugMcp.Fixtures.Pool"))

    assert %{"restarts_in_window" => 1, "last_restart_seconds_ago" => ago, "at_limit" => false} =
             pool["restarts"]

    assert ago <= 1
  end

  test "reads a DynamicSupervisor's history and names its application", %{target: target} do
    :ok = TestTarget.call(target, App, :start, [3])
    :ok = TestTarget.call(target, :logger, :set_primary_config, [:level, :none])

    [{_, worker, _, _} | _] =
      TestTarget.call(target, DynamicSupervisor, :which_children, [OtpDebugMcp.Fixtures.Pool])

    true = TestTarget.call(target, :erlang, :exit, [worker, :kill])
    Process.sleep(100)

    assert %{
             kind: :dynamic,
             application: :fixture_app,
             restarts_in_window: 1,
             restarting_children: "not sampled" <> _
           } = restarted(OtpDebugMcp.Fixtures.Pool)
  end
end
