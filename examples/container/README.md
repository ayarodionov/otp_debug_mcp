# Container demo

An Erlang pricing service in Docker, limited to one CPU and 256 MB, but
started with the `vm.args` it had on the 8-core machine it used to run
on: `+S 8:8 +sbwt very_long`. For the `vm_config` check, which `diagnose`
runs first.

- Baskets come in bursts, 80 every quarter of a second, each priced by
  one of 8 workers in about 2 ms of CPU. Eight schedulers spend the
  container's 100 ms of CPU per 100 ms period early in the period, and
  the kernel stops the whole VM until the next one: its own health
  check, due every 10 ms, runs up to 80 ms late. Busy-waiting
  schedulers spend the quota spinning too.
- A price cache in ETS, about 120 MB, and a latency table that nothing
  trims, take the node to the edge of the container's memory limit.
- The service sets the logger to `debug` at start, and logs every basket.

```sh
examples/container/run.sh start     # docker run erlang:27-slim --cpus=1 --memory=256m
examples/container/run.sh stop
```

It needs Docker. `pricing:latency()` gives the last minute's latencies,
baskets' and health checks'.

## Connecting

The service runs as `svc@127.0.0.1` with the cookie `containerdemo`,
listening for distribution on port 9300 without epmd. Register a server
for it, next to your usual one:

```sh
claude mcp add otp-debug-container --scope user \
  -e ERL_FLAGS="-erl_epmd_port 9300" -e OTP_DEBUG_MCP_COOKIE=containerdemo \
  -- "$server" start
```

(see [docs/production.md](../../docs/production.md)). Then ask, for
example:

> Our pricing service runs in a container, as svc@127.0.0.1 (cookie
> containerdemo). Every few seconds it stalls for up to 100 ms, though
> its CPU use looks moderate, and it was OOM-killed twice this week.
> Find out why.

Walkthrough 32 in [docs/walkthroughs.md](../../docs/walkthroughs.md).
