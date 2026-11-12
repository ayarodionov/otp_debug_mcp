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

  test "the server's instructions name only tools and checks it has" do
    text = OtpDebugMcp.Server.server_instructions()
    tools = MapSet.new(OtpDebugMcp.Server.__components__(:tool), & &1.name)
    checks = MapSet.new(OtpDebugMcp.Checks.all_checks(), &Atom.to_string/1)

    assert text =~ "Then diagnose, always"

    # Every word with an underscore is the name of a tool or of a check.
    for [name] <- Regex.scan(~r/\b[a-z]+(?:_[a-z]+)+\b/, text),
        name not in ["include_state", "gen_server"] do
      assert name in tools or name in checks, "#{name} is neither a tool nor a check"
    end

    for [check] <- Regex.scan(~r/run_check ([a-z_]+)/, text, capture: :all_but_first),
        do: assert(check in checks, "#{check} isn't a check")

    for tool <-
          ~w(phoenix bandit cowboy ranch yaws postgrex mnesia shackle rabbitmq emqx ejabberd),
        do: assert(tool in tools)
  end

  test "a process name that doesn't exist on the target isn't created there", %{target: target} do
    name = "no_such_process_#{System.unique_integer([:positive])}"

    assert {:error, {:no_such_process, ^name}} = Tools.resolve_process(name)
    assert {:error, {:no_such_process, "Nope.Missing"}} = Tools.resolve_process("Nope.Missing")
    assert :error = OtpDebugMcp.Target.existing_atom(name)
    assert :error = OtpDebugMcp.Target.existing_atom("Elixir.Nope.Missing")

    assert {:error, text} = call_tool(Tools.SupervisionTree, %{app: name})
    assert text =~ "app_not_running"
    assert :error = OtpDebugMcp.Target.existing_atom(name)

    # Names that do exist still resolve, Elixir module names as written in Elixir too.
    assert {:ok, pid} = Tools.resolve_process("stuck_mailbox")
    assert is_pid(pid)
    {:ok, named} = TestTarget.call(target, Ticker, :start, [OtpDebugMcp.Fixtures.Named, 1_000])
    assert {:ok, ^named} = Tools.resolve_process("OtpDebugMcp.Fixtures.Named")
    assert {:ok, ^named} = Tools.resolve_process("Elixir.OtpDebugMcp.Fixtures.Named")
  end

  describe "connect" do
    test "reports the connection and recon", %{target: target} do
      params = %{node: Atom.to_string(target.node), cookie: target.cookie}

      assert {:ok, %{"connected" => node, "recon" => %{"source" => "injected"}, "hint" => _}} =
               call_tool_json(Tools.Connect, params)

      assert node == Atom.to_string(target.node)
    end

    test "says how long the node has run", %{target: target} do
      params = %{node: Atom.to_string(target.node), cookie: target.cookie}

      assert {:ok, %{"uptime_seconds" => seconds, "uptime" => text, "uptime_note" => note}} =
               call_tool_json(Tools.Connect, params)

      assert seconds < 600
      assert text =~ ~r/^\d+ (s|min \d+ s)$/
      assert note =~ "previous run"

      assert Tools.duration(45) == "45 s"
      assert Tools.duration(3_725) == "1 h 2 min"
      assert Tools.duration(200_000) == "2 d 7 h"
    end

    test "explains a failure", %{target: target} do
      params = %{node: Atom.to_string(target.node), cookie: "wrong"}
      assert {:error, text} = call_tool(Tools.Connect, params)
      assert text =~ "connection_failed"
      assert text =~ "wrong cookie"
    end
  end

  test "diagnose returns conclusions, the checks that aren't ok, and the names of the rest" do
    assert {:ok, report} = call_tool_json(Tools.Diagnose, %{})

    assert [%{"severity" => "warning", "conclusion" => text, "from" => ["message_queues"]} | _] =
             report["conclusions"]

    assert text =~ "stuck_mailbox"
    assert text =~ "isn't reading its mailbox"

    assert [%{"check" => "message_queues", "status" => "warning", "interpretation" => _} | _] =
             report["findings"]

    refute Enum.any?(report["findings"], &(&1["status"] == "ok"))
    assert "atom_table" in report["ok"]
    assert %{"memory" => _, "processes" => _} = report["vitals"]
  end

  test "diagnose with quick runs only the checks that read the node" do
    assert {:ok, report} = call_tool_json(Tools.Diagnose, %{quick: true})

    assert report["skipped"] == ["binary_leak", "scheduler_time", "long_schedules"]
    ran = Enum.map(report["findings"], & &1["check"]) ++ report["ok"]
    assert "message_queues" in ran
    for check <- report["skipped"], do: refute(check in ran)
    assert is_integer(report["elapsed_ms"]) and report["elapsed_ms"] > 0

    # No trace session to find who sends to the long mailbox.
    assert %{"findings" => [%{"senders" => senders}]} =
             Enum.find(report["findings"], &(&1["check"] == "message_queues"))

    assert senders =~ "quick"
    assert [%{"conclusion" => text} | _] = report["conclusions"]
    assert text =~ "Who fills it wasn't measured, as diagnose ran with quick."
  end

  test "diagnose with verbose returns every check in full" do
    assert {:ok, %{"conclusions" => [_ | _], "checks" => checks}} =
             call_tool_json(Tools.Diagnose, %{verbose: true})

    assert [%{"check" => "message_queues", "status" => "warning"} | _] = checks
    assert Enum.any?(checks, &(&1["status"] == "ok" and is_binary(&1["interpretation"])))
  end

  test "pids are printed as the target prints them, and are accepted as input" do
    {:ok, %{"findings" => [%{"check" => "message_queues", "findings" => [%{"pid" => pid}]} | _]}} =
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

  test "process_info on a plain Erlang node answers in Erlang syntax" do
    erlang = TestTarget.start(erlang: true)
    on_exit(fn -> TestTarget.stop(erlang) end)
    {:ok, _} = TestTarget.connect(erlang)

    assert {:ok, %{"info" => info}} = call_tool_json(Tools.ProcessInfo, %{pid: "init"})
    assert info =~ "{registered_name,init}"
    refute info =~ "%{"
    refute info =~ ":init"
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

    test "takes a quoted name, and answers with the pid and binary memory" do
      assert {:ok, result} = call_tool_json(Tools.ProcessInfo, %{pid: "'stuck_mailbox'"})

      assert %{"pid" => "<0." <> _, "name" => "'stuck_mailbox'", "binary_memory_bytes" => _} =
               result
    end

    test "won't ask a process that isn't an OTP behaviour for its state", %{target: target} do
      :ok = TestTarget.call(target, OtpDebugMcp.Fixtures.Fussy, :start, [:fussy, 1])

      assert {:ok, %{"state" => "skipped: " <> _}} =
               call_tool_json(Tools.ProcessInfo, %{pid: "fussy", include_state: true})

      assert is_pid(TestTarget.call(target, :erlang, :whereis, [:fussy]))
    end

    test "summarizes the state it fetches" do
      assert {:ok, %{"state_summary" => %{"kind" => _, "words" => _}}} =
               call_tool_json(Tools.ProcessInfo, %{pid: "ticker", include_state: true})
    end

    test "says when state wasn't requested" do
      assert {:ok, %{"state" => "not requested" <> _}} =
               call_tool_json(Tools.ProcessInfo, %{pid: "ticker"})
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

    test "shows each supervisor's name, strategy and restart history" do
      assert {:ok, root} = call_tool_json(Tools.SupervisionTree, %{app: "fixture_app"})

      assert %{"strategy" => "one_for_one", "kind" => "static", "restarts" => restarts} = root
      assert %{"max_restarts" => 3, "max_seconds" => 5, "restarts_in_window" => 0} = restarts

      pool = Enum.find(root["children"], &(&1["type"] == "supervisor"))

      assert %{"name" => "OtpDebugMcp.Fixtures.Pool", "kind" => "dynamic", "restarts" => %{}} =
               pool
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
    assert result["stopped_by"] =~ "max_events"
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
