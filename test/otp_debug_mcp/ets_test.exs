defmodule OtpDebugMcp.EtsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.EtsOwner

  setup_all do
    target = TestTarget.start()
    :ok = TestTarget.call(target, EtsOwner, :start, [:ets_owner])
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp ets_table(params), do: call_tool_json(Tools.EtsTable, params)

  test "a set: its settings, first rows, and the large row the scan finds" do
    assert {:ok, r} = ets_table(%{table: "otpdbg_set"})
    assert %{"type" => "set", "protection" => "public", "rows" => 2001, "named_table" => true} = r
    assert r["memory_bytes"] > 160_000
    assert %{"name" => ":ets_owner", "pid" => "<0." <> _} = r["owner"]
    assert length(r["first_rows"]) == 10

    assert %{"rows" => 2001, "of" => 2001, "complete" => true, "largest" => [big | _]} =
             r["scanned"]

    assert big["key"] == ":big"
    assert big["bytes"] > 300_000
    # Too large to send whole: described by its key and size.
    assert big["row"] =~ "-byte row; its key is :big"
    assert r["scanned"]["average_row_bytes"] < big["bytes"]
    refute Map.has_key?(r, "most_rows_per_key")
  end

  test "a bag's hot key, found by its name though it isn't a named table" do
    assert {:ok, %{"type" => "bag", "named_table" => false} = r} =
             ets_table(%{table: ":otpdbg_bag", rows: 3})

    assert length(r["first_rows"]) == 3
    assert [%{"key" => ":hot", "rows" => 30}] = r["most_rows_per_key"]

    # Its rows are all alike: none stands out, so only the biggest's size.
    refute Map.has_key?(r["scanned"], "largest")
    assert r["scanned"]["largest_row_bytes"] == r["scanned"]["average_row_bytes"]
  end

  test "a scan stops at its limit" do
    assert {:ok, %{"scanned" => %{"rows" => 500, "complete" => false}}} =
             ets_table(%{table: "otpdbg_set", scan: 500})
  end

  test "a private table: its settings only" do
    assert {:ok, %{"readable" => false, "why" => why, "protection" => "private"} = r} =
             ets_table(%{table: "otpdbg_private"})

    assert why =~ "only its owner"
    refute Map.has_key?(r, "first_rows")
  end

  test "explains a table that isn't there" do
    assert {:error, text} = call_tool(Tools.EtsTable, %{table: "no_such_table_anywhere"})
    assert text =~ "no ETS table named no_such_table_anywhere"
  end
end
