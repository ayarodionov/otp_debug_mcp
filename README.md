# otp_debug_mcp

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

Register with Claude Code (from any project, or use `--scope user` for global):

```sh
claude mcp add otp-debug -- \
  env MIX_ENV=prod mix run --no-halt -e ":ok" # placeholder, see below
```

For real use, build an escript or release so startup is fast and stdout stays
clean (MCP stdio requires that *nothing* but protocol messages goes to
stdout — configure Logger to stderr). A `.mcp.json` entry looks like:

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/path/to/otp_debug_mcp/bin/otp_debug_mcp",
      "env": { "OTP_DEBUG_MCP_ALLOW_EVAL": "false" }
    }
  }
}
```

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

## Status / TODO

This is a skeleton. Open items:

- [ ] Verify Hermes component API details against hermes_mcp 0.14 docs and compile
- [ ] Tracer: return early once `max_events` collected (currently waits out the window)
- [ ] Checks: supervisor restart-intensity check (scan logger/SASL reports)
- [ ] Checks: `recon_alloc` fragmentation check (memory held by allocators vs used)
- [ ] Release/escript packaging + Logger-to-stderr config
- [ ] Tests against a disposable target node (`peer` module)
- [ ] TLS distribution + `inet_dist_use_interface` guidance for prod targets
