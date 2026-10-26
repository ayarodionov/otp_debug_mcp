defmodule OtpDebugMcp.ChecksTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Snapshotter, TestTarget}
  alias OtpDebugMcp.Fixtures.{AtomLeak, Fussy, Mailbox, OldLoop, ProcLeak, SliceKeeper}

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

    assert Enum.map(results, & &1.check) |> Enum.sort() ==
             Enum.sort(Checks.all_checks() -- Checks.on_request())

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

  test "logs says where the node's logs go, and when no file keeps them", %{target: target} do
    assert %{status: :ok, findings: %{files: [], note: note, primary_level: level} = f} =
             Checks.run(:logs)

    assert note =~ "watch_minutes"
    assert level in [:notice, :info, :debug, :all, :warning]
    assert Enum.any?(f.handlers, &(&1.writes =~ "console"))

    file = Path.join(System.tmp_dir!(), "otpdbg_logs_#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(file) end)
    config = %{config: %{file: String.to_charlist(file)}}
    # The handler creates its file when it starts.
    :ok = TestTarget.call(target, :logger, :add_handler, [:otpdbg_file, :logger_std_h, config])

    try do
      assert %{status: :ok, findings: %{files: [%{file: ^file, size_bytes: _}]} = f} =
               Checks.run(:logs)

      refute Map.has_key?(f, :note)
      assert %{id: _, writes: ^file} = Enum.find(f.handlers, &(&1.writes == file))

      # A primary level above error hides errors.
      :ok = TestTarget.call(target, :logger, :set_primary_config, [:level, :critical])
      assert %{status: :warning, findings: %{primary_level: :critical}} = Checks.run(:logs)
    after
      :ok = TestTarget.call(target, :logger, :set_primary_config, [:level, level])
      :ok = TestTarget.call(target, :logger, :remove_handler, [:otpdbg_file])
    end
  end

  test "scheduler_time splits scheduler time by state, and leaves accounting as it was",
       %{target: target} do
    assert %{status: _, findings: %{by_thread_type: %{scheduler: normal} = types} = f} =
             Checks.run(:scheduler_time)

    assert normal.threads >= 1
    assert normal.busy >= 0 and normal.busy <= 1
    assert %{emulator: _, gc: _, port: _, other: _} = normal.work
    refute Map.has_key?(normal.work, :sleep)
    # The busy time, split: it adds up to 1, rounding aside.
    if normal.busy > 0, do: assert_in_delta(Enum.sum(Map.values(normal.work)), 1.0, 0.02)
    # Idle thread types are left out.
    refute Map.has_key?(types, :async)
    assert f.gc_share_of_work >= 0 and f.gc_share_of_work <= 1
    assert f.gc_schedulers >= 0
    refute Map.has_key?(f, :note)
    # Off again, as it was.
    assert TestTarget.call(target, :erlang, :system_flag, [:microstate_accounting, false]) ==
             false

    # Someone else's accounting is left on, and not reset.
    false = TestTarget.call(target, :erlang, :system_flag, [:microstate_accounting, true])

    try do
      assert %{findings: %{note: note}} = Checks.run(:scheduler_time)
      assert note =~ "left on"
    after
      # Still on, as it was.
      assert TestTarget.call(target, :erlang, :system_flag, [:microstate_accounting, false])
    end
  end

  test "stale_code: processes left in old code, and modules unlike their file" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)

    assert %{status: :ok, findings: %{old_code: [], different_on_disk: []}} =
             Checks.run(:stale_code)

    # Loaded again while its process loops: the process stays in the old code.
    :ok = TestTarget.call(target, OldLoop, :start, [:old_loop])
    {OldLoop, bin, file} = :code.get_object_code(OldLoop)
    {:module, OldLoop} = TestTarget.call(target, :code, :load_binary, [OldLoop, file, bin])

    # The code path has a different .beam for a module than the one running.
    dir = Path.join(System.tmp_dir!(), "otpdbg_stale_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {_, other, _} = :code.get_object_code(Fussy)
    fake = Path.join(dir, "Elixir.OtpDebugMcp.Fixtures.Mailbox.beam")
    File.write!(fake, other)
    {Mailbox, mailbox, _} = :code.get_object_code(Mailbox)
    true = TestTarget.call(target, :code, :add_patha, [to_charlist(dir)])

    {:module, Mailbox} =
      TestTarget.call(target, :code, :load_binary, [Mailbox, to_charlist(fake), mailbox])

    assert %{status: :warning, findings: f} = Checks.run(:stale_code)

    assert %{processes_in_it: 1, some: [p]} =
             Enum.find(f.old_code, &(&1.module == "OtpDebugMcp.Fixtures.OldLoop"))

    # Mailbox, loaded again too, has old code that nothing runs.
    assert %{processes_in_it: 0} =
             Enum.find(f.old_code, &(&1.module == "OtpDebugMcp.Fixtures.Mailbox"))

    assert p.registered_name == ":old_loop"

    assert [%{module: "OtpDebugMcp.Fixtures.Mailbox", on_disk: :modified, file: ^fake}] =
             f.different_on_disk

    # A module off the code path, as Mix leaves its tools' modules, isn't
    # stale while the file it was loaded from is there; once that's gone
    # too, it is.
    forms = [
      {:attribute, 1, :module, :otpdbg_tool},
      {:attribute, 1, :export, [f: 0]},
      {:function, 1, :f, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
    ]

    {:ok, :otpdbg_tool, tool} = :compile.forms(forms)
    tools = Path.join(dir, "tools")
    File.mkdir_p!(tools)
    beam = Path.join(tools, "otpdbg_tool.beam")
    File.write!(beam, tool)
    true = TestTarget.call(target, :code, :add_patha, [to_charlist(tools)])
    {:module, _} = TestTarget.call(target, :code, :load_abs, [to_charlist(Path.rootname(beam))])
    true = TestTarget.call(target, :code, :del_path, [to_charlist(tools)])

    assert %{findings: %{different_on_disk: disk}} = Checks.run(:stale_code)
    refute Enum.any?(disk, &(&1.module == ":otpdbg_tool"))

    File.rm!(beam)

    assert %{findings: %{different_on_disk: disk}} = Checks.run(:stale_code)
    assert %{on_disk: :removed, file: ^beam} = Enum.find(disk, &(&1.module == ":otpdbg_tool"))
  end

  test "distribution: the node's connections, and this tool's marked" do
    [a, b] = for _ <- 1..2, do: TestTarget.start()

    on_exit(fn ->
      TestTarget.stop(a)
      TestTarget.stop(b)
    end)

    true = TestTarget.call(a, :erlang, :set_cookie, [b.node, String.to_atom(b.cookie)])
    true = TestTarget.call(a, :net_kernel, :connect_node, [b.node])
    {:ok, _} = TestTarget.connect(a)

    assert %{status: :ok, findings: f} = Checks.run(:distribution)
    assert f.node == Atom.to_string(a.node)
    assert f.busy_limit_bytes > 0
    other = Enum.find(f.connections, &(&1.node == Atom.to_string(b.node)))
    assert %{type: :normal, state: :up, pending_bytes: pending} = other
    assert is_integer(pending)
    refute Map.has_key?(other, :this_tool)
    assert %{type: :hidden, this_tool: true} = Enum.find(f.connections, & &1[:this_tool])
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
