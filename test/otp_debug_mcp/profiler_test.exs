defmodule OtpDebugMcp.ProfilerTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.{Busy, Operator, Ticker}

  # Two targets: one where nobody else traces, and one where an operator
  # runs recon_trace, as someone debugging the node by hand would.
  setup_all do
    target = TestTarget.start(recon: true)
    :ok = TestTarget.call(target, Busy, :start, [:busy, 2_000])
    :ok = TestTarget.call(target, Busy, :start, [:busy_light, 10])

    watched = TestTarget.start(recon: true)
    :ok = TestTarget.call(watched, Busy, :start, [:busy, 2_000])
    {:ok, _} = TestTarget.call(watched, Ticker, :start, [:ticker, 50])
    :ok = TestTarget.call(watched, Operator, :start, [{Ticker, :handle_info, :_}])

    on_exit(fn ->
      TestTarget.stop(target)
      TestTarget.stop(watched)
    end)

    %{target: target, watched: watched}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp profile(params), do: call_tool_json(Tools.Profile, params)

  defp by_name(rows), do: Map.new(rows, &{&1["function"], &1})

  test "ranks a module's functions by own time, with calls and memory" do
    assert {:ok, result} = profile(%{module: "OtpDebugMcp.Fixtures.Busy", duration_ms: 1_000})
    assert result["backend"] == "isolated trace session"
    assert result["processes"] == "all"

    rows = by_name(result["by_time"])
    crunch = rows["OtpDebugMcp.Fixtures.Busy.crunch/1"]
    square = rows["anonymous fn/1 in OtpDebugMcp.Fixtures.Busy.crunch/1"]
    light = rows["OtpDebugMcp.Fixtures.Busy.light/1"]
    step = rows["OtpDebugMcp.Fixtures.Busy.step/1"]

    # The top two are crunch and the fn it maps with.
    assert result["by_time"] |> Enum.take(2) |> Enum.map(& &1["function"]) |> Enum.sort() ==
             Enum.sort([crunch["function"], square["function"]])

    # Every step calls crunch and light once, and crunch calls the fn once
    # per element: 2,000 times for busy, 10 for busy_light.
    assert crunch["calls"] > 100
    assert crunch["calls"] == light["calls"]
    assert step["calls"] == crunch["calls"]
    assert square["calls"] > 100 * crunch["calls"]

    # crunch's own time includes Enum's, which isn't profiled; step's
    # doesn't include crunch's, which is.
    assert crunch["time_us"] > 10 * light["time_us"]
    assert crunch["time_us"] > step["time_us"]
    # crunch allocates the most of the functions doing the work (OTP 27
    # sometimes charges loop/1, waiting in its receive, with as much).
    assert crunch["memory_bytes"] > 100 * step["memory_bytes"]

    assert crunch["function"] in (result["by_memory"]
                                  |> Enum.take(2)
                                  |> Enum.map(& &1["function"]))

    assert crunch["percent"] + square["percent"] > 80

    assert [%{"name" => ":busy", "pid" => "<0." <> _} | _] = result["by_process"]
  end

  test "one function, or one process's calls" do
    assert {:ok, result} =
             profile(%{module: "OtpDebugMcp.Fixtures.Busy", function: "light", duration_ms: 500})

    assert [%{"function" => "OtpDebugMcp.Fixtures.Busy.light/1"}] = result["by_time"]

    assert {:ok, result} =
             profile(%{
               module: "OtpDebugMcp.Fixtures.Busy",
               process: "busy_light",
               duration_ms: 500
             })

    assert [%{"name" => ":busy_light"}] = result["by_process"]
    assert result["processes"] == [hd(result["by_process"])["pid"]]
  end

  test "every module, when asked for" do
    assert {:ok, result} = profile(%{all_modules: true, duration_ms: 500, top: 50})
    assert result["functions_profiled"] > 1_000
    names = Enum.map(result["by_time"], & &1["function"])
    # Enum's work is now profiled in Enum, not in crunch.
    assert Enum.any?(names, &String.starts_with?(&1, "Enum."))
  end

  test "leaves nothing behind on the target", %{target: target} do
    {:ok, _} = profile(%{module: "OtpDebugMcp.Fixtures.Busy", duration_ms: 200})
    {:ok, _} = profile(%{module: "OtpDebugMcp.Fixtures.Busy", duration_ms: 200, force: false})

    sessions = TestTarget.call(target, :trace, :session_info, [:all])
    refute Enum.any?(sessions, &match?({:otp_debug_mcp_profile, _}, &1))
    busy = TestTarget.call(target, :erlang, :whereis, [:busy])
    assert TestTarget.call(target, :erlang, :trace_info, [busy, :flags]) == {:flags, []}
  end

  test "explains what it can't profile" do
    assert {:error, text} = call_tool(Tools.Profile, %{module: "no_such_module"})
    assert text =~ "module_not_loaded_on_target"

    assert {:error, text} =
             call_tool(Tools.Profile, %{module: "OtpDebugMcp.Fixtures.Busy", function: "nope"})

    assert text =~ "no function matches"

    assert {:error, text} = call_tool(Tools.Profile, %{})
    assert text =~ "give a module, or all_modules"

    assert {:error, text} = call_tool(Tools.Profile, %{module: "lists", all_modules: true})
    assert text =~ "not both"

    assert {:error, text} =
             call_tool(Tools.Profile, %{module: "lists", process: "no_such_process"})

    assert text =~ "no_such_process"
  end

  describe "where someone else is tracing" do
    setup %{watched: watched} do
      {:ok, _} = TestTarget.connect(watched)
      :ok
    end

    test "a session profile doesn't disturb their trace", %{watched: watched} do
      before = TestTarget.call(watched, Operator, :lines, [])

      assert {:ok, %{"by_time" => [_ | _]}} =
               profile(%{module: "OtpDebugMcp.Fixtures.Busy", duration_ms: 500})

      assert TestTarget.call(watched, Operator, :alive?, [])
      Process.sleep(300)
      assert TestTarget.call(watched, Operator, :lines, []) > before
    end

    test "the legacy backend refuses unless forced" do
      assert {:error, text} =
               call_tool_json_with_backend(%{module: "OtpDebugMcp.Fixtures.Busy"}, :legacy)

      assert text =~ "other tracing is active"
      assert text =~ "force: true"
    end
  end

  test "the legacy backend profiles where nobody else traces, and clears up", %{target: target} do
    assert {:ok, result} =
             OtpDebugMcp.Profiler.profile(
               {:module, "OtpDebugMcp.Fixtures.Busy", nil},
               500,
               backend: :legacy
             )

    assert result.backend =~ "legacy"
    assert "OtpDebugMcp.Fixtures.Busy.crunch/1" in Enum.map(result.by_time, & &1.function)

    mfa = {Busy, :crunch, 1}
    assert TestTarget.call(target, :erlang, :trace_info, [mfa, :call_time]) == {:call_time, false}
    busy = TestTarget.call(target, :erlang, :whereis, [:busy])
    assert TestTarget.call(target, :erlang, :trace_info, [busy, :flags]) == {:flags, []}
  end

  defp call_tool_json_with_backend(params, backend) do
    case OtpDebugMcp.Profiler.profile({:module, params.module, nil}, 300, backend: backend) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, JSON.encode!(reason)}
    end
  end
end
