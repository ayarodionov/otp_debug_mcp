defmodule OtpDebugMcp.VmConfigTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, TestTarget, VmConfig}

  # A container's cgroup (v2) and a process's /proc/self, as files: the
  # node reads them where it's told.
  defp fake_linux(cpu_max, memory_max, open_files_soft) do
    root = Path.join(System.tmp_dir!(), "otpdbg_vm_#{System.unique_integer([:positive])}")
    cgroup = Path.join(root, "cgroup")
    proc = Path.join(root, "proc")
    File.mkdir_p!(cgroup)
    File.mkdir_p!(Path.join(proc, "fd"))
    File.write!(Path.join(cgroup, "cpu.max"), cpu_max <> "\n")
    File.write!(Path.join(cgroup, "memory.max"), memory_max <> "\n")
    File.write!(Path.join(cgroup, "memory.current"), "1000\n")

    File.write!(
      Path.join(cgroup, "cpu.stat"),
      "usage_usec 5000000\nnr_periods 1000\nnr_throttled 250\nthrottled_usec 9000000\n"
    )

    File.write!(Path.join(proc, "status"), "Name:\tbeam.smp\nVmRSS:\t   20480 kB\n")

    File.write!(
      Path.join(proc, "limits"),
      "Limit                     Soft Limit           Hard Limit           Units\n" <>
        "Max open files            #{open_files_soft}                 4096                 files\n"
    )

    File.write!(
      Path.join(proc, "cmdline"),
      Enum.join(
        ["beam.smp", "-S", "4:4", "-sbwt", "very_long", "--", "-root", "/x", "-sbwt", "ignored"],
        <<0>>
      )
    )

    for i <- 1..10, do: File.write!(Path.join([proc, "fd", "#{i}"]), "")
    on_exit(fn -> File.rm_rf!(root) end)
    [cgroup_root: cgroup, proc_root: proc]
  end

  defp target(args) do
    target = TestTarget.start(args: args)
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    target
  end

  test "is part of diagnose, and fine on an ordinary node" do
    target([])
    assert %{check: :vm_config, status: :ok, findings: f} = Checks.run(:vm_config)
    assert f.cpu.schedulers_online >= 1
    assert f.limits.processes.limit > 0
    assert :vm_config in Checks.all_checks()
  end

  test "more schedulers than the CPU quota, busy-waiting, a memory limit nearly reached" do
    target = target([~c"+S", ~c"4:4"])
    total = TestTarget.call(target, :erlang, :memory, [:total])
    # A limit only a little over what the node uses now.
    opts = fake_linux("150000 100000", "#{round(total * 1.15)}", 1024)

    assert {:ok, status, f, _} = VmConfig.run(opts ++ [stat_ms: 10])
    assert status == :warning or status == :critical
    assert f.cpu.cpu_quota == 1.5
    assert f.cpu.cpu_quota_period_ms == 100
    assert f.cpu.busy_wait.sbwt == "very_long"
    assert %{periods_since_start: 1000, throttled_share_since_start: 0.25} = f.cpu.throttled
    assert f.limits.open_files == %{used: 10, limit: 1024, share: 0.01, hard_limit: 4096}
    assert f.memory.os_resident_bytes == 20480 * 1024

    assert f.emulator_flags == %{"+S" => "4:4", "+sbwt" => "very_long"}
    notes = Enum.join(f.notes, "\n")
    assert notes =~ "4 schedulers online, but the container's CPU quota is 1.5 CPUs per 100 ms"
    assert notes =~ "(the command line sets +S 4:4)"
    assert notes =~ "+S 2:2"
    assert notes =~ "throttled it in 25% of its periods since it started"
    assert notes =~ "+sbwt none"
    assert notes =~ "of the container's"
    assert notes =~ "the OS allows 1024 open files"
  end

  test "no CPU or memory limit, and the logger at debug" do
    target = target([])
    :ok = TestTarget.call(target, :logger, :set_primary_config, [:level, :debug])
    opts = fake_linux("max 100000", "max", 65_536)

    assert {:ok, :warning, f, _} = VmConfig.run(opts ++ [stat_ms: 10])
    assert f.cpu.cpu_quota == "unlimited"
    assert f.memory.container_limit_bytes == "unlimited"
    notes = Enum.join(f.notes, "\n")
    assert notes =~ "the logger's primary level is debug"
    refute notes =~ "CPU quota"
    refute notes =~ "busy-wait"
  end
end
