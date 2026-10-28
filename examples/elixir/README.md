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
compiled in memory, from scripts. The Phoenix demo is a Mix project:
the first `run.sh phoenix` fetches its dependencies from Hex, then it's
built in dev, which keeps debug info. Node names end in `_ex` or start with `ex_`, so they can run
alongside the demos in the other languages.

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_ex` | `Shop.PriceCache`, a GenServer that takes 5 ms per update, gets casts far faster than that: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_ex` | An application whose `Payments.Gateway` parses a malformed URL a second after each start and raises, just under `Payments.Supervisor`'s restart limit: payments fail now and then | `diagnose` (`supervisor_restarts`, with the exit reason, file and line) |
| `cluster` | `ex_a`, `ex_b`, `ex_c` | Three connected nodes, only `ex_b` running the shop bug | `cluster`, pointed at a healthy node |
| `billing` | `billing_ex` | Routes defined with a macro DSL, `Billing.Router`. Its `timed` macro runs the block it wraps twice, so every charge is recorded twice in the ledger. No route's source shows the bug: it exists only after macro expansion | `module_code` (which functions the macro generated, and their code after expansion), `trace_calls` on `Billing.Ledger.record/2` |
| `phoenix` | `phoenix_ex` | A Phoenix 1.8 JSON API (in `phoenix_shop/`, served by Bandit on port 4040) whose product search always returns 404. `resources "/products", ..., only: [:index, :show]` generates `GET /products/:id`, which matches `/products/search` before the `get "/products/search"` route after it, so search requests reach `show` with `id: "search"`. The source never mentions `:id`, and it compiles without a warning | `module_code` on the router (its `__match_route__/3` clauses, in matching order), `trace_calls` on the controller |
| `cowboy` | `cowboy_ex` | An Erlang API on Cowboy (in `cowboy_shop/`, port 8090) with Ranch's limits at 4 acceptors × 10 connections, and its own clients: 60 accountants asking for sales reports, which one gen_server renders one at a time, 300 ms each, and 10 shoppers browsing products, every request on a new connection. The report requests hold every connection, the acceptors wait for room, and a request for the trivial `/products` waits seconds to be accepted | `cowboy` (acceptors waiting, the requests in flight in `report_handler`), `process_info` on `report_server` |
| `yaws` | `yaws_ex` | An Erlang API on Yaws, embedded (in `yaws_shop/`, port 8095; Yaws is fetched from GitHub and builds a PAM driver, `libpam0g-dev` on Debian and Ubuntu), with its own clients: 10 shoppers looking at their carts through a mobile app that keeps no cookies. The cart appmod starts a new cookie session on every request instead of looking for the shopper's, so the sessions, each holding a cart and recommendations, pile up for an hour and a half: memory grows about 12 MB a minute | `yaws` (sessions used once, growing), `module_code` on `shop_api` |
| `bandit` | `bandit_ex` | A Plug API (in `bandit_shop/`, served by Bandit on port 4050) whose connections were capped at 100 (4 acceptors × 25), with traffic built in: 30 clients asking for recommendations, which wait 3 seconds on a slow upstream inside the request, and 120 browsing products on keep-alive connections. The server is full: the acceptors wait for room, new clients wait unaccepted, and some are refused, which nothing logs | `bandit` (the limit, acceptors waiting, the busy connections by where they wait, refused connections), `module_code` |
| `riak` | `riak_a`, `riak_b`, `riak_c` | A shop on riak_core (in `riak_shop/`, on riak_core_lite from Hex): carts in `shop_vnode`, a 16-partition ring. `run.sh` forms the cluster, waits for its handoffs, then stops `riak_c`, still a member, and starts the traffic on `riak_a`: 20 shoppers, and a flash sale where everyone adds to one cart, whose vnode takes 5 ms an add and falls behind | `riak_core` (the member down, fallbacks, the swamped vnode on `riak_b` near its overload threshold), `trace_calls` on the vnode |
| `wishlist` | `riak_a`, `riak_b` | The same project, with riak_dt: wishlists kept as riak_dt sets in `wishlist_vnode`, merged on handoff. `run.sh` forms a two-node cluster, then 10 shoppers add to 20 wishlists from `riak_a`, each request in a process of its own, which `riak_shop:wish/2` passes as the set's actor: a new actor for every add, so the sets' clocks grow with every request though each holds at most 30 items | `riak_core` with `crdts: true` (sets with thousands of actors), `module_code` on `riak_shop` |
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
