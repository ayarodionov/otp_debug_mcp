defmodule OtpDebugMcp.TracerTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Target, TestTarget, Tracer}
  alias OtpDebugMcp.Fixtures.{CrashSup, Operator, Ticker}

  @ticker "OtpDebugMcp.Fixtures.Ticker"

  # Both targets tick 20 times a second. The second one also has an
  # operator's recon_trace session on the ticker, at 10 calls a second so
  # that it stays under its own {50, 1000} rate limit.
  setup_all do
    plain = TestTarget.start()
    {:ok, _} = TestTarget.call(plain, Ticker, :start, [:ticker, 50])

    on_exit(fn -> TestTarget.stop(plain) end)
    %{plain: plain}
  end

  defp operator_target do
    target = TestTarget.start(recon: true)
    {:ok, _} = TestTarget.call(target, Ticker, :start, [:ticker, 100])
    :ok = TestTarget.call(target, Operator, :start, [{Ticker, :handle_info, :_}])
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    target
  end

  # A child that raises in handle_info 200ms after each start.
  defp crashing_target do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    opts = [max_restarts: 1_000, max_seconds: 5]
    :ok = TestTarget.call(target, CrashSup, :start, [:crash_sup, [{:looper, 200}], opts])
    {:ok, _} = TestTarget.connect(target)
    target
  end

  defp assert_exception_event(backend) do
    assert {:ok, %{events: events}} =
             Tracer.trace("OtpDebugMcp.Fixtures.Crasher", "handle_info", 2, 5_000,
               backend: backend
             )

    assert [call, raised] = events
    assert call =~ "handle_info(crash"
    assert raised =~ ~r/handle_info\/2 .*error/
    assert raised =~ "'Elixir.ArgumentError'"
    assert raised =~ "crash loop fixture"
    refute raised =~ "\n"
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  describe "isolated trace session (OTP 27+)" do
    setup %{plain: plain} do
      {:ok, _} = TestTarget.connect(plain)
      :ok
    end

    test "returns call and return events, one per line" do
      assert {:ok, %{events: events, backend: "isolated trace session"}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000)

      assert [call, ret, _, _] = events
      assert call =~ ~r/^\d{2}:\d{2}:\d{2}\.\d{6}Z /

      assert call =~
               ~r/<0\.\d+\.0> 'Elixir.OtpDebugMcp.Fixtures.Ticker':handle_info\(tick, \d+\)$/

      assert ret =~ ~r/handle_info\/2 --> \{noreply,\d+\}$/
      refute Enum.any?(events, &String.contains?(&1, "\n"))
    end

    test "returns as soon as max_events have arrived" do
      {ms, {:ok, %{events: events}}} = timed(fn -> Tracer.trace(@ticker, nil, 2, 10_000) end)
      assert length(events) == 2
      assert ms < 2_000
    end

    test "stops at the duration when nothing is called" do
      {ms, {:ok, %{events: []}}} = timed(fn -> Tracer.trace(@ticker, "init", 5, 500) end)
      assert ms < 2_000
    end

    test "destroys its session afterwards" do
      {:ok, _} = Tracer.trace(@ticker, "handle_info", 2, 5_000)
      {:ok, sessions} = Target.rpc(:trace, :session_info, [:all])
      refute inspect(sessions) =~ "otp_debug_mcp"
    end

    test "fails at once for a function that doesn't exist" do
      {ms, {:error, message}} = timed(fn -> Tracer.trace(@ticker, "nope", 5, 10_000) end)
      assert message =~ "no function in OtpDebugMcp.Fixtures.Ticker matches nope"
      assert ms < 2_000
    end

    test "fails for a module that isn't loaded" do
      assert {:error, {:module_not_loaded_on_target, "No.Such.Module"}} =
               Tracer.trace("No.Such.Module", nil, 5, 1_000)
    end

    test "reports exceptions" do
      crashing_target()
      assert_exception_event(:auto)
    end

    test "leaves an operator's recon_trace session on the same function running" do
      target = operator_target()

      assert {:ok, %{events: [_ | _], backend: "isolated trace session"}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000)

      assert TestTarget.call(target, Operator, :alive?, [])
      before = TestTarget.call(target, Operator, :lines, [])
      Process.sleep(300)
      assert TestTarget.call(target, Operator, :lines, []) > before
    end
  end

  describe "recon_trace backend (before OTP 27)" do
    test "traces when nothing else is tracing", %{plain: plain} do
      {:ok, _} = TestTarget.connect(plain)

      assert {:ok, %{events: [_, _, _, _], backend: "recon_trace", stopped_other_tracing: nil}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000, backend: :recon_trace)

      # Our own trace is fully gone, so a second one isn't refused.
      assert {:ok, %{events: [_ | _]}} =
               Tracer.trace(@ticker, "handle_info", 2, 5_000, backend: :recon_trace)
    end

    test "reports exceptions" do
      crashing_target()
      assert_exception_event(:recon_trace)
    end

    test "refuses while an operator's recon_trace session runs, unless forced" do
      target = operator_target()

      assert {:error, %{refused: _, active_tracing: active, next_step: next_step}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000, backend: :recon_trace)

      assert active.recon_trace_session
      assert next_step =~ "force: true"
      assert TestTarget.call(target, Operator, :alive?, [])

      assert {:ok, %{events: [_ | _], stopped_other_tracing: %{recon_trace_session: true}}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000, backend: :recon_trace, force: true)

      refute TestTarget.call(target, Operator, :alive?, [])
    end

    test "detects tracing set up with erlang:trace/3", %{plain: plain} do
      {:ok, _} = TestTarget.connect(plain)
      tracer = TestTarget.call(plain, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      traced = TestTarget.call(plain, :erlang, :whereis, [:ticker])
      1 = TestTarget.call(plain, :erlang, :trace, [traced, true, [:call, {:tracer, tracer}]])
      on_exit(fn -> TestTarget.call(plain, :erlang, :trace, [traced, false, [:all]]) end)

      assert {:error, %{active_tracing: %{traced_processes: 1}}} =
               Tracer.trace(@ticker, "handle_info", 4, 5_000, backend: :recon_trace)
    end
  end
end
