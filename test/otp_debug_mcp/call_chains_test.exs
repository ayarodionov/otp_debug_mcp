defmodule OtpDebugMcp.CallChainsTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, TestTarget}
  alias OtpDebugMcp.Fixtures.Caller

  setup do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    %{target: target}
  end

  defp check, do: Checks.run(:call_chains)

  defp start(target, names),
    do: for(n <- names, do: {:ok, _} = TestTarget.call(target, Caller, :start, [n]))

  test "is ok when nothing waits", %{target: target} do
    start(target, [:idle])
    assert %{status: :ok, findings: %{waiting_over_1s: 0, deadlocks: [], chains: []}} = check()
  end

  test "finds two gen_servers calling each other", %{target: target} do
    start(target, [:alpha, :beta])
    # alpha calls beta, which calls alpha back: neither can answer.
    TestTarget.call(target, Caller, :make_call, [:alpha, :beta, {:via, [:alpha]}])

    assert %{status: :critical, findings: %{deadlocks: [cycle], most_waited_on: []}} = check()
    assert cycle |> Enum.map(& &1.name) |> Enum.sort() == [":alpha", ":beta"]

    alpha = Enum.find(cycle, &(&1.name == ":alpha"))
    assert alpha.waits_on =~ ~r/^a call to :beta \(<0\.\d+\.0>\)$/
    assert alpha.call == "'Elixir.GenServer':call/3"
    assert alpha.request == "{:via, [:alpha]}"
    assert alpha.timeout == ":infinity"
    assert alpha.current_function == "{:gen, :do_call, 4}"
  end

  test "follows a chain of calls to the process at its end", %{target: target} do
    start(target, [:front, :middle, :back])
    TestTarget.call(target, Caller, :call_later, [:front, {:via, [:middle, :back]}])

    assert %{status: :warning, findings: %{chains: [chain], deadlocks: []}} = check()
    assert [caller, front, middle, back] = chain
    assert caller.waits_on =~ "a call to"
    assert caller.request == "{:via, [:middle, :back]}"
    assert front.name == ":front"
    assert middle.name == ":middle"
    assert back.name == ":back"
    # The end of the chain waits on nobody: it's the one to look at.
    refute Map.has_key?(back, :waits_on)
    assert back.current_function =~ "Process"
  end

  test "names the process many wait on", %{target: target} do
    start(target, [:busy])
    for _ <- 1..6, do: TestTarget.call(target, Caller, :call_later, [:busy, {:via, []}])

    assert %{status: :warning, findings: %{most_waited_on: [busy | _]} = f} = check()
    assert busy.name == ":busy"
    assert busy.waiting_processes == 6
    assert length(busy.some_waiters) == 3
    assert f.waiting_over_1s == 6
    assert f.by_kind == %{call: 6}
  end
end
