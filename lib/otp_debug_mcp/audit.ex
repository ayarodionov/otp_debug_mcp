defmodule OtpDebugMcp.Audit do
  @moduledoc """
  A record of every tool call, for answering "what did the agent do on
  the node?": one JSON line per call, appended to a local file, with the
  time, the node, the tool and its arguments, whether the step reads the
  node or changes something there, what came of it (ran, failed, asked
  the user, declined, refused in read-only mode) and how long it took.

  The file is `OTP_DEBUG_MCP_AUDIT_LOG`, or by default
  `~/.local/state/otp_debug_mcp/audit.jsonl`; `OTP_DEBUG_MCP_AUDIT_LOG=off`
  turns it off. A cookie given to `connect` is never written. Writing it
  never fails a tool call: if the file can't be written, the server logs
  that once, to stderr.
  """

  require Logger

  alias Anubis.Server.{InputRequired, Response}
  alias OtpDebugMcp.Target

  @doc "The file calls are written to, or nil when it's off."
  def path do
    case System.get_env("OTP_DEBUG_MCP_AUDIT_LOG") do
      off when off in ["off", "false", "none"] ->
        nil

      nil ->
        Path.join([System.user_home!(), ".local", "state", "otp_debug_mcp", "audit.jsonl"])

      "" ->
        nil

      path ->
        Path.expand(path)
    end
  end

  @doc """
  Run `fun`, the tool's step, and record the call: `fun` returns the
  tool's reply, from which the outcome is read. `outcome` overrides it
  for a step that wasn't run.
  """
  def call(name, params, effect, fun) do
    started = System.monotonic_time(:millisecond)
    reply = fun.()
    record(name, params, effect, outcome(reply), System.monotonic_time(:millisecond) - started)
    reply
  end

  @doc "Record a call that wasn't run, with why."
  def not_run(name, params, effect, why), do: record(name, params, effect, why, 0)

  defp outcome({:reply, %InputRequired{}, _frame}), do: "asked the user"
  defp outcome({:reply, %Response{isError: true}, _frame}), do: "failed"
  defp outcome({:reply, %Response{}, _frame}), do: "ran"
  defp outcome(_), do: "ran"

  defp record(name, params, effect, outcome, ms) do
    with path when is_binary(path) <- path() do
      line =
        %{
          at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
          node: node_of(name, params),
          tool: name,
          arguments: arguments(params),
          effect: effect,
          outcome: outcome,
          ms: ms
        }
        |> encode()

      write(path, line <> "\n")
    end

    :ok
  end

  defp node_of("connect", %{node: node}), do: node
  defp node_of(_name, _params), do: Target.connected_node() |> then(&(&1 && to_string(&1)))

  defp arguments(params) do
    params
    |> Map.drop([:__struct__])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn
      {:cookie, _} -> {:cookie, "(given, not recorded)"}
      {k, v} -> {k, v}
    end)
  end

  defp encode(map) do
    JSON.encode!(map)
  rescue
    _ -> JSON.encode!(%{map | arguments: inspect(map.arguments, limit: 50)})
  end

  defp write(path, line) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, line, [:append]) do
      :ok
    else
      {:error, reason} ->
        # Once per run: the next calls fail the same way.
        unless :persistent_term.get({__MODULE__, :warned}, false) do
          :persistent_term.put({__MODULE__, :warned}, true)
          Logger.warning("can't write the audit log #{path}: #{:file.format_error(reason)}")
        end
    end
  end
end
