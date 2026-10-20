defmodule OtpDebugMcp.ToolCase do
  @moduledoc "Call MCP tool components directly and decode what a client would receive."

  alias Anubis.Server.{Frame, Response}

  @doc "Returns `{:ok | :error, text}`, as the tool result's content and isError flag."
  def call_tool(tool, params) do
    {:reply, response, _frame} = tool.execute(params, Frame.new())
    %{"content" => [%{"text" => text}], "isError" => error?} = Response.to_protocol(response)
    {if(error?, do: :error, else: :ok), text}
  end

  @doc "Like `call_tool/2`, with the text decoded as JSON."
  def call_tool_json(tool, params) do
    {status, text} = call_tool(tool, params)
    {status, JSON.decode!(text)}
  end
end
