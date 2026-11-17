defmodule OtpDebugMcp.Prompts do
  @moduledoc """
  MCP prompts: starting points a user picks from the client's menu (in
  Claude Code, the / menu) without knowing the tools' names. Each fills in
  the opening message of an investigation; the agent takes it from there,
  with the tools and the server's instructions.
  """

  alias Anubis.Server.Response

  @doc false
  def reply(text, frame), do: {:reply, Response.prompt() |> Response.user_message(text), frame}

  @doc false
  def arg(args, key), do: args[key] || args[Atom.to_string(key)]

  defmodule Investigate do
    @moduledoc """
    Find out what is wrong with a running Erlang/Elixir node, from the symptom
    you describe: connect, diagnose, drill into what it finds, read the code,
    and answer with the cause, the evidence and the fix.
    """
    use Anubis.Server.Component, type: :prompt, name: "investigate"

    alias OtpDebugMcp.Prompts

    schema do
      field(:node, {:required, :string}, description: "The node's name, e.g. myapp@myhost")

      field(:symptom, :string,
        description: "What's wrong, as you'd tell a colleague, e.g. it gets slower every hour"
      )
    end

    @impl true
    def get_messages(args, frame) do
      node = Prompts.arg(args, :node)

      symptom =
        case Prompts.arg(args, :symptom) do
          s when is_binary(s) and s != "" -> s
          _ -> "Something seems wrong with it, and I'd like to know what."
        end

      """
      Investigate the running node `#{node}` with the otp-debug tools. #{symptom}

      Connect, then run diagnose and report what it concludes before drilling in. \
      If a flight recorder runs there, read its history for what happened before you \
      connected. Confirm a cause in the code (module_code) before proposing a fix. \
      End with the cause, the evidence for it, the fix, and what you didn't verify. \
      If nothing is wrong now, say so rather than guessing.
      """
      |> Prompts.reply(frame)
    end
  end

  defmodule Watch do
    @moduledoc """
    Watch a node for a problem that comes and goes: start a flight recorder
    on it, wait until a new problem shows, then investigate it while it's
    happening.
    """
    use Anubis.Server.Component, type: :prompt, name: "watch"

    alias OtpDebugMcp.Prompts

    schema do
      field(:node, {:required, :string}, description: "The node's name, e.g. myapp@myhost")

      field(:minutes, :string,
        description: "How long to record and watch, in minutes (default 60, at most 1440)"
      )
    end

    @impl true
    def get_messages(args, frame) do
      node = Prompts.arg(args, :node)

      minutes =
        case Integer.parse(to_string(Prompts.arg(args, :minutes) || "")) do
          {n, _} when n > 0 -> min(n, 1440)
          _ -> 60
        end

      """
      Watch the node `#{node}` for a problem that comes and goes, with the otp-debug tools.

      Connect, and start a flight recorder for #{minutes} minutes (record; it asks me \
      first, since it leaves a process on the node). Then call wait_for_problem, again \
      each time it returns with nothing new, until it reports a problem or the \
      #{minutes} minutes are over; tell me every few calls that you're still watching. \
      When it reports one, investigate it at once, while it's happening: diagnose, \
      the process or table it names, and history for when it began. End with the \
      cause and the fix, or, if nothing happened, say so and what was already wrong \
      when you started.
      """
      |> Prompts.reply(frame)
    end
  end

  defmodule Help do
    @moduledoc """
    What the otp-debug tools can do, by situation, with an example of what to
    ask for each.
    """
    use Anubis.Server.Component, type: :prompt, name: "help"

    alias OtpDebugMcp.{Capabilities, Prompts}

    schema do
    end

    @impl true
    def get_messages(_args, frame) do
      """
      Explain briefly what the otp-debug tools can do for me, by situation, from \
      this list, with one example of what I could ask for each, in my own words. \
      Mention that I describe the problem and you pick the tools; that nothing needs \
      changing in the node being debugged; and the prompts investigate and watch. \
      Don't call any tool.

      #{Capabilities.text("- ", 1000)}
      """
      |> Prompts.reply(frame)
    end
  end
end
