# Erlang demo targets

Plain Erlang/OTP nodes, no Elixir, each with a bug for otp_debug_mcp to
find. They need only Erlang (`erl` and `erlc` on the `PATH`).

Start a demo by its command in the table below, e.g. `shop`, and stop
them all with `stop`:

```sh
examples/erlang/run.sh shop
examples/erlang/run.sh stop
```

`run.sh` compiles `src/` into `ebin/` and starts each node in the
background, with `-sname` on this host and the cookie in
`~/.erlang.cookie`, which is also the tool's default. Node names end in
`_erl` or start with `erl_`, so they can run alongside the demos in the
other languages. The `native` demo also needs a C compiler (`cc`, or set
`CC`): `run.sh` builds its NIF library against this Erlang's `erl_nif.h`.

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_erl` | `price_cache`, a gen_server that takes 5 ms per update, gets 25,000 casts a second from a producer: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_erl` | An OTP application whose `payments_gateway` parses a malformed URL a second after each start and crashes, just under `payments_sup`'s restart limit | `diagnose` (`supervisor_restarts`, with the exit reason and line), `supervision_tree` |
| `sessions` | `sessions_erl` | `sessions` makes an atom from every session id and never deletes its ETS rows: the atom table fills up in under an hour | `diagnose` (`atom_table`: the growth, and when the table will be full), snapshot diffs, `ets_tables`, `ets_table` (the rows: a new atom for every key, nothing deleted), `trace_calls` |
| `cluster` | `erl_a`, `erl_b`, `erl_c` | Three connected nodes, only `erl_b` running the shop bug | `cluster` |
| `ports` | `ports_erl` | `ports_shop`, three port bugs. `ports_client` opens a TCP connection per request, 5 a second, and never closes it. `ports_feed` sends 64 KB every 50 ms to a peer that reads 4 KB every 100 ms, so its socket queues up to 8 MB and its sends block. `ports_thumbnailer` starts an external program (`cat`) for every job, 2 a second, and never closes it | `diagnose` (`ports`: types, owners, write queues, external programs), snapshot diffs (`port_delta_by_type`, `port_delta_by_owner`), `port_info`, `trace_port` (`opened: true`) |
| `orders` | `orders_erl` | `orders`, an OTP application that keeps working while it fails, logging to `log/orders_erl.log`. At start it can't read its pricing rules and logs an error once. `orders_importer` crashes on a line with `n/a` for a quantity on every import, every 2 seconds, under `orders_sup`'s restart limit. `orders_payments` logs a warning when its provider is slow and an error when it times out. `orders_coupons` gives no discount for two of its five coupon codes, catching the error silently | `recent_errors` (crash groups with the stack and the bad argument, log groups with where they were logged, and the boot error from the log file), `module_code` with `at:`; for the coupons, which log nothing, `trace_calls` with `exceptions: true` |
| `locks` | `locks_erl` | `locks_shop`: `locks_stock` asks `locks_pricing` for a price in every reservation, and `locks_pricing`'s refresh, every 3 seconds, asks `locks_stock` for levels, both with timeout infinity. The first refresh during a reservation deadlocks them, and 20 shoppers' calls time out behind them | `diagnose` (`call_chains`: the deadlock, each side's request and timeout, the waiters stuck behind it), `module_code` |
| `crash` | `crash_erl` | `events_shop`: `events_source` sends 50,000 events a second to `events_writer`, which stores about 1,000. The node may use only 300 MB, so it runs out of memory within a minute and dies, writing `dumps/crash_erl.dump` | `crash_dump` on the dump: the cause, the writer's mailbox and stack, the events in it, and the sender that was running |
| `reports` | `reports_erl` | `reports`: two workers build a daily report again and again: every sale as a tuple in a list of 100,000, sorted by price, then summed. Most of the CPU goes to collecting that garbage, on the dirty CPU schedulers where large heaps are collected | `diagnose` (`scheduler_time`: `gc_share_of_work`), `top_reductions`, `profile`, `module_code` |
| `deploy` | `deploy_erl` | `deploy_shop`: `discounts` gives 5% off. After the node starts, `run.sh` compiles the fix (10%) into `deploy/ebin`, as a deploy that copies files would, but nothing loads it; and it loads `heartbeat` again, as `l(heartbeat)` in a remote shell would, while its process loops calling itself locally, so it stays in the old code | `diagnose` (`stale_code`: `discounts` modified on disk, `heartbeat`'s process in old code), `module_code` (which version runs) |
| `mnesia` | `mnesia_erl` | A shop on Mnesia (`mnesia_shop`, RAM tables): 20 shoppers place orders, each a transaction that write-locks the day's stats record and its product, then calls the payment provider's fraud check (`fraud:check/2`, 30 ms) before writing. Every order waits for the stats record, and Mnesia restarts most of them: an order takes up to a second | `mnesia` (the record waited for, its holders in `place_order/2`, restarts), `module_code` |
| `inventory` | `inventory_erl` | The shop's inventory, one gen_server holding every product's stock in a map. 20 shop processes reserve items, each every 50 ms, with `gen_server:call`: a map update. The warehouse dashboard asks the same server for a stock report every 700 ms, which values every product and takes about a third of a second, while every reservation sent meanwhile waits in the mailbox. The mailbox never holds more than the 20 waiting callers, so nothing looks long | `call_latency` on `inventory` (reservations waiting behind `stock_report`, its share of the server's time) |
| `tuning` | `tuning_erl` | `quote:build/1` prices an order's lines from a catalog of 5000 products and writes the quote's text: it walks the lines with `lists:nth`, looks each price up with `lists:keyfind` in the catalog list, and appends each line to the text with `++`, all quadratic. Four sales reps build quotes for 3000-line orders, about a second each. `tuning/quote_fast.erl` is a tuned version, to load and compare | `hot_spots` (most of the CPU in `quote:price_lines/5` itself, where its `++` runs, and in `lists:nth`), `profile`, `benchmark` (with `quote_fast:build/1` loaded: same result, about 100 times faster) |
| `dist` | `dist_a`, `dist_b` | `dist_shop`: `catalog` on `dist_a` sends the whole catalog, about 2 MB, to `mirror` on `dist_b` ten times a second, where a change would do; `checkout`'s calls to `dist_b` share the connection | `diagnose` (`distribution`: the bytes per second to `dist_b`; `long_schedules`: `catalog` suspended on the busy distribution port), `process_info`, `module_code` |
| `native` | `native_erl` | `native_shop`, an OTP application with a C NIF library, `native_nif`, and two classic NIF bugs. `checksum/1` does 80 ms of work on a normal scheduler without yielding, called by `native_pricing` every 300 ms: every process on that scheduler stalls. `parse/1` mallocs 256 KB a call and never frees it, called by `native_ingest` every 100 ms: the OS sees the node grow while `erlang:memory()` stays flat | `diagnose` (`long_schedules`, `native_memory`, `native_code`), snapshot diffs (`native_memory_delta_mb`), `module_code` (marks the NIFs), `profile` |

To run one by hand instead, in the foreground:

```sh
cd examples/erlang
mkdir -p ebin && erlc -o ebin src/*.erl && cp src/payments.app ebin/
erl -sname payments_erl -pa ebin -eval 'application:ensure_all_started(payments)'
```

Then point Claude Code at a node, without telling it the bug:

> `sessions_erl@yourhost` is a live Erlang node whose memory slowly grows,
> and the ops team worries it will crash in a few hours. Find out what is
> leaking and what in the code causes it.

Tested that way, a headless session found both leaks in `sessions`, the
`list_to_atom` call and the missing deletes, and worked out that the atom
table, not memory, would kill the node first.
