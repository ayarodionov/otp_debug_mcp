defmodule OtpDebugMcp.ChecksTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Snapshotter, TestTarget}
  alias OtpDebugMcp.Fixtures.{AtomLeak, Fussy, Mailbox, ProcLeak, SliceKeeper}

  setup_all do
    target = TestTarget.start()
    _ = TestTarget.call(target, Mailbox, :start, [:stuck_mailbox, 5_000])
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  test "diagnose ranks the backed-up mailbox first and names its process" do
    [first | _] = results = Checks.run_all()

    assert %{check: :message_queues, status: :warning, findings: [offender]} = first
    assert offender.queue_len >= 5_000
    assert offender.info.registered_name =~ "stuck_mailbox"

    assert Enum.map(results, & &1.check) |> Enum.sort() == Enum.sort(Checks.all_checks())
    refute Enum.any?(results, &(&1.status == :error))
  end

  test "atom_table is ok when no atoms are being created" do
    assert %{status: :ok, findings: %{growth_per_second: rate} = f} = Checks.run(:atom_table)
    assert rate == 0.0
    refute Map.has_key?(f, :seconds_until_full)
  end

  test "atom_table measures atom growth, and when the table will be full" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    TestTarget.call(target, AtomLeak, :start, [2])
    Process.sleep(200)

    assert %{status: status, findings: %{growth_per_second: rate, seconds_until_full: left}} =
             Checks.run(:atom_table)

    # About 500 a second: a million atoms fill in well under a day.
    assert status == :critical
    assert rate > 100
    assert left > 0 and left < 86_400
  end

  test "process_count measures growth and names the group that grows" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    TestTarget.call(target, ProcLeak, :start, [2])
    Process.sleep(1_000)

    # Critical once the limit is under an hour away, at a fast enough leak.
    assert %{status: status, findings: f} = Checks.run(:process_count)
    assert status in [:warning, :critical]
    assert f.growth_per_second > 100
    assert f.seconds_until_limit > 0

    assert [%{processes: n, sample_stack: stack} | _] = f.largest_groups
    assert n > 300
    assert stack =~ "OtpDebugMcp.Fixtures.ProcLeak"
  end

  test "binary_leak names a process pinning binaries through slices" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    :ok = TestTarget.call(target, SliceKeeper, :start, [:slice_keeper, 4_000, :slices])

    assert %{status: :warning, findings: f} = Checks.run(:binary_leak)
    assert [top | _] = f.largest_holders
    assert top.binary_bytes > 60 * 1_048_576
    assert top.share_of_binary_memory > 0.9
    assert top.info.registered_name =~ "slice_keeper"
    assert %{sampled: 2000, looks_like: "slices" <> _} = top.held_binaries
    # GC can't free live references.
    assert f.released_by_gc == []
  end

  test "binary_leak never sends sys:get_state to a process that isn't an OTP behaviour" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    :ok = TestTarget.call(target, Fussy, :start, [:fussy, 80])

    assert %{findings: %{largest_holders: [top | _]}} = Checks.run(:binary_leak)
    assert top.info.registered_name =~ "fussy"
    refute Map.has_key?(top, :held_binaries)
    assert is_pid(TestTarget.call(target, :erlang, :whereis, [:fussy]))
  end

  test "binary_leak tells whole binaries piling up from slices" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    :ok = TestTarget.call(target, SliceKeeper, :start, [:whole_keeper, 4_000, :whole])

    assert %{findings: %{largest_holders: [top | _]}} = Checks.run(:binary_leak)
    assert %{looks_like: "whole binaries" <> _} = top.held_binaries
  end

  test "memory_breakdown is a partition of the total" do
    %{status: :ok, findings: %{total_bytes: total, breakdown: parts}} =
      Checks.run(:memory_breakdown)

    assert Enum.sum(Enum.map(parts, & &1.bytes)) == total
    assert_in_delta Enum.sum(Enum.map(parts, & &1.percent)), 100.0, 0.5
  end

  test "limit checks report count and limit" do
    for check <- [:process_count, :atom_table, :ports] do
      assert %{status: :ok, findings: %{count: count, limit: limit}} = Checks.run(check)
      assert count > 0 and limit > count
    end
  end

  test "ets_tables and schedulers return their measurements" do
    assert %{status: :ok, findings: [%{bytes: _, rows: _, owner: _} | _]} =
             Checks.run(:ets_tables)

    assert %{
             status: :ok,
             findings: %{
               normal: [%{scheduler: _, usage: _} | _],
               normal_run_queue: _,
               dirty_cpu: %{schedulers: dirty_cpu, usage_avg: _, run_queue: _},
               dirty_io: %{schedulers: dirty_io, usage_max: _}
             }
           } = Checks.run(:schedulers)

    assert dirty_cpu > 0 and dirty_io > 0
  end

  test "remote_eval evaluates Erlang on the target and reports syntax errors", %{target: target} do
    assert {:ok, node} = Checks.remote_eval("node().")
    assert node == target.node
    assert {:error, {_, :erl_parse, _}} = Checks.remote_eval("node(.")
  end

  test "a snapshot diff shows what grew", %{target: target} do
    {:ok, %{process_count: _}} = Snapshotter.take()

    for i <- 1..100, do: TestTarget.call(target, :erlang, :binary_to_atom, ["snap_#{i}"])
    for _ <- 1..50, do: TestTarget.call(target, :erlang, :spawn, [:timer, :sleep, [:infinity]])

    {:ok, diff} = Snapshotter.diff()
    assert diff.atom_count_delta >= 100
    assert diff.process_count_delta >= 50
  end
end
