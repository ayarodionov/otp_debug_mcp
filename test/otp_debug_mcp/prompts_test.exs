defmodule OtpDebugMcp.PromptsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.{Frame, Response}
  alias OtpDebugMcp.{Capabilities, Prompts, Server}

  defp text(prompt, args) do
    {:reply, response, _frame} = prompt.get_messages(args, Frame.new())

    %{"messages" => [%{"role" => "user", "content" => %{"text" => text}}]} =
      Response.to_protocol(response)

    text
  end

  test "the server offers investigate, watch and help" do
    names = Server.__components__(:prompt) |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["help", "investigate", "watch"]
  end

  test "investigate names the node and the symptom, and how to answer" do
    t = text(Prompts.Investigate, %{node: "shop_ex@host", symptom: "It gets slower every hour."})
    assert t =~ "Investigate the running node `shop_ex@host`"
    assert t =~ "It gets slower every hour."
    assert t =~ "diagnose"
    assert t =~ "If nothing is wrong now, say so"

    # Without a symptom, and with arguments as the wire sends them.
    assert text(Prompts.Investigate, %{"node" => "a@b"}) =~ "Something seems wrong with it"
  end

  test "watch records for the minutes asked, a day at most" do
    assert text(Prompts.Watch, %{node: "a@b", minutes: "30"}) =~ "flight recorder for 30 minutes"
    assert text(Prompts.Watch, %{node: "a@b", minutes: "5000"}) =~ "for 1440 minutes"
    assert text(Prompts.Watch, %{node: "a@b"}) =~ "for 60 minutes"
    assert text(Prompts.Watch, %{node: "a@b"}) =~ "wait_for_problem"
  end

  test "help lists every situation, and calls no tool" do
    t = text(Prompts.Help, %{})
    assert t =~ "Don't call any tool."

    for {situation, _tools} <- Capabilities.situations(), do: assert(t =~ situation)
  end

  test "the capabilities name only tools the server has" do
    tools = MapSet.new(Server.__components__(:tool), & &1.name)

    for {_situation, text} <- Capabilities.situations(),
        [name] <- Regex.scan(~r/\b[a-z]+(?:_[a-z]+)+\b/, text),
        name != "erl_crash",
        do: assert(name in tools, "#{name} isn't a tool")
  end

  test "--help's list fits 80 columns" do
    for line <- String.split(Capabilities.text(), "\n"), do: assert(String.length(line) <= 80)
  end
end
