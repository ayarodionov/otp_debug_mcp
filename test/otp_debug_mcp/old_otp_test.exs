defmodule OtpDebugMcp.OldOtpTest do
  @moduledoc """
  Against a node running an older OTP release than this one, which can't
  load our compiled recon and has no trace sessions. Start one in Docker,
  limited to one CPU but with four schedulers, calling queue:new/0 ten
  times a second:

      docker run -d --rm --name otp26 -p 9100:9100 --cpus=1 erlang:26-slim \\
        erl +S 4:4 -noinput -name old@127.0.0.1 -setcookie testcookie -erl_epmd_port 9100 \\
        -eval 'spawn(fun() -> timer:apply_interval(100, queue, new, []), receive after infinity -> ok end end).'

  and run only these tests, connecting without epmd and without listening:

      OLD_OTP_NODE=old@127.0.0.1 OLD_OTP_COOKIE=testcookie \\
        ERL_FLAGS="-erl_epmd_port 9100 -dist_listen false" mix test --only old_otp
  """
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Profiler, Target, Tracer}

  @moduletag :old_otp

  setup do
    {:ok, %{recon: recon}} =
      Target.connect(System.fetch_env!("OLD_OTP_NODE"), System.get_env("OLD_OTP_COOKIE"))

    on_exit(fn -> Checks.remote_eval("dbg:stop().") end)
    %{recon: recon}
  end

  test "the target runs an older OTP release" do
    {:ok, theirs} = Target.rpc(:erlang, :system_info, [:otp_release])
    assert List.to_integer(theirs) < String.to_integer(System.otp_release())
  end

  test "recon is compiled on the target, and every check works", %{recon: recon} do
    # compiled_on_target is only reported by the connect that loads it.
    assert %{source: "injected"} = recon
    {:ok, attributes} = Target.rpc(:recon, :module_info, [:attributes])
    assert Keyword.has_key?(attributes, :otp_debug_mcp_injected)

    for %{check: check, status: status} <- Checks.run_all() do
      assert status != :error, "#{check} failed"
    end
  end

  test "vm_config sees the container's CPU quota, and more schedulers than it" do
    assert {:ok, :warning, f, _} = OtpDebugMcp.VmConfig.run()
    assert f.cpu.cpu_quota == 1.0
    assert f.cpu.schedulers_online == 4

    assert Enum.any?(
             f.notes,
             &(&1 =~ "4 schedulers online, but the container's CPU quota is 1.0 CPUs")
           )

    assert f.limits.open_files.limit > 0
  end

  test "call_latency traces a gen_server in the legacy session, and cleans up" do
    # inet_db is a gen_server every node runs.
    assert {:ok, r} = OtpDebugMcp.CallLatency.run("inet_db", 500, 1_000)
    assert r.trace == "legacy trace session"
    assert r.module == "inet_db"
    assert Tracer.other_tracing() == {:ok, nil}
  end

  test "trace_calls uses recon_trace" do
    assert {:ok, %{events: [_, _, _, _], backend: "recon_trace"}} =
             Tracer.trace("queue", "new", 4, 5_000)
  end

  test "trace_calls refuses while dbg is tracing, unless forced" do
    {:ok, _} = Checks.remote_eval("dbg:tracer(), dbg:p(all, call), dbg:tpl(queue, new, []).")

    assert {:error, %{refused: _, active_tracing: %{traces_new_processes: true}}} =
             Tracer.trace("queue", "new", 4, 5_000)

    assert {:ok, %{events: [_ | _], stopped_other_tracing: %{}}} =
             Tracer.trace("queue", "new", 4, 5_000, force: true)

    assert {:ok, %{events: [_ | _], stopped_other_tracing: nil}} =
             Tracer.trace("queue", "new", 2, 5_000)
  end

  test "long_schedules uses the node's system_monitor, and only when it's free" do
    assert %{findings: %{via: "the node's system_monitor"}} = Checks.run(:long_schedules)
    assert {:ok, :undefined} = Target.rpc(:erlang, :system_monitor, [])

    {:ok, :ok} =
      Checks.remote_eval("""
      register(monitor_holder, spawn(fun() -> timer:sleep(infinity) end)),
      erlang:system_monitor(whereis(monitor_holder), [{long_gc, 1000}]),
      ok.
      """)

    on_exit(fn ->
      Checks.remote_eval("erlang:system_monitor(undefined), exit(whereis(monitor_holder), kill).")
    end)

    assert %{status: :ok, findings: %{skipped: skipped}} = Checks.run(:long_schedules)
    assert skipped =~ "held by"
    {:ok, holder} = Target.rpc(:erlang, :whereis, [:monitor_holder])
    assert {:ok, {^holder, [{:long_gc, 1000}]}} = Target.rpc(:erlang, :system_monitor, [])
  end

  test "port_info, and trace_port in the legacy session, refused while dbg traces" do
    %{findings: %{by_type: [_ | _]}} = Checks.run(:ports)
    {:ok, [port | _]} = Target.rpc(:erlang, :ports, [])
    assert {:ok, %{port: _, name: _}} = OtpDebugMcp.Ports.info(port)

    assert {:ok, %{backend: "legacy trace session"}} = OtpDebugMcp.Ports.trace(:new_ports, 5, 500)

    {:ok, _} = Checks.remote_eval("dbg:tracer(), dbg:p(all, call), dbg:tpl(queue, new, []).")
    assert {:error, %{refused: _}} = OtpDebugMcp.Ports.trace(:new_ports, 5, 500)

    assert {:ok, %{backend: "legacy trace session"}} =
             OtpDebugMcp.Ports.trace(:new_ports, 5, 500, force: true)
  end

  test "module_code reads an older OTP's .beam here" do
    assert {:ok, info} = OtpDebugMcp.ModuleCode.fetch("queue")
    assert info.disassembled == :here
    in2 = Enum.find(info.functions, &(&1.name == :in and &1.arity == 2))
    assert %{written_at: written} = OtpDebugMcp.ModuleCode.origin(info, in2)
    assert written =~ ~r/queue\.erl:\d+$/
  end

  test "profile counts calls in the legacy trace session, and clears up" do
    assert {:ok, %{backend: "legacy" <> _, by_time: rows}} =
             Profiler.profile({:module, "queue", nil}, 1_000)

    # queue:new/0 ten times a second.
    assert %{calls: calls} = Enum.find(rows, &(&1.function == "queue:new/0"))
    assert calls in 5..15

    assert {:ok, {:call_time, false}} =
             Target.rpc(:erlang, :trace_info, [{:queue, :new, 0}, :call_time])
  end

  test "profile refuses while dbg is tracing, unless forced" do
    {:ok, _} = Checks.remote_eval("dbg:tracer(), dbg:p(all, call), dbg:tpl(queue, new, []).")

    assert {:error, %{refused: _, active_tracing: %{traces_new_processes: true}}} =
             Profiler.profile({:module, "queue", nil}, 500)

    assert {:ok, %{by_time: [_ | _]}} =
             Profiler.profile({:module, "queue", nil}, 500, force: true)
  end

  test "recent_errors catches a crash, and removes its handler" do
    {:ok, before} = Target.rpc(:logger, :get_handler_ids, [])

    {:ok, _} =
      Checks.remote_eval(
        "spawn(fun() -> group_leader(whereis(user), self()), timer:sleep(200), " <>
          "proc_lib:spawn(fun() -> lists:nth(5, [a]) end) end)."
      )

    assert {:ok, :window, report} = OtpDebugMcp.Errors.listen(:warning, 1_000)

    assert %{groups: [%{kind: "crash", reason: "function_clause", stack: [_ | _]} | _]} =
             OtpDebugMcp.Errors.summarize(report)

    assert {:ok, ^before} = Target.rpc(:logger, :get_handler_ids, [])
  end

  test "trace_calls with exceptions reports only the calls that raise" do
    {:ok, looper} =
      Checks.remote_eval(
        "spawn(fun() -> group_leader(whereis(user), self()), " <>
          "(fun L(N) -> catch queue:head(case N rem 2 of 0 -> queue:new(); 1 -> queue:from_list([N]) end), " <>
          "timer:sleep(20), L(N + 1) end)(0) end)."
      )

    assert {:ok, %{events: [call, raised]}} =
             Tracer.trace("queue", "head", 2, 5_000, exceptions: true)

    assert call =~ "queue:head({[],[]})"
    assert raised =~ "queue:head/1 raised error:empty"
    Checks.remote_eval("exit(Pid, kill).", Pid: looper)
  end
end
