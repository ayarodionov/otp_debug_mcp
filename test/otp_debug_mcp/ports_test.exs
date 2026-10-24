defmodule OtpDebugMcp.PortsTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, Ports, Snapshotter, TestTarget, Tools}

  # The ports demo on a target: ports_client leaks a socket every 200 ms,
  # ports_feed fills a socket its peer reads slowly, ports_thumbnailer
  # starts an external program (cat) every 500 ms and never closes it.
  @demo Path.expand("../../examples/erlang/src/ports_shop.erl", __DIR__)

  setup_all do
    dir = Path.join(System.tmp_dir!(), "otpdbg_ports_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, :ports_shop} = :compile.file(~c"#{@demo}", [:debug_info, outdir: ~c"#{dir}"])

    target = TestTarget.start()
    true = TestTarget.call(target, :code, :add_patha, [~c"#{dir}"])
    :ok = TestTarget.call(target, :ports_shop, :start, [])
    # A socket of the socket module, which isn't a port, held by a process
    # that lives on (a socket closes when its owner exits).
    {:ok, _} = TestTarget.connect(target)

    {:ok, :ok} =
      Checks.remote_eval("""
      spawn(fun() -> {ok, S} = socket:open(inet, stream, tcp), receive stop -> socket:close(S) end end),
      ok.
      """)

    Process.sleep(3_000)

    on_exit(fn ->
      TestTarget.stop(target)
      File.rm_rf!(dir)
    end)

    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    :ok
  end

  defp owner(findings, name), do: Enum.find(findings, &(&1[:owner_name] == name))

  test "ports: types, owners, write queues, external programs and socket-module sockets" do
    assert %{findings: f} = Checks.run(:ports)
    assert %{type: "tcp_inet"} = Enum.find(f.by_type, &(&1.type == "tcp_inet"))

    assert %{type: "external: cat", count: programs} =
             Enum.find(f.by_type, &(&1.type == "external: cat"))

    assert programs >= 4

    assert %{ports: leaked, types: %{"tcp_inet" => leaked}} = owner(f.top_owners, ":ports_client")
    assert leaked >= 10

    assert %{queued_bytes: queued} = owner(f.write_queues, ":ports_feed")
    assert queued > 100_000

    assert f.external_programs.count >= 4
    assert [%{command: "cat", os_pid: os_pid} | _] = f.external_programs.running
    assert is_integer(os_pid)

    assert f.socket_module_sockets.count >= 1
    assert %{"inet/stream/tcp" => _} = f.socket_module_sockets.by_kind
  end

  test "snapshot diffs say which kind of port grew, and who opened them" do
    {:ok, _} = Snapshotter.take()
    Process.sleep(2_000)
    {:ok, diff} = Snapshotter.diff()

    assert diff.port_delta_by_type["tcp_inet"] >= 5
    assert diff.port_delta_by_type["external: cat"] >= 2
    assert %{ports_added: added} = owner(diff.port_delta_by_owner, ":ports_client")
    assert added >= 5
  end

  test "socket_traffic finds the busiest socket, with its peer" do
    assert %{findings: [top | _]} = Checks.run(:socket_traffic)
    assert top.owner_name == ":ports_feed" or top.bytes_per_s > 0
    assert top.peer =~ "127.0.0.1:"
  end

  test "port_info on a socket and on an external program" do
    %{findings: f} = Checks.run(:ports)
    %{port: socket} = owner(f.write_queues, ":ports_feed")

    assert {:ok, info} = call_tool_json(Tools.PortInfo, %{port: socket})

    assert %{
             "kind" => "socket",
             "name" => "tcp_inet",
             "socket" => %{
               "peer" => _,
               "stats" => %{"send_pend" => _},
               "options" => %{"active" => "false"}
             }
           } = info

    assert %{"owner_process" => %{"name" => ":ports_feed"}} = info

    [%{port: program} | _] = f.external_programs.running

    assert {:ok, %{"kind" => "external program", "os_pid" => _}} =
             call_tool_json(Tools.PortInfo, %{port: program})

    assert {:error, text} = call_tool(Tools.PortInfo, %{port: "#Port<0.999999>"})
    assert text =~ "closed" or text =~ "no port"
  end

  test "trace_port: a socket's traffic, and the ports opened in a window" do
    %{findings: f} = Checks.run(:ports)
    %{port: socket} = owner(f.write_queues, ":ports_feed")

    assert {:ok, %{"events" => events, "backend" => "isolated trace session"}} =
             call_tool_json(Tools.TracePort, %{port: socket, max_events: 4, duration_ms: 3_000})

    assert Enum.any?(events, &(&1 =~ "'receive'" and &1 =~ "command"))

    assert {:ok, %{"opened" => opened, "opened_by" => by}} =
             call_tool_json(Tools.TracePort, %{opened: true, max_events: 40, duration_ms: 1_500})

    assert opened >= 4
    assert %{"what" => %{"tcp_inet" => _}} = Enum.find(by, &(&1["owner_name"] == ":ports_client"))
    assert Enum.find(by, &(&1["owner_name"] == ":ports_thumbnailer"))
  end

  test "trace_port's legacy backend traces where nobody else does" do
    assert {:ok, %{backend: "legacy trace session", events: events}} =
             Ports.trace(:new_ports, 10, 1_500, backend: :legacy)

    assert Enum.any?(events, &(&1 =~ " open "))
  end
end
