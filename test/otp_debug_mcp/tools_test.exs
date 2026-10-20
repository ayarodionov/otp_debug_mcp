defmodule OtpDebugMcp.ToolsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.{App, Mailbox, Ticker}

  setup_all do
    target = TestTarget.start()
    {:ok, _} = TestTarget.call(target, Ticker, :start, [:ticker, 50])
    _ = TestTarget.call(target, Mailbox, :start, [:stuck_mailbox, 2_000])
    :ok = TestTarget.call(target, App, :start, [60])
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  describe "connect" do
    test "reports the connection and recon", %{target: target} do
      params = %{node: Atom.to_string(target.node), cookie: target.cookie}

      assert {:ok, %{"connected" => node, "recon" => %{"source" => "injected"}, "hint" => _}} =
               call_tool_json(Tools.Connect, params)

      assert node == Atom.to_string(target.node)
    end

    test "explains a failure", %{target: target} do
      params = %{node: Atom.to_string(target.node), cookie: "wrong"}
      assert {:error, text} = call_tool(Tools.Connect, params)
      assert text =~ "connection_failed"
      assert text =~ "wrong cookie"
    end
  end

  test "diagnose returns ranked findings as JSON" do
    assert {:ok, [%{"check" => "message_queues", "status" => "warning"} | _]} =
             call_tool_json(Tools.Diagnose, %{})
  end

  test "pids are printed as the target prints them, and are accepted as input" do
    {:ok, [%{"check" => "message_queues", "findings" => [%{"pid" => pid}]} | _]} =
      call_tool_json(Tools.Diagnose, %{})

    assert pid =~ ~r/^<0\.\d+\.\d+>$/

    assert {:ok, %{"info" => info}} = call_tool_json(Tools.ProcessInfo, %{pid: pid})
    assert info =~ ~r/<0\.\d+\.\d+>/
    refute info =~ "#PID"

    assert {:ok, %{"supervisor" => sup}} =
             call_tool_json(Tools.SupervisionTree, %{app: "fixture_app"})

    assert sup =~ ~r/^<0\.\d+\.\d+>$/

    assert {:ok, %{"events" => [event | _]}} =
             call_tool_json(Tools.TraceCalls, %{
               module: "OtpDebugMcp.Fixtures.Ticker",
               max_events: 2
             })

    [_, ticker_pid] = Regex.run(~r/ (<0\.\d+\.\d+>) /, event)

    assert {:ok, %{"info" => ticker_info}} =
             call_tool_json(Tools.ProcessInfo, %{pid: ticker_pid})

    assert ticker_info =~ "registered_name: :ticker"
  end

  test "run_check rejects an unknown check" do
    assert {:error, text} = call_tool(Tools.RunCheck, %{check: "nope"})
    assert text =~ "unknown_check"
  end

  describe "process_info" do
    test "accepts a registered name, including Elixir module names" do
      assert {:ok, %{"info" => info}} = call_tool_json(Tools.ProcessInfo, %{pid: "stuck_mailbox"})
      assert info =~ "message_queue_len"

      assert {:ok, %{"info" => _}} =
               call_tool_json(Tools.ProcessInfo, %{pid: "OtpDebugMcp.Fixtures.Pool"})
    end

    test "accepts pids as the target prints them and as our tools print them", %{target: target} do
      pid = TestTarget.call(target, :erlang, :whereis, [:ticker])
      remote_form = TestTarget.call(target, :erlang, :pid_to_list, [pid]) |> to_string()
      assert remote_form =~ ~r/^<0\.\d+\.0>$/

      for form <- [remote_form, inspect(pid)] do
        assert {:ok, %{"info" => _}} = call_tool_json(Tools.ProcessInfo, %{pid: form})
      end
    end

    test "estimates the process's age and reports its supervisor", %{target: target} do
      [{_, worker, _, _} | _] =
        TestTarget.call(target, DynamicSupervisor, :which_children, [OtpDebugMcp.Fixtures.Pool])

      pid = TestTarget.call(target, :erlang, :pid_to_list, [worker]) |> to_string()

      assert {:ok, %{"age" => age, "supervisor" => sup}} =
               call_tool_json(Tools.ProcessInfo, %{pid: pid})

      assert %{"estimated_seconds" => _, "younger_than_seconds" => _, "how" => _} = age

      assert %{
               "supervisor" => "OtpDebugMcp.Fixtures.Pool",
               "kind" => "dynamic",
               "child_id" => nil
             } =
               sup
    end

    test "fetches gen_server state" do
      assert {:ok, %{"state" => state}} =
               call_tool_json(Tools.ProcessInfo, %{pid: "ticker", include_state: true})

      assert state =~ ~r/^\d+$/
    end

    test "reports an unknown process" do
      assert {:error, text} = call_tool(Tools.ProcessInfo, %{pid: "no_such_process"})
      assert text =~ "no_such_process"
    end
  end

  describe "supervision_tree" do
    test "renders nested supervisors and caps long child lists" do
      assert {:ok, %{"children" => children}} =
               call_tool_json(Tools.SupervisionTree, %{app: "fixture_app"})

      pool = Enum.find(children, &(&1["type"] == "supervisor"))
      assert pool["child_count"] == 60
      assert length(pool["children"]) == 50
      assert pool["note"] =~ "first 50"
      assert Enum.count(children, &(&1["type"] == "worker")) == 2
    end

    test "stops at the depth limit" do
      assert {:ok, %{"children" => children}} =
               call_tool_json(Tools.SupervisionTree, %{app: "fixture_app", depth: 1})

      pool = Enum.find(children, &(&1["type"] == "supervisor"))
      assert pool["children"] =~ "depth limit"
    end

    test "reports an application that isn't running" do
      assert {:error, text} = call_tool(Tools.SupervisionTree, %{app: "no_such_app"})
      assert text =~ "app_not_running"
    end
  end

  test "trace_calls returns events and the backend, without empty keys" do
    assert {:ok, result} =
             call_tool_json(Tools.TraceCalls, %{
               module: "OtpDebugMcp.Fixtures.Ticker",
               max_events: 2
             })

    assert %{"events" => [_, _], "backend" => "isolated trace session"} = result
    refute Map.has_key?(result, "stopped_other_tracing")
  end

  test "snapshot rejects an unknown action" do
    assert {:error, text} = call_tool(Tools.Snapshot, %{action: "nope"})
    assert text =~ "unknown_action"
  end

  describe "remote_eval" do
    test "is disabled by default" do
      assert {:error, text} = call_tool(Tools.RemoteEval, %{code: "1 + 1."})
      assert text =~ "disabled"
    end

    test "when enabled, answers in Erlang syntax and explains errors" do
      System.put_env("OTP_DEBUG_MCP_ALLOW_EVAL", "true")
      on_exit(fn -> System.delete_env("OTP_DEBUG_MCP_ALLOW_EVAL") end)

      assert {:ok, %{"value" => "{ok,[1,2]}"}} =
               call_tool_json(Tools.RemoteEval, %{code: "{ok, [1, 2]}."})

      assert {:ok, %{"value" => pid}} =
               call_tool_json(Tools.RemoteEval, %{code: "whereis(init)."})

      assert pid =~ ~r/^<0\.\d+\.\d+>$/

      assert {:error, "syntax error: " <> _} = call_tool(Tools.RemoteEval, %{code: "{ok,"})

      assert {:error, "evaluation raised: badarith"} =
               call_tool(Tools.RemoteEval, %{code: "1 / 0."})
    end
  end
end
