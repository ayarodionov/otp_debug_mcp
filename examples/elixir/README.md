# Elixir demo targets

Elixir nodes, each with a bug for otp_debug_mcp to find, plus a Mix
release for trying release-specific things. They need Elixir.

Start a demo by its command in the table below, e.g. `shop`, and stop
them all with `stop`:

```sh
examples/elixir/run.sh shop
examples/elixir/run.sh stop
```

`run.sh` starts each node in the background with `elixir --sname` on this
host, using the cookie in `~/.erlang.cookie`, which is also the tool's
default. The billing demo is compiled to `.beam` files in `ebin/` first,
because `module_code` reads a module's `.beam` and the other demos are
compiled in memory, from scripts. Node names end in `_ex` or start with `ex_`, so they can run
alongside the demos in the other languages.

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_ex` | `Shop.PriceCache`, a GenServer that takes 5 ms per update, gets casts far faster than that: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_ex` | An application whose `Payments.Gateway` parses a malformed URL a second after each start and raises, just under `Payments.Supervisor`'s restart limit: payments fail now and then | `diagnose` (`supervisor_restarts`, with the exit reason, file and line) |
| `cluster` | `ex_a`, `ex_b`, `ex_c` | Three connected nodes, only `ex_b` running the shop bug | `cluster`, pointed at a healthy node |
| `billing` | `billing_ex` | Routes defined with a macro DSL, `Billing.Router`. Its `timed` macro runs the block it wraps twice, so every charge is recorded twice in the ledger. No route's source shows the bug: it exists only after macro expansion | `module_code` (which functions the macro generated, and their code after expansion), `trace_calls` on `Billing.Ledger.record/2` |
| `release` | `demo_shop` | No bug: a Mix release with its own cookie (printed when it starts) and a nested supervision tree, with a DynamicSupervisor | `connect` with the release's cookie, `supervision_tree`, and reconnects after it's stopped and started again (`bin/demo_shop stop`, then `daemon`, in `demo_shop/_build/prod/rel/demo_shop`) |

To run one in the foreground instead:

```sh
elixir --sname payments_ex --no-halt examples/elixir/src/payments.exs
```

Then point Claude Code at a node, without telling it the bug:

> `payments_ex@yourhost` fails payments now and then. Find out why.

Tested that way, a headless session got the cause and the file and line
from `diagnose` alone; and pointed at the healthy `ex_a`, one ran
`cluster` first and went straight to `ex_b`.
