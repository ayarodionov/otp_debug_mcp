defmodule OtpDebugMcp.NewOtpTest do
  @moduledoc """
  Against a node running a newer OTP release than this one, whose .beam
  files this node's beam_disasm can't read. Start one in Docker, calling
  queue:new/0 ten times a second:

      docker run -d --rm --name otp29 -p 9101:9101 erlang:29-slim \\
        erl -noinput -name new@127.0.0.1 -setcookie testcookie -erl_epmd_port 9101 \\
        -eval 'spawn(fun() -> timer:apply_interval(100, queue, new, []), receive after infinity -> ok end end).'

  and run only these tests, connecting without epmd and without listening:

      NEW_OTP_NODE=new@127.0.0.1 NEW_OTP_COOKIE=testcookie \\
        ERL_FLAGS="-erl_epmd_port 9101 -dist_listen false" mix test --only new_otp
  """
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, ModuleCode, Profiler, Target, Tracer}

  @moduletag :new_otp

  setup do
    {:ok, _} =
      Target.connect(System.fetch_env!("NEW_OTP_NODE"), System.get_env("NEW_OTP_COOKIE"))

    :ok
  end

  test "the target runs a newer OTP release" do
    {:ok, theirs} = Target.rpc(:erlang, :system_info, [:otp_release])
    assert List.to_integer(theirs) > String.to_integer(System.otp_release())
  end

  test "every check works" do
    for %{check: check, status: status} <- Checks.run_all() do
      assert status != :error, "#{check} failed"
    end
  end

  test "trace_calls and profile work in their own trace sessions" do
    assert {:ok, %{events: [_, _ | _], backend: "isolated trace session"}} =
             Tracer.trace("queue", "new", 4, 5_000)

    assert {:ok, %{backend: "isolated trace session", by_time: rows}} =
             Profiler.profile({:module, "queue", nil}, 1_000)

    assert Enum.any?(rows, &(&1.function == "queue:new/0"))
  end

  test "module_code has the node disassemble what this node can't" do
    assert {:ok, info} = ModuleCode.fetch("queue")
    assert info.disassembled == :target
    # queue:new/0 has no line: nothing in it can fail. in/2 has.
    in2 = Enum.find(info.functions, &(&1.name == :in and &1.arity == 2))
    assert %{written_at: written} = ModuleCode.origin(info, in2)
    assert written =~ ~r/queue\.erl:\d+$/
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
