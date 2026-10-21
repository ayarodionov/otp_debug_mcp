# Gleam demo targets

Gleam services on the BEAM, each with a bug for otp_debug_mcp to find. They
use the standard `gleam_otp` actors and supervisors, and need Gleam and
Erlang (`gleam`, `erl` on the `PATH`).

Start a demo by its command in the table below, e.g. `shop`, and stop
them all with `stop`:

```sh
examples/gleam/run.sh shop
examples/gleam/run.sh stop
```

`run.sh` runs `gleam build`, then starts each node in the background with
`erl`, with `-sname` on this host and the cookie in `~/.erlang.cookie`,
which is also the tool's default. (Set `GLEAM` to use a `gleam` binary
that isn't on the `PATH`.)

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_gleam` | A `price_cache` actor that takes 5 ms per update gets 25,000 a second from a producer: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_gleam` | A static supervisor whose gateway actor parses a malformed URL a second after each start, and its `let assert` panics, just under the restart limit | `diagnose` (`supervisor_restarts`, with Gleam's panic details: module, function, line and the value that didn't match) |
| `jobs` | `jobs_gleam` | Every job spawns a worker that waits forever for a reply nobody sends: the process count climbs about 170 a second | `diagnose` (`process_count`, whose largest group's stack points at the line), snapshot diffs |

Gleam modules are Erlang modules on the BEAM: `src/shop.gleam` is the
module `shop`, so `trace_calls` takes `shop` and a function name such as
`handle_message`. Values appear as Erlang sees them, e.g. a custom type
`Update(sku: 1, price: 2)` as `{update,1,2}`.

To run one in the foreground instead, stopping it with Ctrl-C twice:

```sh
cd examples/gleam
gleam run -m jobs
```

That node has no name; for the tool to reach it, start it as `run.sh` does,
or give `gleam run` a name through `ERL_FLAGS="-sname jobs_gleam"`.

Then point Claude Code at a node, without telling it the bug:

> `jobs_gleam@yourhost` is a live node running a Gleam service whose memory
> keeps growing. Find out what is leaking and what in the code causes it.

Tested that way, a headless session found the leaking workers through
`diagnose`, the line in `jobs.gleam` that holds them, and why: a reply
subject the job creates itself, which nobody else can ever send to.
