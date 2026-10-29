defmodule OtpDebugMcp.TuningTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.Tunable

  @t "'Elixir.OtpDebugMcp.Fixtures.Tunable'"

  defp target do
    target = TestTarget.start(recon: true)
    on_exit(fn -> TestTarget.stop(target) end)
    target
  end

  test "hot_spots: where the CPU goes, and the first frame of your code" do
    target = target()
    :ok = TestTarget.call(target, Tunable, :churn, [3_000, 2])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = call_tool_json(Tools.HotSpots, %{duration_ms: 1_500})
    assert r["busy_samples"] > 50
    assert [%{"function" => yours, "percent" => p} | _] = r["your_code"]
    assert yours =~ "OtpDebugMcp.Fixtures.Tunable."
    assert p > 50
    assert [%{"initial_call" => _} | _] = r["busiest_processes"]
    assert Enum.any?(r["with_callees"], &(&1["function"] =~ "Tunable.loop/1"))
  end

  test "hot_spots on an idle node: no hot spot" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = call_tool_json(Tools.HotSpots, %{duration_ms: 1_000})
    assert r["status"] == "ok"
    assert [finding] = r["findings"]
    assert finding =~ "few busy samples"
  end

  test "benchmark: a function against a rewrite, and one that answers differently" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} =
             call_tool_json(Tools.Benchmark, %{
               functions: [
                 "OtpDebugMcp.Fixtures.Tunable.slow_sum",
                 "Elixir.OtpDebugMcp.Fixtures.Tunable.fast_sum",
                 "Elixir.OtpDebugMcp.Fixtures.Tunable:wrong_sum"
               ],
               args: "[#{@t}:list(2000)]",
               duration_ms: 300
             })

    assert [slow, fast, wrong] = r["variants"]
    assert slow["function"] == "OtpDebugMcp.Fixtures.Tunable.slow_sum"
    assert slow["result"]["ok"] == "2001000"
    assert fast["same_result_as_first"]
    assert fast["speedup_vs_first"] > 10
    assert fast["reductions_per_call"] < slow["reductions_per_call"]
    refute wrong["same_result_as_first"]
    assert r["status"] == "warning"
    assert Enum.any?(r["findings"], &(&1 =~ "wrong_sum ([]) didn't return the same"))
    assert Enum.any?(r["findings"], &(&1 =~ "fastest: OtpDebugMcp.Fixtures.Tunable.fast_sum"))
  end

  test "benchmark: process tuning, and calls a second across processes" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} =
             call_tool_json(Tools.Benchmark, %{
               functions: ["OtpDebugMcp.Fixtures.Tunable.alloc"],
               args: "[50000]",
               spawn_options: ["[]", "[{min_heap_size, 2000000}]"],
               duration_ms: 400,
               concurrency: 2
             })

    assert [default, big] = r["variants"]
    assert default["spawn_options"] == "[]"
    assert big["spawn_options"] == "[{min_heap_size, 2000000}]"
    assert big["same_result_as_first"]
    assert big["heap_words_after"] > default["heap_words_after"]
    assert default["calls_per_s"] > 0
  end

  test "benchmark: a large result is shown only in part" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} =
             call_tool_json(Tools.Benchmark, %{
               functions: ["lists:duplicate"],
               args: "[100000, $a]",
               duration_ms: 200
             })

    assert [%{"result" => %{"ok" => preview, "words" => words}}] = r["variants"]
    assert String.length(preview) <= 303
    assert words == 200_000
  end

  test "benchmark: arguments that aren't a list" do
    target = target()
    {:ok, _} = TestTarget.connect(target)

    assert {:error, text} =
             call_tool(Tools.Benchmark, %{functions: ["lists:sum"], args: "42"})

    assert text =~ "args must be an Erlang expression for the list of arguments"
  end
end
