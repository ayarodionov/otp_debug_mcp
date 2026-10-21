defmodule OtpDebugMcp.FragmentationTest do
  use ExUnit.Case, async: false

  alias OtpDebugMcp.{Checks, TestTarget}
  alias OtpDebugMcp.Fixtures.Fragmenter

  setup do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    %{target: target}
  end

  test "a fresh node is ok, and the numbers add up" do
    assert %{status: :ok, findings: f} = Checks.run(:allocator_fragmentation)
    assert f.allocated_bytes == f.used_bytes + f.unused_bytes
    assert f.used_bytes > 0 and f.peak_allocated_bytes >= f.allocated_bytes
    assert [%{allocator: _, usage: _, unused_bytes: _} | _] = f.allocators

    if ll = Enum.find(f.allocators, &(&1.allocator == :ll_alloc)),
      do: assert(ll.note =~ "by design")

    assert is_binary(JSON.encode!(f))
  end

  test "names the fragmented allocator", %{target: target} do
    :ok = TestTarget.call(target, Fragmenter, :start, [200, 20])

    %{findings: f} = Checks.run(:allocator_fragmentation)
    assert [%{allocator: :binary_alloc} = binary | _] = f.allocators
    assert binary.unused_bytes > 100 * 1_048_576
    assert binary.usage < 0.3
  end

  test "status depends on the amount unused, not only the ratio" do
    mib = 1_048_576
    assert Checks.fragmentation_status(40 * mib, 0.5) == :ok
    assert Checks.fragmentation_status(600 * mib, 0.7) == :ok
    assert Checks.fragmentation_status(600 * mib, 0.5) == :warning
    assert Checks.fragmentation_status(3_000 * mib, 0.5) == :warning
    assert Checks.fragmentation_status(3_000 * mib, 0.3) == :critical
  end
end
