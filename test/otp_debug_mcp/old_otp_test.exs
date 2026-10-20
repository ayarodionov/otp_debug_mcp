defmodule OtpDebugMcp.OldOtpTest do
  @moduledoc """
  Against a node running an older OTP release than this one, which can't
  load our compiled recon and has no trace sessions. Start one in Docker,
  calling queue:new/0 ten times a second:

      docker run -d --rm --name otp26 -p 9100:9100 erlang:26-slim \\
        erl -noinput -name old@127.0.0.1 -setcookie testcookie -erl_epmd_port 9100 \\
        -eval 'spawn(fun() -> timer:apply_interval(100, queue, new, []), receive after infinity -> ok end end).'

  and run only these tests, connecting without epmd and without listening:

      OLD_OTP_NODE=old@127.0.0.1 OLD_OTP_COOKIE=testcookie \\
        ERL_FLAGS="-erl_epmd_port 9100 -dist_listen false" mix test --only old_otp
  """
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, Target, Tracer}

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
end
