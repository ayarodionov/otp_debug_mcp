defmodule OtpDebugMcp.ReadOnlyTest do
  # Read-only mode and the audit log: both are settings of the server, read
  # from its environment on every call.
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.Mailbox

  setup_all do
    target = TestTarget.start()
    _ = TestTarget.call(target, Mailbox, :start, [:stuck_mailbox, 3_000])
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp read_only(fun) do
    System.put_env("OTP_DEBUG_MCP_READ_ONLY", "true")

    try do
      fun.()
    after
      System.delete_env("OTP_DEBUG_MCP_READ_ONLY")
    end
  end

  describe "read-only mode" do
    test "refuses every step that changes the node, and says what still works", %{
      target: target
    } do
      read_only(fn ->
        for {tool, params} <- [
              {Tools.RunCheck, %{check: "binary_leak"}},
              {Tools.RunCheck, %{check: "long_schedules"}},
              {Tools.ProcessInfo, %{pid: "stuck_mailbox", include_state: true}},
              {Tools.TraceCalls, %{module: "lists", function: "seq"}},
              {Tools.Record, %{}},
              {Tools.RemoteEval, %{code: "1 + 1."}},
              {Tools.LoadModule, %{revert: "lists"}}
            ] do
          assert {:error, text} = call_tool(tool, params), inspect(tool)
          assert text =~ "Read-only mode (OTP_DEBUG_MCP_READ_ONLY=true)"
          assert text =~ "Nothing was run."
          assert text =~ "What only reads still works"
        end

        # Nothing was left on the node.
        assert {:ok, :undefined} =
                 OtpDebugMcp.Target.rpc(:erlang, :whereis, [:otp_debug_mcp_recorder])

        # Connecting still works, and says the server is read-only.
        assert {:ok, %{"read_only" => note}} =
                 call_tool_json(Tools.Connect, %{
                   node: Atom.to_string(target.node),
                   cookie: target.cookie
                 })

        assert note =~ "steps that change something on the node are refused"
      end)
    end

    test "diagnose and the mailbox check run without changing anything" do
      read_only(fn ->
        assert {:ok, report} = call_tool_json(Tools.Diagnose, %{})
        assert report["skipped"] == ["binary_leak", "scheduler_time", "long_schedules"]

        assert {:ok, %{"findings" => [%{"senders" => senders}]}} =
                 call_tool_json(Tools.RunCheck, %{check: "message_queues"})

        assert senders =~ "read-only"

        # What only reads runs.
        assert {:ok, _} = call_tool_json(Tools.ProcessInfo, %{pid: "stuck_mailbox"})
        assert {:error, text} = call_tool(Tools.History, %{})
        assert text =~ "No recorder"
      end)
    end
  end

  describe "the audit log" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "otpdbg_audit_#{System.unique_integer([:positive])}.jsonl")

      System.put_env("OTP_DEBUG_MCP_AUDIT_LOG", path)

      on_exit(fn ->
        System.put_env("OTP_DEBUG_MCP_AUDIT_LOG", "off")
        File.rm(path)
      end)

      %{path: path}
    end

    defp lines(path),
      do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    test "records every call: what, where, its effect and what came of it", %{
      path: path,
      target: target
    } do
      node = Atom.to_string(target.node)
      {:ok, _} = call_tool_json(Tools.Connect, %{node: node, cookie: target.cookie})
      {:ok, _} = call_tool_json(Tools.RunCheck, %{check: "atom_table"})
      {:error, _} = call_tool(Tools.ProcessInfo, %{pid: "no_such_process"})
      read_only(fn -> {:error, _} = call_tool(Tools.Record, %{minutes: 5}) end)

      assert [connect, check, missing, refused] = lines(path)

      assert %{"tool" => "connect", "node" => ^node, "effect" => "changes", "outcome" => "ran"} =
               connect

      # The cookie is never written.
      assert connect["arguments"]["cookie"] == "(given, not recorded)"
      refute File.read!(path) =~ target.cookie

      assert %{
               "tool" => "run_check",
               "arguments" => %{"check" => "atom_table"},
               "effect" => "read",
               "outcome" => "ran",
               "node" => ^node,
               "at" => at,
               "ms" => ms
             } = check

      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert is_integer(ms)
      assert %{"tool" => "process_info", "outcome" => "failed"} = missing

      assert %{"tool" => "record", "outcome" => "refused: read-only mode", "effect" => "changes"} =
               refused
    end

    test "asks and declines are recorded as such", %{path: path} do
      System.put_env("OTP_DEBUG_MCP_CONFIRM", "all")
      on_exit(fn -> System.delete_env("OTP_DEBUG_MCP_CONFIRM") end)

      # A client that can't show a dialog: refused, and recorded.
      {:error, _} = call_tool(Tools.RunCheck, %{check: "atom_table"})
      assert [%{"outcome" => "refused: the client can't ask the user"}] = lines(path)
    end

    test "off writes nothing, and a file it can't write fails no call", %{path: path} do
      System.put_env("OTP_DEBUG_MCP_AUDIT_LOG", "off")
      {:ok, _} = call_tool_json(Tools.RunCheck, %{check: "atom_table"})
      refute File.exists?(path)

      System.put_env("OTP_DEBUG_MCP_AUDIT_LOG", "/dev/null/not/a/dir/audit.jsonl")
      assert {:ok, _} = call_tool_json(Tools.RunCheck, %{check: "atom_table"})
    end
  end
end
