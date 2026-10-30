# RabbitMQ demo

RabbitMQ 4, in Docker, with AMQP clients that run into the classic
trouble, for the `rabbitmq` tool:

- **A consumer with no prefetch limit.** The order worker consumes
  `orders` without `basic.qos` (its client library's default), so
  RabbitMQ sends it every order as it's published, about 300 a second, while it
  handles 60: the rest wait, delivered but unacknowledged, in RabbitMQ's
  memory (and the worker's).
- **A queue nobody reads.** The email service that consumed `email` was
  retired; the order services still publish a notification there per
  order, and the queue keeps every one.
- **A memory alarm.** The broker's high watermark is 300 MiB
  (`rabbitmq.conf`). Within two minutes the unacknowledged orders and the
  emails reach it, and RabbitMQ blocks every publishing connection: the
  order services hang on publish, with nothing in their logs.

```sh
examples/rabbitmq/run.sh start    # docker run rabbitmq:4.1, and clients.py
examples/rabbitmq/run.sh stop
```

It needs Docker and Python 3 (no AMQP library: `clients.py` speaks
enough AMQP 0-9-1 itself). The first start pulls the image.

## Connecting

RabbitMQ runs as `rabbit@localhost`, with the cookie `rabbitdemo` (given
on its command line). It listens for distribution on port 25672, which
the container publishes; the server dials that port directly, without
epmd: register one for it, next to your usual one, with

```sh
claude mcp add otp-debug-rabbitmq --scope user \
  -e ERL_FLAGS="-erl_epmd_port 25672" -e OTP_DEBUG_MCP_COOKIE=rabbitdemo \
  -- "$server" start
```

(see [docs/production.md](../../docs/production.md)). Then ask, for
example:

> Our order services hang when they publish to RabbitMQ, for minutes at
> a time, though the order worker is running. RabbitMQ is
> `rabbit@localhost`. Find out why.

Walkthrough 34 in [docs/walkthroughs.md](../../docs/walkthroughs.md).
