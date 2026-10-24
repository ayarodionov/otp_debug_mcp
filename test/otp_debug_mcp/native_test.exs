defmodule OtpDebugMcp.NativeTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Checks, Snapshotter, TestTarget, Tools}

  # The native_shop demo's NIFs, built into an application of their own
  # on the target: checksum/1 holds a scheduler for 80 ms, parse/1 leaks
  # 256 KB of native memory a call.
  @demo Path.expand("../../examples/erlang/native_shop", __DIR__)

  setup_all do
    dir = Path.join(System.tmp_dir!(), "otpdbg_native_#{System.unique_integer([:positive])}")
    app = Path.join(dir, "native_shop")
    File.mkdir_p!(Path.join(app, "ebin"))
    File.mkdir_p!(Path.join(app, "priv"))

    {:ok, :native_nif} =
      :compile.file(~c"#{@demo}/src/native_nif.erl", outdir: ~c"#{app}/ebin")

    File.cp!(Path.join(@demo, "src/native_shop.app.src"), Path.join(app, "ebin/native_shop.app"))

    include =
      Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])

    flags =
      case :os.type() do
        {:unix, :darwin} -> ["-shared", "-undefined", "dynamic_lookup"]
        _ -> ["-shared", "-fPIC"]
      end

    {_, 0} =
      System.cmd(
        System.get_env("CC", "cc"),
        ["-O2" | flags] ++
          [
            "-I",
            include,
            "-o",
            Path.join(app, "priv/native_nif.so"),
            Path.join(@demo, "c_src/native_nif.c")
          ],
        stderr_to_stdout: true
      )

    target = TestTarget.start()
    true = TestTarget.call(target, :code, :add_patha, [~c"#{app}/ebin"])
    :ok = TestTarget.call(target, :application, :load, [:native_shop])
    {:module, :native_nif} = TestTarget.call(target, :code, :ensure_loaded, [:native_nif])

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

  # A registered process calling checksum/1 every 200 ms.
  defp start_spinner do
    {:ok, _} =
      Checks.remote_eval("""
      Bin = crypto:strong_rand_bytes(4096),
      Pid = spawn(fun Loop() -> native_nif:checksum(Bin), receive stop -> ok after 200 -> Loop() end end),
      register(native_spinner, Pid),
      ok.
      """)

    on_exit(fn -> Checks.remote_eval("native_spinner ! stop.") end)
  end

  test "long_schedules names the process stuck in a NIF" do
    start_spinner()

    assert %{status: status, findings: %{via: "its own trace session", long_schedules: long}} =
             Checks.run(:long_schedules)

    assert status in [:warning, :critical]

    assert %{name: ":native_spinner", max_ms: max, times: times} =
             Enum.find(long, &(&1[:name] == ":native_spinner"))

    assert max >= 50 and times >= 2
  end

  test "long_schedules leaves the node's system_monitor alone", %{target: target} do
    holder = TestTarget.call(target, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    TestTarget.call(target, :erlang, :system_monitor, [holder, [{:long_gc, 1000}]])
    on_exit(fn -> TestTarget.call(target, :erlang, :system_monitor, [:undefined]) end)

    %{findings: %{long_schedules: _}} = Checks.run(:long_schedules)
    assert {^holder, [{:long_gc, 1000}]} = TestTarget.call(target, :erlang, :system_monitor, [])
  end

  test "native_memory and snapshot diffs see memory NIFs allocate", %{target: target} do
    assert %{findings: %{rss_bytes: rss, vm_allocated_bytes: _, outside_vm_bytes: _}} =
             Checks.run(:native_memory)

    assert rss > 0

    {:ok, _} = Snapshotter.take()
    # 200 calls: 50 MB that erlang:memory() never sees.
    for _ <- 1..200, do: TestTarget.call(target, :native_nif, :parse, [<<1, 2, 3>>])
    {:ok, diff} = Snapshotter.diff()

    assert diff.native_memory_delta_mb > 30
    assert diff.memory_delta_mb[:total] < 5
  end

  test "native_code lists the application's NIF library" do
    assert %{status: :ok, findings: %{native_libraries: libs, loaded_drivers: _}} =
             Checks.run(:native_code)

    assert %{app: ":native_shop", files: ["priv/native_nif.so"]} in libs
  end

  test "module_code marks a module's NIFs" do
    {:ok, result} = call_tool_json(Tools.ModuleCode, %{module: "native_nif"})
    nifs = for f <- result["functions"], f["nif"], do: f["function"]
    assert Enum.sort(nifs) == ["checksum/1", "parse/1"]

    {:ok, %{"code" => [%{"note" => note}]}} =
      call_tool_json(Tools.ModuleCode, %{module: "native_nif", function: "checksum/1"})

    assert note =~ "only its Erlang stub"
  end
end
