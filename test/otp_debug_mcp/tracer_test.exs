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

  describe "exceptions only" do
    @parser "OtpDebugMcp.Fixtures.Parser"

    setup %{plain: plain} do
      :ok =
        TestTarget.call(plain, OtpDebugMcp.Fixtures.Parser, :start, [
          :"parser_#{System.unique_integer([:positive])}",
          10
        ])

      {:ok, _} = TestTarget.connect(plain)
      :ok
    end

    defp assert_only_failing_calls(events) do
      assert [call, raised, _, _] = events
      assert call =~ ~s|quantity(<<"n/a">>)|
      assert raised =~ ~r"quantity/1 raised error:"
      assert raised =~ "badarg"

      for {line, i} <- Enum.with_index(events),
          rem(i, 2) == 0,
          do: assert(line =~ "n/a", "a call that didn't raise: #{line}")
    end

    test "in a trace session, and nothing is left behind", %{plain: plain} do
      assert {:ok, %{events: events, backend: "isolated trace session"}} =
               Tracer.trace(@parser, "quantity", 4, 5_000, exceptions: true)

      assert_only_failing_calls(events)
      sessions = TestTarget.call(plain, :trace, :session_info, [:all])
      refute Enum.any?(sessions, &match?({:otp_debug_mcp_exceptions, _}, &1))
    end

    test "in the legacy session, which it clears", %{plain: plain} do
      assert {:ok, %{events: events, backend: "legacy trace session"}} =
               Tracer.trace(@parser, "quantity", 4, 5_000,
                 exceptions: true,
                 backend: :recon_trace
               )

      assert_only_failing_calls(events)

      mfa = {OtpDebugMcp.Fixtures.Parser, :quantity, 1}
      assert TestTarget.call(plain, :erlang, :trace_info, [mfa, :traced]) == {:traced, false}
      assert {:ok, nil} = Tracer.other_tracing()
    end

    # Two parsers, of which only the first is traced.
    defp two_parsers(plain) do
      for _ <- 1..2 do
        name = :"parser_#{System.unique_integer([:positive])}"
        :ok = TestTarget.call(plain, OtpDebugMcp.Fixtures.Parser, :start, [name, 10])
        TestTarget.call(plain, :erlang, :whereis, [name])
      end
    end

    # A pid as the target prints it, <0.N.0>, from ours.
    defp printed(pid), do: String.replace(inspect(pid), ~r/^#PID<\d+\./, "<0.")

    # Elixir inlines String.to_integer/1, and quantity/1 tail-calls it: the
    # BIF raises, with its argument, called from loop/2, at its line.
    defp assert_failure_chain(events, pid) do
      assert [bif, raised | _] = events
      assert bif =~ ~s|erlang:binary_to_integer(<<"n/a">>) from |
      # With its line in a trace session (caller_line), not in the legacy one.
      assert bif =~ ~r"Parser':loop/2( \(test/support/fixtures.ex:\d+\))?$"
      assert raised =~ "erlang:binary_to_integer/1 raised error:badarg"
      assert Enum.all?(events, &(&1 =~ " #{printed(pid)} ")), "events of another process"
    end

    test "one process's exceptions, in every function it calls", %{plain: plain} do
      [traced, _other] = two_parsers(plain)

      assert {:ok, %{events: events, backend: "isolated trace session"}} =
               Tracer.trace(nil, nil, 6, 5_000, exceptions: true, process: traced)

      assert_failure_chain(events, traced)
      assert hd(events) =~ "fixtures.ex:"
      sessions = TestTarget.call(plain, :trace, :session_info, [:all])
      refute Enum.any?(sessions, &match?({:otp_debug_mcp_exceptions, _}, &1))
    end

    test "one process's exceptions in the legacy session, which it clears", %{plain: plain} do
      [traced, _other] = two_parsers(plain)

      assert {:ok, %{events: events, backend: "legacy trace session"}} =
               Tracer.trace(nil, nil, 6, 5_000,
                 exceptions: true,
                 process: traced,
                 backend: :recon_trace
               )

      assert_failure_chain(events, traced)

      assert TestTarget.call(plain, :erlang, :trace_info, [
               {:erlang, :binary_to_integer, 1},
               :traced
             ]) == {:traced, false}

      assert {:ok, nil} = Tracer.other_tracing()
    end

    test "one process's calls to a module", %{plain: plain} do
      [traced, _other] = two_parsers(plain)

      for backend <- [:auto, :recon_trace] do
        assert {:ok, %{events: [_ | _] = events}} =
                 Tracer.trace(@parser, "quantity", 8, 2_000, process: traced, backend: backend)

        assert Enum.all?(events, &(&1 =~ " #{printed(traced)} ")), "events of another process"
      end
    end

    test "the tool: a process by name, with no module", %{plain: plain} do
      name = :"parser_#{System.unique_integer([:positive])}"
      :ok = TestTarget.call(plain, OtpDebugMcp.Fixtures.Parser, :start, [name, 10])
      trace = &OtpDebugMcp.ToolCase.call_tool_json(OtpDebugMcp.Tools.TraceCalls, &1)

      assert {:ok, result} =
               trace.(%{process: Atom.to_string(name), exceptions: true, max_events: 2})

      assert [_, _] = result["events"]
      assert result["traced"] =~ "every exported function and BIF"

      assert {:error, text} =
               OtpDebugMcp.ToolCase.call_tool(OtpDebugMcp.Tools.TraceCalls, %{exceptions: true})

      assert text =~ "a module is needed"

      assert {:error, text} =
               OtpDebugMcp.ToolCase.call_tool(OtpDebugMcp.Tools.TraceCalls, %{
                 process: "no_such_parser",
                 exceptions: true
               })

      assert text =~ "no_such_parser"
    end

    test "every function only for one process's exceptions", %{plain: plain} do
      [traced, _other] = two_parsers(plain)
      assert {:error, text} = Tracer.trace(nil, nil, 4, 1_000, exceptions: true)
      assert text =~ "a module is needed"
      assert {:error, _} = Tracer.trace(nil, nil, 4, 1_000, process: traced)

      dead = TestTarget.call(plain, :erlang, :spawn, [:erlang, :now, []])
      assert {:error, "process " <> _} = Tracer.trace(@parser, nil, 4, 1_000, process: dead)
    end

    test "the legacy session refuses while others trace, unless forced" do
      operator_target()

      assert {:error, %{refused: _, active_tracing: %{recon_trace_session: true}}} =
               Tracer.trace(@ticker, "handle_info", 4, 1_000,
                 exceptions: true,
                 backend: :recon_trace
               )
    end
  end
end
