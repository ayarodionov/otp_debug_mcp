defmodule OtpDebugMcp.ErrorsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, Errors, TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.CrashSup

  setup_all do
    elixir = TestTarget.start()
    erlang = TestTarget.start(erlang: true)

    on_exit(fn ->
      TestTarget.stop(elixir)
      TestTarget.stop(erlang)
    end)

    %{elixir: elixir, erlang: erlang}
  end

  defp recent_errors(params), do: call_tool_json(Tools.RecentErrors, params)

  # Run `code` on the target `ms` from now, while the tool listens, in a
  # process of its own there: logger sends the events of a process whose
  # group leader is on another node to that node too.
  defp later(ms, code) do
    {:ok, _} =
      Checks.remote_eval(
        "spawn(fun() -> group_leader(whereis(user), self()), timer:sleep(#{ms}), #{code} end)."
      )
  end

  defp handlers(target),
    do: target |> TestTarget.call(:logger, :get_handler_ids, []) |> Enum.sort()

  describe "on an Elixir node" do
    setup %{elixir: elixir} do
      {:ok, _} = TestTarget.connect(elixir)
      # The node's own console handler would print every error in the test output.
      _ = TestTarget.call(elixir, :logger, :remove_handler, [:default])
      :ok
    end

    test "groups a crash loop's reports by who crashed and why", %{elixir: elixir} do
      before = handlers(elixir)

      :ok =
        TestTarget.call(elixir, CrashSup, :start, [
          :loop_sup,
          [{:looper, 200}],
          [max_restarts: 100]
        ])

      # CrashSup silences the node; this test needs its errors.
      :ok = TestTarget.call(elixir, :logger, :set_primary_config, [:level, :notice])

      assert {:ok, result} = recent_errors(%{duration_ms: 1_500})
      assert result["listened_ms"] == 1_500
      assert [crash | _] = result["groups"]
      assert crash["kind"] == "crash"
      assert crash["level"] == "error"
      assert crash["reason"] =~ "ArgumentError: crash loop fixture"
      assert crash["events"] >= 4
      # A new process each time: the supervisor restarts it.
      assert crash["processes"] >= 4
      assert crash["reports"]["gen_server terminated"] >= 4
      assert [top | _] = crash["stack"]
      assert top =~ "OtpDebugMcp.Fixtures.Crasher.handle_info/2"
      assert crash["example"] =~ "crash loop fixture"

      # The handler is gone once the window ends.
      assert handlers(elixir) == before
    end

    test "groups log messages by where they were logged and what they say" do
      later(100, ~S'[logger:warning("upstream slow: ~p ms", [N]) || N <- [120, 340, 95]]')

      assert {:ok, result} = recent_errors(%{duration_ms: 600})
      assert [group] = for(g <- result["groups"], (g["message"] || "") =~ "upstream slow", do: g)
      assert group["kind"] == "log"
      assert group["level"] == "warning"
      assert group["events"] == 3
      assert group["message"] =~ "upstream slow: 95 ms"
      assert result["by_level"]["warning"] >= 3
    end

    test "warnings are left out at level error" do
      later(100, ~S|logger:warning("just a warning"), logger:error("a real error")|)

      assert {:ok, result} = recent_errors(%{duration_ms: 600, level: "error"})
      messages = Enum.map(result["groups"], & &1["message"])
      assert "a real error" in messages
      refute "just a warning" in messages
    end

    test "a background watch keeps listening until stopped", %{elixir: elixir} do
      before = handlers(elixir)

      assert {:ok, %{"watching" => "warning and above, for 5 min"}} =
               recent_errors(%{watch_minutes: 5})

      assert :otp_debug_mcp_errors in handlers(elixir)
      later(0, ~S|logger:error("while watching")|)
      Process.sleep(200)

      # A plain call reads the watch, without waiting.
      {micros, {:ok, read}} = :timer.tc(fn -> recent_errors(%{duration_ms: 10_000}) end)
      assert micros < 5_000_000
      assert read["note"] =~ "background watch"
      assert Enum.any?(read["groups"], &(&1["message"] == "while watching"))

      assert {:ok, stopped} = recent_errors(%{stop: true})
      assert stopped["stopped"] == true
      assert Enum.any?(stopped["groups"], &(&1["message"] == "while watching"))
      assert handlers(elixir) == before

      assert {:error, "no watch is running on this node"} =
               call_tool(Tools.RecentErrors, %{stop: true})
    end

    test "a killed watch's handler is removed", %{elixir: elixir} do
      before = handlers(elixir)
      {:ok, :started} = Errors.start(:warning, 60_000)
      assert :otp_debug_mcp_errors in handlers(elixir)

      {:ok, true} = Checks.remote_eval("exit(whereis(otp_debug_mcp_errors), kill).")
      Process.sleep(200)
      assert handlers(elixir) == before
    end
  end

  describe "on an Erlang node" do
    setup %{erlang: erlang} do
      {:ok, _} = TestTarget.connect(erlang)
      _ = TestTarget.call(erlang, :logger, :remove_handler, [:default])
      :ok
    end

    test "crash reports and a plain process's crash, in Erlang syntax" do
      later(
        100,
        "proc_lib:spawn(fun() -> lists:nth(5, [a]) end), spawn(fun() -> erlang:error({bad, 42}) end)"
      )

      assert {:ok, result} = recent_errors(%{duration_ms: 800})
      crashes = for g <- result["groups"], g["kind"] == "crash", into: %{}, do: {g["reason"], g}

      assert %{"reports" => %{"crash report" => 1}, "stack" => [nth | _]} =
               crashes["function_clause"]

      assert nth =~ "lists:nth_1/2"
      assert crashes["function_clause"]["called_with"] == "[4,[]]"
      assert %{"reports" => %{"process crashed" => 1}} = crashes["{bad,42}"]
    end
  end

  test "log files: the newest error entries, whatever the format" do
    otp = """
    2026-10-24T10:00:00.000000+00:00 info: started
    2026-10-24T10:00:01.000000+00:00 error: crasher:
        initial call: foo:init/1
        pid: <0.90.0>
    2026-10-24T10:00:02.000000+00:00 warning: slow
    """

    assert [
             %{level: :info},
             %{level: :error, text: "2026-10-24T10:00:01" <> _ = crash},
             %{level: :warning}
           ] = Errors.log_entries(otp)

    assert crash =~ "pid: <0.90.0>"

    elixir = """
    rt of a cut line
    10:00:00.123 [error] GenServer :x terminating
    ** (ArithmeticError) bad argument in arithmetic expression
        (demo 0.1.0) lib/demo.ex:12: Demo.add/2
    10:00:01.000 [info] fine
    """

    assert [%{level: :error, text: text}, %{level: :info}] =
             Errors.log_entries(elixir, drop_first: true)

    assert text =~ "lib/demo.ex:12"

    legacy = "=ERROR REPORT==== 24-Oct-2026::10:00:00.000000 ===\nboom\n"
    assert [%{level: :error}] = Errors.log_entries(legacy)
  end

  test "log files on a node that writes one", %{erlang: erlang} do
    {:ok, _} = TestTarget.connect(erlang)
    _ = TestTarget.call(erlang, :logger, :remove_handler, [:default])
    dir = Path.join(System.tmp_dir!(), "otpdbg_log_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "node.log")

    # What the node logged before: an error once at boot, then a loop's,
    # 400 KB of it, more than is read from the end.
    loop =
      for i <- 1..4_000,
          do: "2026-10-24T10:00:#{rem(i, 60)}.000000+00:00 error: import failed: line #{i}\n"

    File.write!(file, [
      "2026-10-24T09:59:59.000000+00:00 error: pricing rules: enoent\n",
      String.duplicate("2026-10-24T10:00:00.000000+00:00 info: filler\n", 1_000),
      loop
    ])

    :ok =
      TestTarget.call(erlang, :logger, :add_handler, [
        :file_log,
        :logger_std_h,
        %{config: %{file: String.to_charlist(file)}}
      ])

    later(0, ~S|logger:error("written to the file")|)
    Process.sleep(500)

    assert {:ok, result} = recent_errors(%{duration_ms: 100})
    assert [log] = for(f <- result["log_files"], f["file"] == file, do: f)
    assert log["read"] =~ "first 64 KB and last 192 KB"

    assert [
             %{"entries" => 1, "first" => "2026-10-24T09:59:59" <> _ = boot},
             %{"entries" => looped, "first" => first, "latest" => latest},
             %{"entries" => 1, "first" => text}
           ] = log["groups"]

    assert boot =~ "pricing rules"
    assert first =~ "import failed: line 1"
    assert latest =~ "import failed: line 4000"
    assert looped > 2_000
    assert text =~ "written to the file"

    :ok = TestTarget.call(erlang, :logger, :remove_handler, [:file_log])
    File.rm_rf!(dir)
  end
end
