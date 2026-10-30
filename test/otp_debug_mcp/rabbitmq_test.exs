defmodule OtpDebugMcp.RabbitmqTest do
  @moduledoc """
  Against a running RabbitMQ node, given by RABBITMQ_NODE and
  RABBITMQ_COOKIE, with AMQP on RABBITMQ_AMQP_PORT (default 5672) for
  user test, password test, e.g. from Docker:

      docker run -d --name rabbitmq -e RABBITMQ_NODENAME=rabbit@localhost \\
        -e RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-setcookie secret" \\
        -e RABBITMQ_DEFAULT_USER=test -e RABBITMQ_DEFAULT_PASS=test \\
        -p 5672:5672 -p 25672:25672 rabbitmq:4.1
      RABBITMQ_NODE=rabbit@localhost RABBITMQ_COOKIE=secret \\
        ERL_FLAGS="-erl_epmd_port 25672 -dist_listen false" mix test --only rabbitmq

  RabbitMQ listens for distribution on 25672, so the test VM connects
  there directly, without epmd. The tests make their own queues.
  """
  use ExUnit.Case, async: false

  import OtpDebugMcp.ToolCase

  alias OtpDebugMcp.{Amqp, Checks, TestTarget, Tools}

  defp port, do: String.to_integer(System.get_env("RABBITMQ_AMQP_PORT", "5672"))

  defp connect do
    {:ok, _} =
      call_tool_json(Tools.Connect, %{
        node: System.fetch_env!("RABBITMQ_NODE"),
        cookie: System.fetch_env!("RABBITMQ_COOKIE")
      })
  end

  defp rabbitmq(params), do: call_tool_json(Tools.Rabbitmq, params)

  defp queue(what) do
    name = "otpdbg-#{what}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      connect()

      Checks.remote_eval(
        "rabbit_amqqueue:delete_immediately_by_resource([rabbit_misc:r(<<\"/\">>, queue, Q)]).",
        Q: name
      )
    end)

    name
  end

  defp amqp, do: Amqp.connect(port(), "test", "test")

  defp find(r, name), do: Enum.find(r["busiest_queues"] || [], &(&1["queue"] == name))

  @tag :rabbitmq
  test "the broker: version, cluster, memory against its watermark" do
    connect()
    assert {:ok, r} = rabbitmq(%{duration_ms: 500})
    assert r["version"] =~ ~r/^RabbitMQ \d/
    assert [_ | _] = r["cluster"]["running"]
    assert r["memory"]["limit_bytes"] > 0
  end

  @tag :rabbitmq
  test "a queue nobody consumes" do
    connect()
    name = queue("orphan")
    s = amqp()
    on_exit(fn -> :gen_tcp.close(s) end)
    Amqp.declare(s, name)
    for i <- 1..1_200, do: Amqp.publish(s, name, "message #{i}")
    Process.sleep(500)

    assert {:ok, r} = rabbitmq(%{duration_ms: 500})
    assert %{"messages" => 1_200, "consumers" => 0, "ready" => 1_200} = find(r, name)
    assert Enum.any?(r["findings"], &(&1 =~ "queue #{name} has 1200 messages and no consumers"))
  end

  @tag :rabbitmq
  test "a consumer with no prefetch limit holds everything unacknowledged" do
    connect()
    name = queue("greedy")
    publisher = amqp()
    consumer = amqp()

    on_exit(fn ->
      :gen_tcp.close(publisher)
      :gen_tcp.close(consumer)
    end)

    Amqp.declare(publisher, name)
    Amqp.declare(consumer, name)
    Amqp.consume(consumer, name)
    spawn(fn -> Amqp.drain(consumer) end)
    for i <- 1..1_500, do: Amqp.publish(publisher, name, "message #{i}")
    Process.sleep(1_000)

    assert {:ok, r} = rabbitmq(%{duration_ms: 500})
    assert %{"unacknowledged" => 1_500, "ready" => 0, "consumers" => 1} = find(r, name)

    assert %{"prefetch" => 0, "unacknowledged" => 1_500} =
             Enum.find(r["channels_holding_unacked"], &(&1["unacknowledged"] == 1_500))

    assert Enum.any?(r["findings"], &(&1 =~ "with no prefetch limit"))
  end

  test "explains a node without RabbitMQ" do
    target = TestTarget.start()
    on_exit(fn -> TestTarget.stop(target) end)
    {:ok, _} = TestTarget.connect(target)
    assert {:error, text} = call_tool(Tools.Rabbitmq, %{})
    assert text =~ "doesn't run RabbitMQ"
  end
end
