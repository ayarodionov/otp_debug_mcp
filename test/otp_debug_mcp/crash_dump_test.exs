defmodule OtpDebugMcp.CrashDumpTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.{DyingApp, Mailbox}

  # Two nodes that die: one runs out of memory (its VM may use only a
  # 128 MB super carrier) because a process can't keep up with its
  # mailbox; the other is an Elixir node whose permanent application stops.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "otpdbg_dumps_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    oom = Path.join(dir, "oom.dump")

    die(
      TestTarget.start(
        erlang: true,
        args: [~c"+MMscs", ~c"128", ~c"+MMsco", ~c"true", ~c"+Musac", ~c"false"],
        env: [ERL_CRASH_DUMP: oom]
      ),
      fn target ->
        eval(target, ~S"""
        Sink = spawn(fun() -> register(sink, self()), receive never -> ok end end),
        spawn(fun() ->
          Loop = fun L(N) -> Sink ! {event, N, #{id => N, tags => [a, b]}}, L(N + 1) end,
          Loop(1)
        end).
        """)
      end
    )

    app = Path.join(dir, "app.dump")

    mbox =
      die(TestTarget.start(env: [ERL_CRASH_DUMP: app]), fn target ->
        pid = TestTarget.call(target, Mailbox, :start, [:mbox, 3])
        big = Map.new(1..40, &{:"key#{&1}", &1})
        TestTarget.call(target, :erlang, :send, [:mbox, {:big, "text", 1.5, -7, 2 ** 70, big}])
        :ok = TestTarget.call(target, DyingApp, :start, [100])
        # As the dump prints it.
        pid |> :erlang.pid_to_list() |> to_string() |> String.replace(~r/^<\d+\./, "<0.")
      end)

    %{oom: oom, app: app, mbox: mbox}
  end

  # Start the node's death with `fun`, and wait until it's dead and its
  # dump written. Returns what `fun` returns.
  defp die(target, fun) do
    ref = Process.monitor(target.peer)
    result = fun.(target)

    receive do
      {:DOWN, ^ref, _, _, _} -> result
    after
      60_000 -> flunk("the node didn't die")
    end
  end

  defp eval(target, code) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(code))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    TestTarget.call(target, :erl_eval, :exprs, [exprs, []])
  end

  defp crash_dump(params), do: call_tool_json(Tools.CrashDump, params)

  test "out of memory: the cause, the process that grew, and what it was sent", %{oom: oom} do
    assert {:ok, r} = crash_dump(%{path: oom})
    assert r["complete"] == true
    assert r["cause"]["kind"] == "out_of_memory"
    assert r["slogan"] =~ ~r/Cannot (re)?allocate/
    assert r["system_version"] =~ "Erlang/OTP"

    assert [%{"name" => "sink", "message_queue_len" => queued} = sink | _] =
             r["processes"]["top_message_queues"]

    assert queued > 10_000
    assert sink["current_function"] == "prim_eval:receive/2"
    assert Enum.any?(r["findings"], &(&1 =~ "(sink)" and &1 =~ "messages"))

    assert %{"name" => "sink", "first_messages" => [first | _]} = r["largest_mailbox"]
    assert first == "{event,1,\#{id => 1,tags => [a,b]}}"

    # The VM was busy with the sender, or the receiver, when it died.
    assert %{"thread" => _} = r["running_when_it_died"]
    assert r["memory_mb"]["total"] < 140
  end

  test "an application that stopped, on an Elixir node", %{app: app, mbox: mbox} do
    assert {:ok, r} = crash_dump(%{path: app, process: mbox})
    assert r["cause"]["kind"] == "application_terminated"
    assert r["cause"]["application"] == "dying_app"
    assert r["cause"]["look_at"] =~ "recent_errors"
    # Its distribution stopped with the application controller.
    assert r["node"] == "not distributed"

    # In Elixir syntax: atoms, a map of 40 keys, a binary, floats, big numbers.
    assert %{"first_messages" => [junk | rest]} = r["largest_mailbox"]
    assert junk == "{:junk, 1}"
    big = List.last(rest)
    assert big =~ ~s({:big, "text", 1.5, -7, 1180591620717411303424, %{)
    assert big =~ "key40: 40"

    assert %{"pid" => ^mbox, "name" => "mbox", "message_queue_len" => 4, "stack" => _} =
             r["process"]

    assert [_ | _] = r["processes"]["top_memory"]
    # The applications had stopped: what's left is the mailbox and the VM's own.
    assert %{"count" => count} = r["processes"]
    assert count > 5
    # proc_lib processes say what they run.
    assert Enum.any?(r["processes"]["top_memory"], &Map.has_key?(&1, "initial_call"))
  end

  test "explains a path that isn't a dump" do
    assert {:error, text} = call_tool(Tools.CrashDump, %{path: "/no/such/erl_crash.dump"})
    assert text =~ "copied here first"

    assert {:error, text} = call_tool(Tools.CrashDump, %{path: __ENV__.file})
    assert text =~ "isn't an Erlang crash dump"
  end
end
