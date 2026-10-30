defmodule OtpDebugMcp.SocketTuningTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}
  alias OtpDebugMcp.Fixtures.SocketShop

  defp tuning(params), do: call_tool_json(Tools.SocketTuning, params)

  defp target do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    target
  end

  defp findings(r), do: Enum.join(r["findings"], "\n")

  test "small writes with Nagle on" do
    target = target()
    port = TestTarget.call(target, SocketShop, :chatty, [])
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = tuning(%{duration_ms: 1_000, port: port})
    assert r["by_kind"]["tcp_listen"] == 1
    assert r["by_kind"]["tcp"] == 2
    assert Enum.any?(r["groups"], &(&1["options"]["nodelay"] == false))
    # The client writes each request in two (a window can end between
    # them); the server replies in one.
    assert findings(r) =~
             ~r/warning: 1 TCP socket owned by .*SocketShop.ask\/1 makes small writes.*(1\.[5-9]|2\.\d) writes for every read/

    assert findings(r) =~
             ~r/info: 1 TCP socket owned by .*SocketShop.echo\/1 makes small writes.*one per read/

    assert findings(r) =~ "{nodelay, true}"
  end

  test "an active socket flooding its owner's mailbox" do
    target = target()
    port = TestTarget.call(target, SocketShop, :flood, [])
    Process.sleep(1_000)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = tuning(%{duration_ms: 1_000, port: port})
    assert findings(r) =~ "in {active, true}"
    assert Enum.any?(r["groups"], &((&1["owner_mailbox_max"] || 0) >= 1_000))
  end

  test "a sender blocked by a peer that doesn't read" do
    target = target()
    port = TestTarget.call(target, SocketShop, :blocked, [])
    Process.sleep(1_000)
    {:ok, _} = TestTarget.connect(target)

    assert {:ok, r} = tuning(%{duration_ms: 1_000, port: port})
    assert findings(r) =~ "more queued to send than their high_watermark"
    assert findings(r) =~ "send_timeout infinity"
  end

  test "an ordinary node: the distribution socket, nothing to tune" do
    target()
    |> TestTarget.connect()

    assert {:ok, r} = tuning(%{duration_ms: 500})
    assert r["sockets"] >= 1
    assert r["status"] == "ok"
  end
end
