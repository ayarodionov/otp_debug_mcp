defmodule OtpDebugMcp.RecorderTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Recorder, Target, TestTarget, Tools, Watch}
  alias OtpDebugMcp.Fixtures.{Flooded, Mailbox}

  @mib 1_048_576

  # -- History, from samples made up here ------------------------------------------

  defp sample(at, fields \\ []) do
    base = %{
      at: at,
      memory: %{
        total: 100 * @mib,
        processes: 30 * @mib,
        binary: @mib,
        ets: @mib,
        code: 20 * @mib,
        atom: @mib
      },
      counts: %{processes: 100, ports: 10, atoms: 20_000, run_queue: 0},
      top_memory: [],
      top_mailbox: [],
      top_reductions: [],
      ets: []
    }

    Enum.reduce(fields, base, fn
      {:memory, m}, s -> %{s | memory: Map.merge(s.memory, m)}
      {:counts, c}, s -> %{s | counts: Map.merge(s.counts, c)}
      {k, v}, s -> Map.put(s, k, v)
    end)
  end

  defp report(samples, fields \\ %{}) do
    Map.merge(
      %{
        samples: samples,
        started: 1_000,
        ends: 1_000 + 3_600,
        interval_ms: 10_000,
        keep: 360,
        taken: length(samples),
        failed: 0,
        spaced_out: 0,
        recording: true,
        read_at: List.last(samples).at + 5,
        expires: 1_000 + 3_600 + 86_400
      },
      fields
    )
  end

  # A process as a sample records it: pid, value, initial call, {name, current function}.
  defp proc(pid, value, name \\ []),
    do: {pid, value, {Shop.PriceCache, :init, 1}, {name, {Process, :sleep, 1}}}

  test "a growing mailbox and the memory with it, in one sentence each, with when" do
    pid = self()

    samples =
      for i <- 0..6 do
        q = if i == 0, do: 10, else: i * 200_000
        held = if i == 0, do: @mib, else: i * 150 * @mib

        sample(1_000 + i * 10,
          memory: %{total: 100 * @mib + held, processes: 30 * @mib + held},
          top_mailbox: [proc(pid, q, Shop.PriceCache)],
          top_memory: [proc(pid, held, Shop.PriceCache)]
        )
      end

    h = Recorder.history(report(samples))
    [memory, process | _] = h.conclusions

    assert memory =~
             ~r/^Total memory rose from 101 MB at 00:16:40 UTC \(1 min ago\) to 1000 MB at 00:17:40 UTC \(5 s ago\)/

    assert memory =~ "(1 min 0 s), the latest sample."

    assert memory =~ "At the peak, Shop.PriceCache ("
    assert memory =~ "held 900 MB of it (90% of the node's memory)."

    assert memory =~ "Most of the rise was process memory (+899 MB)."
    # The categories aren't repeated when the total says it.
    refute Enum.any?(h.conclusions, &(&1 =~ "Process memory rose"))

    assert process =~ "Shop.PriceCache"
    assert process =~ "its mailbox passed 1,000 at 00:16:50 UTC"
    assert process =~ "reached 1,200,000 at 00:17:40 UTC"
    assert process =~ "its memory went from 1 MB at 00:16:40 UTC"
    assert process =~ "It was in Process.sleep/1."
  end

  test "a fall, a crowded run queue, a growing table, and a mailbox there from the start" do
    pid = self()

    samples =
      for i <- 0..5 do
        sample(2_000 + i * 10,
          counts: %{
            processes: if(i < 3, do: 50_000, else: 200),
            run_queue: if(i == 2, do: 80, else: 0)
          },
          top_mailbox: [proc(pid, 5_000 + i)],
          ets: [{:sessions, (10 + i * 40) * @mib, i * 100_000, pid}]
        )
      end

    h = Recorder.history(report(samples))
    text = Enum.join(h.conclusions, "\n")

    assert text =~ "The number of processes fell from 50,000 at 00:33:20 UTC"
    assert text =~ "to 200 at 00:33:50 UTC (25 s ago) (30 s), and stayed down."
    # A spike is one sentence, which says where it is now.
    assert text =~ "The run queue rose from 0 at 00:33:20 UTC (55 s ago) to 80 at 00:33:40 UTC"
    assert text =~ "; it is 0 now."
    refute text =~ "The run queue fell"
    assert text =~ ~r/The ETS table :sessions \(owned by .*\) grew from 10 MB \(0 rows\)/
    assert text =~ "to 210 MB (500,000 rows)"
    assert text =~ "its mailbox already held 5,000 messages when recording began"
    assert text =~ "started as Shop.PriceCache.init/1: its mailbox"
  end

  test "a quiet node, too few samples, a window, gaps and failed samples" do
    quiet = for i <- 0..5, do: sample(3_000 + i * 10)
    assert [only] = Recorder.history(report(quiet)).conclusions
    assert only =~ "Nothing changed much in the window"

    assert [few] = Recorder.history(report([sample(3_000)])).conclusions
    assert few =~ "Too few samples"

    windowed = Recorder.history(report(quiet), minutes: 0)
    assert windowed.samples == 0

    gapped = [sample(4_000), sample(4_010), sample(4_200)]

    assert Enum.any?(
             Recorder.history(report(gapped)).conclusions,
             &(&1 =~ "up to 3 min 10 s apart")
           )

    failed = Recorder.history(report(quiet, %{failed: 2, taken: 8})).conclusions
    assert Enum.any?(failed, &(&1 =~ "2 of 8 samples failed"))

    slow = for i <- 0..3, do: sample(5_000 + i * 40, work_ms: 3_100)

    assert Enum.any?(
             Recorder.history(report(slow, %{spaced_out: 3})).conclusions,
             &(&1 =~ "spaced 3 of its samples out" and &1 =~ "up to 3,100 ms of work")
           )

    assert %{raw: [_ | _]} = Recorder.history(report(quiet), raw: true)
    # The recording ends an hour after 1,000 s; it's read at 3,055 s.
    assert Recorder.history(report(quiet)).recorder.ends =~ "in 25 min 45 s"
  end

  # -- On a node -------------------------------------------------------------------

  describe "on a node" do
    setup do
      target = TestTarget.start()
      on_exit(fn -> TestTarget.stop(target) end)
      {:ok, _} = TestTarget.connect(target)
      %{target: target}
    end

    test "records while nobody is connected, and its history names the flooded process",
         %{target: target} do
      TestTarget.call(target, Flooded, :start, [:flooded, 5])

      assert {:ok, :started} = Recorder.start(60_000, 1_000, 100)
      assert {:ok, :already_running} = Recorder.start(60_000, 1_000, 100)
      {:ok, first} = Recorder.read()

      # The recorder runs on the node: it doesn't need us connected.
      Node.disconnect(target.node)
      Process.sleep(4_000)
      {:ok, _} = TestTarget.connect(target)

      {:ok, report} = Recorder.read()
      assert report.recording
      assert length(report.samples) >= length(first.samples) + 2
      assert report.failed == 0

      h = Recorder.history(report)
      assert Enum.any?(h.conclusions, &(&1 =~ ":flooded" and &1 =~ "mailbox"))
      assert %{share_of_samples: share} = h.busiest_process
      assert share > 0

      assert {:ok, _} = Recorder.read(true)
      assert :none = Recorder.read()
    end

    test "stops recording when its time is up, and stays readable" do
      assert {:ok, :started} = Recorder.start(1_500, 500, 100)
      Process.sleep(3_000)

      {:ok, report} = Recorder.read()
      refute report.recording
      taken = report.taken
      Process.sleep(1_000)
      assert {:ok, %{taken: ^taken}} = Recorder.read()
      assert {:ok, _} = Recorder.read(true)
    end

    test "wait_for_problem: what was wrong already, then a new problem, reported once",
         %{target: target} do
      assert {:error, text} = call_tool(Tools.WaitForProblem, %{wait_s: 1})
      assert text =~ "No recorder on this node"

      TestTarget.call(target, Mailbox, :start, [:stuck_mailbox, 5_000])
      assert {:ok, :started} = Recorder.start(120_000, 1_000, 100)
      Process.sleep(2_500)

      # What was wrong when watching began is known, not new.
      assert {:ok, first} = Watch.wait(3_000)
      assert first.new_problems == []
      assert Enum.any?(first.already_present, &(&1 =~ ":stuck_mailbox"))
      assert first.hint =~ "Nothing new yet"

      # A new problem ends the wait as soon as it shows.
      TestTarget.call(target, Flooded, :start, [:flooded, 5])
      began = System.monotonic_time(:millisecond)
      assert {:ok, found} = Watch.wait(30_000)
      assert System.monotonic_time(:millisecond) - began < 20_000
      assert Enum.any?(found.new_problems, &(&1 =~ ":flooded" and &1 =~ "mailbox"))
      refute Enum.any?(found.new_problems, &(&1 =~ ":stuck_mailbox"))
      refute Map.has_key?(found, :already_present)

      # Reported once.
      assert {:ok, again} = Watch.wait(2_500)
      refute Enum.any?(again.new_problems, &(&1 =~ ":flooded"))

      # Afresh: everything wrong now is known.
      assert {:ok, fresh} = Watch.wait(1_000, true)
      assert Enum.any?(fresh.already_present, &(&1 =~ ":flooded"))

      # The tool, the same way.
      assert {:ok, %{"new_problems" => [], "watching_since" => _}} =
               call_tool_json(Tools.WaitForProblem, %{wait_s: 1})

      # A recorder that has stopped: nothing new will come, and it says so.
      assert {:ok, _} = Recorder.read(true)
      assert {:ok, :started} = Recorder.start(1_500, 500, 100)
      Process.sleep(2_500)
      assert {:ok, stopped} = Watch.wait(5_000)
      assert stopped.hint =~ "stopped recording"
      assert {:ok, _} = Recorder.read(true)
    end

    test "the tools: record, history, and history without a recorder" do
      assert {:error, text} = call_tool(Tools.History, %{})
      assert text =~ "No recorder on this node"
      assert text =~ "not before"

      assert {:ok, %{"started" => %{"interval_s" => 2, "recording" => true}}} =
               call_tool_json(Tools.Record, %{minutes: 5, interval_s: 2})

      assert {:ok, %{"already_running" => _}} = call_tool_json(Tools.Record, %{})
      Process.sleep(2_500)

      assert {:ok, %{"conclusions" => [_ | _], "recorder" => %{"samples_kept" => n}}} =
               call_tool_json(Tools.History, %{})

      assert n >= 2
      assert {:ok, %{"stopped" => _}} = call_tool_json(Tools.Record, %{stop: true})
      assert {:error, _} = call_tool(Tools.Record, %{stop: true})

      assert {:ok, nil} =
               Target.rpc(:erlang, :whereis, [:otp_debug_mcp_recorder]) |> nil_if_undefined()
    end
  end

  defp nil_if_undefined({:ok, :undefined}), do: {:ok, nil}
  defp nil_if_undefined(other), do: other
end
