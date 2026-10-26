defmodule OtpDebugMcp.ApprovalTest do
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{TestTarget, Tools}

  setup_all do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    %{target: target}
  end

  setup %{target: target} do
    {:ok, _} = TestTarget.connect(target)
    on_exit(fn -> System.delete_env("OTP_DEBUG_MCP_CONFIRM") end)
    :ok
  end

  defp confirm(mode), do: System.put_env("OTP_DEBUG_MCP_CONFIRM", mode)

  defp answer(%{input_requests: %{"step" => _}, request_state: {:set, state}}, action),
    do: form_client_frame(%{"step" => %{"action" => action, "content" => %{}}}, state)

  test "all: asks before a step that only reads, and runs it once accepted", %{target: target} do
    confirm("all")
    params = %{check: "process_count"}

    assert {:input_required, input} = call_tool(Tools.RunCheck, params, form_client_frame())
    %{"step" => %{"method" => "elicitation/create", "params" => ask}} = input.input_requests
    assert ask["message"] =~ "Run run_check on #{target.node}?"
    assert ask["message"] =~ "Runs the process_count check: reads the node."
    assert ask["message"] =~ ~s(Arguments: check: "process_count")

    assert {:ok, %{"check" => "process_count"}} =
             call_tool_json(Tools.RunCheck, params, answer(input, "accept"))
  end

  test "a declined step doesn't run, and the agent is told to ask the user" do
    confirm("all")
    assert {:input_required, input} = call_tool(Tools.Diagnose, %{}, form_client_frame())
    assert input.input_requests["step"]["params"]["message"] =~ "forces a garbage collection"

    assert {:error, text} = call_tool(Tools.Diagnose, %{}, answer(input, "decline"))
    assert text =~ "The user declined this step (diagnose): nothing was run"
    assert text =~ "ask the user"
  end

  test "an answer counts only for the call it was given for" do
    confirm("all")

    assert {:input_required, input} =
             call_tool(Tools.RunCheck, %{check: "atom_table"}, form_client_frame())

    # The same answer, replayed for another step: asked again.
    assert {:input_required, _} =
             call_tool(Tools.RunCheck, %{check: "binary_leak"}, answer(input, "accept"))
  end

  test "a client that can't ask gets nothing run" do
    confirm("all")
    assert {:error, text} = call_tool(Tools.RunCheck, %{check: "process_count"})
    assert text =~ "OTP_DEBUG_MCP_CONFIRM=all"
    assert text =~ "Nothing was run"
  end

  test "changes: asks only for steps that do something on the node" do
    confirm("changes")

    assert {:ok, %{"check" => "process_count"}} =
             call_tool_json(Tools.RunCheck, %{check: "process_count"}, form_client_frame())

    assert {:input_required, input} =
             call_tool(Tools.RunCheck, %{check: "binary_leak"}, form_client_frame())

    assert input.input_requests["step"]["params"]["message"] =~ "Forces a garbage collection"

    assert {:input_required, _} =
             call_tool(Tools.TraceCalls, %{module: "lists", function: "seq"}, form_client_frame())
  end

  test "load_module keeps its own dialog, asked once" do
    confirm("all")
    path = Path.join(System.tmp_dir!(), "no_such_module.beam")
    assert {:error, text} = call_tool(Tools.LoadModule, %{path: path}, form_client_frame())
    refute text =~ "OTP_DEBUG_MCP_CONFIRM"
  end
end
