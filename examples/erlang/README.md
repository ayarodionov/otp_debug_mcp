# Erlang demo targets

Plain Erlang/OTP nodes, no Elixir, each with a bug for otp_debug_mcp to
find. They need only Erlang (`erl` and `erlc` on the `PATH`).

```sh
examples/erlang/run.sh shop        # start one (see below)
examples/erlang/run.sh stop        # stop them all
```

`run.sh` compiles `src/` into `ebin/` and starts each node in the
background, with `-sname` on this host and the cookie in
`~/.erlang.cookie`, which is also the tool's default. Node names end in
`_erl` or start with `erl_`, so they can run alongside the Elixir demos in
`scripts/`.

| Command | Node | The bug | What finds it |
|---|---|---|---|
| `shop` | `shop_erl` | `price_cache`, a gen_server that takes 5 ms per update, gets 25,000 casts a second from a producer: its mailbox never drains | `diagnose` (`message_queues`), `process_info`, `trace_calls` |
| `payments` | `payments_erl` | An OTP application whose `payments_gateway` parses a malformed URL a second after each start and crashes, just under `payments_sup`'s restart limit | `diagnose` (`supervisor_restarts`, with the exit reason and line), `supervision_tree` |
| `sessions` | `sessions_erl` | `sessions` makes an atom from every session id and never deletes its ETS rows: the atom table fills up in under an hour | `snapshot` take and diff, `ets_tables`, `trace_calls` |
| `cluster` | `erl_a`, `erl_b`, `erl_c` | Three connected nodes, only `erl_b` running the shop bug | `cluster` |

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
