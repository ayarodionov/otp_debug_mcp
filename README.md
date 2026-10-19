# otp_debug_mcp

> **Status: early.** Tested end to end from Claude Code against live nodes,
> but young: expect rough edges. See the TODO list below.

An MCP server that lets AI agents (Claude Code, Claude Desktop, Cursor, …)
connect to a **running** Erlang/Elixir/OTP node and debug it: not just raw
introspection primitives, but an encoded diagnostic playbook in the spirit of
[recon](https://ferd.github.io/recon/) and *Erlang in Anger*.

## Design

- **Hidden-node attach.** The server joins the target over Erlang distribution
  as a hidden node, so it requires **zero changes to the target application**:
  no dependency, no plug, no redeploy. It works on anything running on the
  BEAM (Erlang, Elixir, Gleam, LFE), unlike in-app servers such as Tidewave
  or extools.
- **Diagnosis-first tool design.** The agent's first call is `diagnose`, which
  runs a whole battery of checks and returns ranked findings with
  interpretations — instead of making the AI reconstruct BEAM operational
  knowledge from twenty `process_info` round-trips.
- **recon injected at connect time.** recon's object code is loaded into the
  target over rpc, so recon-quality introspection works even on nodes that
  never shipped it.
- **Safe by default.** Tracing goes through `recon_trace` (hard caps on event
  count and duration); every rpc has a timeout; arbitrary `remote_eval` is
  disabled unless `OTP_DEBUG_MCP_ALLOW_EVAL=true`.

## Tools

| Tool | Purpose |
|---|---|
| `connect` | Attach to a node (name + optional cookie) as a hidden node |
| `diagnose` | Full health battery, findings ranked worst-first |
| `run_check` | One check: `message_queues`, `binary_leak`, `memory_breakdown`, `process_count`, `atom_table`, `ets_tables`, `ports`, `schedulers`, `top_reductions` |
| `process_info` | Deep-inspect one process (recon:info + optional `sys:get_state`) |
| `supervision_tree` | Render an application's supervision tree |
| `trace_calls` | Rate-limited call tracing via recon_trace |
| `snapshot` | Take / diff system snapshots — trends beat point-in-time numbers |
| `remote_eval` | Arbitrary Erlang eval on the target (opt-in, off by default) |

The diagnostic checks live in `lib/otp_debug_mcp/checks.ex`; each returns
structured findings plus an interpretation telling the agent what the numbers
mean and what to look at next.

## Setup

```sh
mix deps.get
mix compile
```

Build the release (Elixir 1.15+, tested on Elixir 1.19 / OTP 28):

```sh
MIX_ENV=prod mix release
```

Register it with Claude Code (`--scope user` makes it available in every
project):

```sh
claude mcp add otp-debug --scope user -- \
  /path/to/otp_debug_mcp/_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp start
```

Or as a `.mcp.json` entry:

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/path/to/otp_debug_mcp/_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": { "OTP_DEBUG_MCP_ALLOW_EVAL": "false" }
    }
  }
}
```

Notes:

- **Name mode is automatic.** `connect` starts distribution on demand in the
  mode the target uses: shortnames for `app@host` (the Mix release default),
  longnames for `app@1.2.3.4` or `app@host.domain`. Connecting to a target
  in the other mode switches modes, dropping the previous connection.
- **Reconnects.** If the target restarts, the next tool call reconnects and
  re-injects recon. If it's down, tools report `connection_lost`.
- **Cookie.** Without a `cookie` argument, `~/.erlang.cookie` is used, which
  matches `iex --sname`/`erl -sname`. Mix releases generate their own cookie;
  pass the target's `RELEASE_COOKIE` (or `releases/COOKIE`).
- **stdout is the protocol stream.** All logging goes to stderr, and IO from
  the target during rpc calls and traces is redirected away from stdout.

Then, in Claude Code:

> Connect to myapp@127.0.0.1 and find out why memory keeps growing.

## Typical agent workflow

1. `connect(node: "myapp@127.0.0.1")`
2. `diagnose()` → ranked findings
3. Drill in: `process_info` on offenders, `supervision_tree` for context,
   `trace_calls` to see live traffic
4. `snapshot(take)` → wait → `snapshot(diff)` to confirm leaks/trends

A Claude Code skill encoding this workflow ships in
`skills/otp-debug/SKILL.md` — copy it to `~/.claude/skills/otp-debug/` so
Claude follows the playbook automatically.

## Testing

`scripts/` holds an end-to-end check that drives the release over MCP stdio
the way a client does, against a demo node with a real bug:

```sh
elixir --sname shop --no-halt scripts/buggy_target.exs &
python3 scripts/mcp_smoke.py \
  _build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp "shop@$(hostname -s)" Shop.PriceCache
```

It fails on any non-JSON line on stdout. The same demo node makes a good
first prompt for Claude Code: *"shop@yourhost is getting slower and using
more memory; find out why."*

`scripts/mcp_call.py` runs an arbitrary sequence of tool calls, with shell
steps in between (e.g. to restart the target). `scripts/demo_shop` is a
small app with a nested supervision tree, built as a Mix release so it has
its own cookie:

```sh
(cd scripts/demo_shop && MIX_ENV=prod mix release)
REL=scripts/demo_shop/_build/prod/rel/demo_shop
$REL/bin/demo_shop daemon
python3 scripts/mcp_call.py _build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp "[
  [\"connect\", {\"node\": \"demo_shop@$(hostname -s)\", \"cookie\": \"$(cat $REL/releases/COOKIE)\"}],
  [\"supervision_tree\", {\"app\": \"demo_shop\"}],
  [\"shell\", \"$REL/bin/demo_shop stop; sleep 2; $REL/bin/demo_shop daemon; sleep 4\"],
  [\"run_check\", {\"check\": \"top_reductions\"}]
]"
```

Verified so far: every tool through MCP stdio; shortnames, longnames (IP and
FQDN) and switching between them in one session; Mix release cookies;
reconnect after a target restart. Not yet verified: a target on another
machine.

## Status / TODO

Open items:

- [ ] Checks: supervisor restart-intensity check (scan logger/SASL reports)
- [ ] Checks: `recon_alloc` fragmentation check (memory held by allocators vs used)
- [ ] Snapshot: discount the debugger's own footprint (atoms/code loaded by
      recon injection and tracing show up in diffs)
- [ ] Print pids in the target's own `<0.x.y>` form in tool output
- [ ] Exit with status 0 (not 1) when the client closes stdin
- [ ] ExUnit tests against a disposable target node (`peer` module)
- [ ] Verify against a target on another machine (firewalls, epmd port 4369,
      the distribution port range)
- [ ] TLS distribution + `inet_dist_use_interface` guidance for prod targets
