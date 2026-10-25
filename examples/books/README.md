# "Plausible but wrong", from the books

Six examples from the "Plausible but wrong" sections of
[Learning Erlang from Claude](https://github.com/ayarodionov/Learning-Erlang-from-Claude)
and [Learning Elixir from Claude](https://github.com/ayarodionov/Learning-Elixir-From-Claude),
each on a node of its own. Each node runs the book's code, with a few
lines around it to give it traffic. [docs/plausible-but-wrong.md](../../docs/plausible-but-wrong.md)
shows what an agent given only the symptom found on each.

They need Erlang and Elixir. The `telemetry` demo fetches the telemetry
library from Hex the first time (with `Mix.install`).

```sh
examples/books/run.sh all     # or one: lock, slice, loop, conn, parse, telemetry
examples/books/run.sh stop
```

`run.sh` compiles `erlang/` and `elixir/` into `ebin/` and starts each
node in the background, with `-sname` on this host and the cookie in
`~/.erlang.cookie`, which is also the tool's default.

| Command | Node | Book section | The bug | Symptom to give | What finds it |
|---|---|---|---|---|---|
| `lock` | `book_lock` | Erlang 5.4.6, two servers calling each other | `tally:get_total` calls `rates:sum`; `rates:refresh` calls `tally:rate`. When the two overlap, both wait 5 seconds, then crash | the totals page sometimes hangs for about 5 seconds and then fails | `recent_errors` (`deadlocks`: the two crashed calling each other), `diagnose` (`call_chains`, while the deadlock lasts) |
| `slice` | `book_slice` | Erlang 3.4.3, keeping a small slice of a huge binary | `headers` keeps a 512-byte slice of each 1 MB body, for 200 sessions, pinning 200 MB | memory keeps growing to hundreds of MB, though it stores little | `diagnose` (`binary_leak`: `held_binaries` tells slices from whole binaries) |
| `loop` | `book_loop` | Erlang 2.4.1, a receive loop with no catch-all | `counter` matches `{add, X}` and `{get, From}`; refunds send `{sub, X}`, which stay in its mailbox | the counter answers more and more slowly, and memory grows | `diagnose` (`message_queues`), `process_info`, snapshot diffs |
| `conn` | `book_conn` | Erlang 1.4.5, permanent per-connection workers | 50 `conn` workers under a `simple_one_for_one` supervisor with the default limits; every 20 seconds one client sends `<<"12,5">>` twice, and they all go | all 50 connections are dropped at once, though one client sends bad data | `diagnose` (`supervisor_restarts`), `recent_errors` (the crash, then `reached_max_restart_intensity`) |
| `parse` | `book_parse` | Elixir 2.4.1, parsing by catching exceptions | `Gateway.parse_port/1` rescues the `ArgumentError` of `String.to_integer/1`; half its inputs fail, and nothing is logged | many ports are counted invalid, but nothing is logged | `trace_calls` with `process: "Gateway"` and `exceptions: true`: each failing call, with where it was made |
| `telemetry` | `book_telemetry` | Elixir 13.4.4, a handler that raises once and disappears | `Metrics.handle_event/4` requires `:source`; about 30 seconds after start a query has none, and telemetry detaches the handler | the db.query metrics went flat, but queries still run | `telemetry` (no handlers left, events still firing), `trace_calls` |
