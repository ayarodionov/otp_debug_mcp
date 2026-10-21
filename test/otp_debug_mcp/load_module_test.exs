defmodule OtpDebugMcp.LoadModuleTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}

  @module :otpdbg_fixed

  # Version 1 is on the target's code path, as a release's code is; the
  # fixed versions are .beam files on this side.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "otpdbg_load_#{System.unique_integer([:positive])}")
    beams = for v <- 1..3, into: %{}, do: {v, compile(dir, v)}

    target = TestTarget.start()
    true = TestTarget.call(target, :code, :add_patha, [~c"#{Path.dirname(beams[1])}"])

    on_exit(fn ->
      TestTarget.stop(target)
      File.rm_rf!(dir)
    end)

    %{target: target, beams: beams}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    TestTarget.call(target, :code, :purge, [@module])
    TestTarget.call(target, :code, :delete, [@module])
    TestTarget.call(target, :code, :purge, [@module])
    {:module, @module} = TestTarget.call(target, :code, :load_file, [@module])
    :ok
  end

  defp compile(dir, version) do
    src = Path.join([dir, "v#{version}", "#{@module}.erl"])
    File.mkdir_p!(Path.dirname(src))

    File.write!(src, """
    -module(#{@module}).
    -export([version/0, start_looper/0]).
    version() -> #{version}.
    start_looper() -> spawn(fun loop/0).
    loop() -> receive stop -> ok after 20 -> loop() end.
    """)

    {:ok, @module} = :compile.file(~c"#{src}", outdir: ~c"#{Path.dirname(src)}")
    Path.join(Path.dirname(src), "#{@module}.beam")
  end

  defp version(target), do: TestTarget.call(target, @module, :version, [])

  defp approve(%{input_requests: %{"approve" => _}, request_state: {:set, state}}, answer),
    do: form_client_frame(%{"approve" => answer}, state)

  defp accept, do: %{"action" => "accept", "content" => %{"load" => true}}

  test "asks first, with what changes where, and loads only once approved",
       %{target: target, beams: beams} do
    params = %{path: beams[2]}

    assert {:input_required, input} = call_tool(Tools.LoadModule, params, form_client_frame())
    %{"approve" => %{"method" => "elicitation/create", "params" => ask}} = input.input_requests
    assert ask["message"] =~ "Load new code for otpdbg_fixed on #{target.node}?"
    assert ask["message"] =~ beams[2]
    assert ask["message"] =~ ~r/Running now: md5 [0-9a-f]{32}, #{beams[1]}/
    assert %{"required" => ["load"]} = ask["requestedSchema"]
    assert version(target) == 1

    assert {:ok, result} = call_tool_json(Tools.LoadModule, params, approve(input, accept()))
    assert %{"loaded" => "otpdbg_fixed", "file" => file, "replaced" => %{"file" => old}} = result
    assert {file, old} == {beams[2], beams[1]}
    assert result["lasts"] =~ "until the node restarts"
    assert version(target) == 2

    assert {:ok, %{"unchanged" => _}} =
             call_tool_json(Tools.LoadModule, params, form_client_frame())
  end

  test "code compiled in memory, as an .exs script's is, can't be reverted",
       %{target: target, beams: beams} do
    {@module, bin, _} = TestTarget.call(target, :code, :get_object_code, [@module])
    TestTarget.call(target, :code, :purge, [@module])
    {:module, @module} = TestTarget.call(target, :code, :load_binary, [@module, [], bin])
    dir = ~c"#{Path.dirname(beams[1])}"
    true = TestTarget.call(target, :code, :del_path, [dir])
    on_exit(fn -> TestTarget.call(target, :code, :add_patha, [dir]) end)

    assert {:input_required, input} =
             call_tool(Tools.LoadModule, %{path: beams[2]}, form_client_frame())

    assert input.input_requests["approve"]["params"]["message"] =~
             ~r/Running now: md5 [0-9a-f]{32}, no file: compiled in memory/

    assert {:ok, %{"lasts" => lasts, "replaced" => %{"file" => "no file: compiled in memory"}}} =
             call_tool_json(Tools.LoadModule, %{path: beams[2]}, approve(input, accept()))

    assert lasts =~ "revert can't undo it; a restart does"

    assert {:error, text} =
             call_tool(Tools.LoadModule, %{revert: "otpdbg_fixed"}, form_client_frame())

    assert text =~ "isn't on the node's code path"
  end

  test "a declined or cancelled form, or an unticked box, loads nothing",
       %{target: target, beams: beams} do
    params = %{path: beams[2]}
    {:input_required, input} = call_tool(Tools.LoadModule, params, form_client_frame())

    for answer <- [
          %{"action" => "decline"},
          %{"action" => "cancel"},
          %{"action" => "accept", "content" => %{"load" => false}}
        ] do
      assert {:error, text} = call_tool(Tools.LoadModule, params, approve(input, answer))
      assert text =~ "didn't approve"
      assert text =~ "Don't ask again"
    end

    assert version(target) == 1
  end

  test "an approval is for the code the user saw: if the file changes, it asks again",
       %{target: target, beams: beams} do
    file = Path.join(Path.dirname(beams[2]), "copy/#{@module}.beam")
    File.mkdir_p!(Path.dirname(file))
    File.cp!(beams[2], file)
    {:input_required, input} = call_tool(Tools.LoadModule, %{path: file}, form_client_frame())

    File.cp!(beams[3], file)

    assert {:input_required, again} =
             call_tool(Tools.LoadModule, %{path: file}, approve(input, accept()))

    assert version(target) == 1
    assert {:ok, _} = call_tool_json(Tools.LoadModule, %{path: file}, approve(again, accept()))
    assert version(target) == 3
  end

  test "refuses outright when the client can't ask the user", %{target: target, beams: beams} do
    assert {:error, text} = call_tool(Tools.LoadModule, %{path: beams[2]})
    assert text =~ "can't. Nothing was loaded."
    assert version(target) == 1
  end

  test "reverts to the version on the node's code path, also once approved",
       %{target: target, beams: beams} do
    {:input_required, input} = call_tool(Tools.LoadModule, %{path: beams[2]}, form_client_frame())
    {:ok, _} = call_tool_json(Tools.LoadModule, %{path: beams[2]}, approve(input, accept()))

    params = %{revert: "otpdbg_fixed"}
    assert {:input_required, input} = call_tool(Tools.LoadModule, params, form_client_frame())
    assert input.input_requests["approve"]["params"]["message"] =~ "Revert otpdbg_fixed"
    assert version(target) == 2

    assert {:ok, %{"file" => file}} =
             call_tool_json(Tools.LoadModule, params, approve(input, accept()))

    assert file == beams[1]
    assert version(target) == 1

    assert {:ok, %{"unchanged" => _}} =
             call_tool_json(Tools.LoadModule, params, form_client_frame())
  end

  test "never kills processes still running old code", %{target: target, beams: beams} do
    looper = TestTarget.call(target, @module, :start_looper, [])

    {:input_required, input} = call_tool(Tools.LoadModule, %{path: beams[2]}, form_client_frame())

    assert {:ok, %{"still_on_old_code" => %{"processes" => 1}}} =
             call_tool_json(Tools.LoadModule, %{path: beams[2]}, approve(input, accept()))

    {:input_required, input} = call_tool(Tools.LoadModule, %{path: beams[3]}, form_client_frame())

    assert {:error, text} =
             call_tool(Tools.LoadModule, %{path: beams[3]}, approve(input, accept()))

    assert text =~ "loading again would kill them"
    assert TestTarget.call(target, :erlang, :is_process_alive, [looper])
    assert version(target) == 2
    send(looper, :stop)
  end

  test "doesn't replace OTP's own modules, and says what's wrong with a path" do
    assert {:error, text} = call_tool(Tools.LoadModule, %{revert: "lists"}, form_client_frame())
    assert text =~ "one of OTP's own modules"

    assert {:error, text} =
             call_tool(Tools.LoadModule, %{path: "/nonexistent.beam"}, form_client_frame())

    assert text =~ "can't read /nonexistent.beam"
  end
end
