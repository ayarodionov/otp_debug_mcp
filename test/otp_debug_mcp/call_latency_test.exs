defmodule OtpDebugMcp.CallLatencyTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.Inventory

  defp latency(params), do: call_tool_json(Tools.CallLatency, params)

  defp target do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    TestTarget.call(target, Inventory, :start, [:inventory])
    target
  end

  defp request(r, text), do: Enum.find(r["calls"] || [], &(&1["request"] == text))

  test "fast calls stuck behind a slow one: the wait is in the mailbox" do
    target = target()
    :ok = TestTarget.call(target, Inventory, :callers, [:inventory, 5, :count, 20])
    :ok = TestTarget.call(target, Inventory, :callers, [:inventory, 2, {:export, 200}, 300])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = latency(%{process: "inventory", duration_ms: 2_000})
    assert r["module"] == "OtpDebugMcp.Fixtures.Inventory"
    assert r["busy_share"] > 0.25

    count = request(r, ":count")
    export = request(r, "{:export, ...} (2-tuple)")
    assert count["calls"] > 20
    assert export["calls"] >= 5
    assert export["handling_ms"]["p50"] >= 190
    # :count takes no time; its callers wait behind the exports.
    assert count["handling_ms"]["p95"] < 5
    assert count["wait_ms"]["max"] >= 50
    assert export["share_of_busy_time"] > 0.7
    assert [%{"calls" => _, "waited_ms_total" => _} | _] = r["callers"]

    findings = Enum.join(r["findings"], "\n")
    assert findings =~ "{:export, ...} (2-tuple) takes"
    assert findings =~ "of the server's busy time"
  end

  test "a reply sent later, casts and other messages" do
    target = target()
    :ok = TestTarget.call(target, Inventory, :callers, [:inventory, 2, {:later, 100}, 50])
    :ok = TestTarget.call(target, Inventory, :callers, [:inventory, 2, {:cast, {:note, 10}}, 50])
    :ok = TestTarget.call(target, Inventory, :callers, [:inventory, 1, :tick, 10])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = latency(%{process: "inventory", duration_ms: 1_500})

    later = request(r, "{:later, ...} (2-tuple)")
    # Answered from handle_info about 100 ms later: handling to the reply.
    assert later["handling_ms"]["p50"] >= 95
    assert later["total_ms"]["p50"] >= 95

    assert [%{"message" => "{:note, ...} (2-tuple)", "casts" => casts, "handling_ms" => h}] =
             r["casts"]

    assert casts > 10
    assert h["p50"] >= 9
    assert Enum.any?(r["other_messages"], &(&1["message"] == ":tick" and &1["messages"] > 50))
  end

  test "a pid, and processes that aren't gen_servers" do
    target = target()
    {:ok, _} = TestTarget.connect(target)
    # The pid as the node writes it, as other tools give it.
    pid = TestTarget.call(target, :erlang, :whereis, [:inventory])
    text = TestTarget.call(target, :erlang, :pid_to_list, [pid])

    assert {:ok, %{"module" => "OtpDebugMcp.Fixtures.Inventory"}} =
             latency(%{process: to_string(text), duration_ms: 500})

    assert {:error, text} =
             call_tool(Tools.CallLatency, %{process: "no_such_name", duration_ms: 500})

    assert text =~ "no process no_such_name"
    assert {:error, text} = call_tool(Tools.CallLatency, %{process: "init", duration_ms: 500})
    assert text =~ "isn't a gen_server"
  end
end
