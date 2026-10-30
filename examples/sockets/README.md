# Sockets demo

An Erlang quotes service in Docker, with its sockets set up the way code
often leaves them, for the `socket_tuning` tool. It runs on Linux in the
container because that's where Nagle's algorithm and delayed
acknowledgements cost 40 ms on loopback (macOS acknowledges loopback
traffic at once).

- **A request written in two pieces, with Nagle on.** The quote frontend
  writes each request to the pricing backend as `QUOTE ` and then the
  sku, with gen_tcp's default `nodelay` false. The second write waits
  for the first's acknowledgement, which the backend delays: every quote
  takes about 41 ms, though the backend answers in microseconds.
- **`{active, true}` and a slow owner.** The metrics collector takes each
  agent line as a message and stores it in a millisecond; its agent
  sends a few thousand a second, and the collector's mailbox, and the
  node's memory, grow without end.
- **A blocked export, with no send timeout.** The nightly price export
  streams to the warehouse's loader, which reads a kilobyte a second;
  the exporter blocks in `gen_tcp:send` with 100 KB queued, and with
  `send_timeout` infinity it never gives up.

```sh
examples/sockets/run.sh start     # docker run erlang:27-slim
examples/sockets/run.sh stop
```

`quotes:latency()` gives the last quotes' latency.

## Connecting

The service runs as `quotes@127.0.0.1` with the cookie `socketsdemo`,
listening for distribution on port 9400 without epmd. Register a server
for it, next to your usual one:

```sh
claude mcp add otp-debug-sockets --scope user \
  -e ERL_FLAGS="-erl_epmd_port 9400" -e OTP_DEBUG_MCP_COOKIE=socketsdemo \
  -- "$server" start
```

Then ask, for example:

> Quotes from our quotes service, quotes@127.0.0.1 (in a container,
> cookie socketsdemo), take 40 ms each, though the pricing backend
> answers in microseconds; the node's memory keeps growing, and the
> nightly price export never finishes. Find out why.

Walkthrough 35 in [docs/walkthroughs.md](../../docs/walkthroughs.md).
