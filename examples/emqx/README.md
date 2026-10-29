# EMQX demo

EMQX 5, the MQTT broker, in Docker, with clients that misbehave in two
classic ways, for the `emqx` tool:

- **A dashboard that never acknowledges.** `dashboard-1` subscribes to
  `sensors/#` at QoS 1 and reads what EMQX sends, but never sends a
  PUBACK (a client library set to manual acknowledgement, and code that
  never acks). EMQX keeps 32 messages in flight for it, queues 1000 more,
  and drops the rest: the dashboard misses readings.
- **Two devices with one client id.** Both connect as `sensor-7`; each
  connection discards the other's session, and each reconnects at once,
  forever.

Meanwhile 19 sensors publish readings at QoS 1, ten a second each.

```sh
examples/emqx/run.sh start      # docker run emqx/emqx:5.8.6, and clients.py
examples/emqx/run.sh stop
```

It needs Docker and Python 3 (no MQTT library: `clients.py` speaks MQTT
3.1.1 itself). The first start pulls the image.

## Connecting

EMQX runs as `emqx@127.0.0.1` with the cookie `emqxdemo`. It listens for
distribution on port 4370 and doesn't use epmd, so the server dials that
port directly: register one for it, next to your usual one, with

```sh
claude mcp add otp-debug-emqx --scope user \
  -e ERL_FLAGS="-erl_epmd_port 4370" -e OTP_DEBUG_MCP_COOKIE=emqxdemo \
  -- "$server" start
```

(`-erl_epmd_port` makes the server dial that port for every node, so it
reaches only nodes on it: see [docs/production.md](../../docs/production.md).)
Then ask, for example:

> Our dashboard (MQTT client `dashboard-1`) misses sensor readings, and
> device `sensor-7` keeps going offline. EMQX is `emqx@127.0.0.1`.
> Find out why.

Walkthrough 28 in [docs/walkthroughs.md](../../docs/walkthroughs.md).
