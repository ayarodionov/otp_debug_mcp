defmodule OtpDebugMcp.ToolCase do
  @moduledoc "Call MCP tool components directly and decode what a client would receive."

  alias Anubis.Server.{Frame, InputRequired, Response}

  @doc """
  Returns `{:ok | :error, text}`, as the tool result's content and isError
  flag, or `{:input_required, input}` when the tool asks the client for
  input first.
  """
  def call_tool(tool, params, frame \\ Frame.new()) do
    case tool.execute(params, frame) do
      {:reply, %InputRequired{} = input, _frame} ->
        {:input_required, input}

      {:reply, response, _frame} ->
        %{"content" => [%{"text" => text}], "isError" => error?} = Response.to_protocol(response)
        {if(error?, do: :error, else: :ok), text}
    end
  end

  @doc "Like `call_tool/3`, with the text decoded as JSON."
  def call_tool_json(tool, params, frame \\ Frame.new()) do
    case call_tool(tool, params, frame) do
      {:input_required, _} = input -> input
      {status, text} -> {status, JSON.decode!(text)}
    end
  end

  @doc """
  The frame of a request from a client of the stateless protocol era that
  can show forms, carrying the answers and the (already verified) state of
  a retry.
  """
  def form_client_frame(responses \\ %{}, state \\ nil) do
    frame = Frame.new()

    context = %{
      frame.context
      | protocol_version: "2026-07-28",
        client_capabilities: %{"elicitation" => %{"form" => %{}}},
        input_responses: responses,
        request_state: state
    }

    %{frame | context: context}
  end
end
