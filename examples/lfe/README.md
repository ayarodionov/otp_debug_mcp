# LFE demo targets

LFE (Lisp Flavoured Erlang) services, each with a bug for otp_debug_mcp to
find. They're plain OTP: gen_servers, a supervisor, an application.

Start a demo by its command in the table below, e.g. `shop`, and stop
them all with `stop`:

```sh
examples/lfe/run.sh shop
examples/lfe/run.sh stop
```

`run.sh` compiles `src/` with `lfec` into `ebin/`, then starts each node in
the background with `erl`. Compiled LFE needs nothing from LFE at runtime,
only Erlang. Nodes get `-sname` on this host and the cookie in
`~/.erlang.cookie`, which is also the tool's default. `lfec` has to be on
the `PATH`, or set `LFE` to an LFE install or checkout (with `lfec` in its
`bin/`). To build LFE itself, here in `~/src/lfe`, and run a demo with it
from the root of this repository:

```sh
git clone --depth 1 --branch v2.2.2 https://github.com/lfe/lfe.git ~/src/lfe
make -C ~/src/lfe compile
LFE=~/src/lfe examples/lfe/run.sh shop
```

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_lfe` | `price-cache`, a gen_server that takes 5 ms per update, gets 25,000 casts a second from a producer: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_lfe` | An OTP application whose `payments-gateway` parses a malformed URL a second after each start and crashes, just under `payments-sup`'s restart limit | `diagnose` (`supervisor_restarts`, with the exit reason and line) |
| `logs` | `logs_lfe` | `log-index` keeps each 16 KB record's 256-byte header as a preview, a slice that pins the whole record: about 800 KB a second | `diagnose` (`binary_leak`: the process holding the binaries, and that they're slices) |

LFE modules are Erlang modules, and a hyphenated name like `price-cache` is
the Erlang atom `'price-cache'`: give `trace_calls` the module as
`price-cache`, and `process_info` a registered name as `log-index` or
`'log-index'`. Terms are shown in Erlang syntax.

Then point Claude Code at a node, without telling it the bug:

> `logs_lfe@yourhost` is a live node running an LFE service whose memory
> keeps growing. Find out what is leaking and what in the code causes it.

A note on the `logs` bug: on OTP 28 the runtime copies slices of 64 bytes
or less when it collects garbage, so keeping a short id from each record
wouldn't leak; keeping anything longer does.
