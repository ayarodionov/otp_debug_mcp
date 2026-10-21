# otp_debug_mcp

[![CI](https://github.com/ayarodionov/otp_debug_mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/ayarodionov/otp_debug_mcp/actions/workflows/ci.yml)

> **Status: 0.2.1. [Releases](https://github.com/ayarodionov/otp_debug_mcp/releases).**
> Tested from Claude Code against live nodes on Erlang/OTP 26 to 29, on the
> same machine, over TLS distribution and across machines, with a test suite
> and CI on every push. Still young: the TODO list below has the known gaps.

An MCP server that lets AI agents (Claude Code, Claude Desktop, Cursor,
GitHub Copilot, …; see [docs/clients.md](docs/clients.md))
connect to a **running** Erlang/Elixir/OTP node and debug it: not just raw
introspection primitives, but an encoded diagnostic playbook in the spirit of
[recon](https://ferd.github.io/recon/) and *Erlang in Anger*.

## Design

- **Hidden-node attach.** The server joins the target over Erlang distribution
  as a hidden node that accepts no connections itself (no listening port,
  nothing registered with epmd, and a random cookie of its own), so it
  requires **zero changes to the target application**:
  no dependency, no plug, no redeploy. It works on anything running on the
  BEAM (Erlang, Elixir, Gleam, LFE), unlike in-app servers such as Tidewave
  or extools.
- **Diagnosis-first tool design.** The agent's first call is `diagnose`, which
  runs a whole battery of checks and returns ranked findings with
  interpretations — instead of making the AI reconstruct BEAM operational
  knowledge from twenty `process_info` round-trips.
- **recon injected at connect time, only where missing.** recon's object
  code is loaded into the target over rpc, so recon-quality introspection
  works even on nodes that never shipped it. A target on an older OTP
  release than the tool can't load its compiled code, so there recon is
  compiled on the target from its abstract code (this needs the target's
  `compiler` application, which Elixir releases always include). If the
  target has its own recon, that copy is used as-is and never loaded over:
  replacing a loaded module and later purging it would kill processes
  running it, such as an operator's `recon_trace` session. `connect` reports
  which recon is in use.
- **Safe by default.** Every trace has hard caps on event count and
  duration and stops early if calls arrive too fast; every rpc has a
  timeout; arbitrary `remote_eval` is disabled unless
  `OTP_DEBUG_MCP_ALLOW_EVAL=true`.
- **Tracing never disturbs someone else's.** On OTP 27+ targets,
  `trace_calls` runs in its own isolated trace session
  (`trace:session_create/3`), so other tracing on the node (an operator's
  `recon_trace`, `dbg`, anything using `erlang:trace/3`) keeps running,
  even on the same function. On older targets it falls back to
  `recon_trace`, which turns off all tracing on the node when it starts and
  stops. There it first checks for other tracing and refuses, describing
  what it found, unless called with `force: true`. The bundled skill tells
  the agent to ask the user before forcing.

## Tools

| Tool | Purpose |
|---|---|
| `connect` | Attach to a node (name + optional cookie) as a hidden node |
| `diagnose` | Full health battery, findings ranked worst-first |
| `run_check` | One check: `message_queues`, `supervisor_restarts`, `binary_leak`, `memory_breakdown`, `allocator_fragmentation`, `process_count`, `atom_table`, `ets_tables`, `ports`, `schedulers`, `top_reductions` |
| `process_info` | Deep-inspect one process: recon:info, an age estimate, its supervisor's restart history, optional `sys:get_state` |
| `supervision_tree` | Render an application's supervision tree, with each supervisor's strategy and restart history |
| `trace_calls` | Rate-limited call tracing (isolated trace session on OTP 27+, recon_trace before) |
| `cluster` | Every node of the target's cluster at once: compare them (outliers, partitions), diagnose them all, or snapshot them all to see which grows |
| `snapshot` | Take / diff system snapshots — trends beat point-in-time numbers; diffs exclude the atoms and code this tool itself adds |
| `remote_eval` | Arbitrary Erlang eval on the target (opt-in, off by default) |

The diagnostic checks live in `lib/otp_debug_mcp/checks.ex`; each returns
structured findings plus an interpretation telling the agent what the numbers
mean and what to look at next. `supervisor_restarts` finds crash loops: it
reads every supervisor's own restart history (including `DynamicSupervisor`),
flags supervisors one crash away from giving up, and names the children
restarting right now, with the exit reason and stack trace of one seen to
die.

## Setup

### Download a release

[Releases](https://github.com/ayarodionov/otp_debug_mcp/releases) bundle
their own Erlang runtime, so nothing else needs installing. They're built
for:

- macOS on Apple silicon (`macos-arm64`)
- Linux on x86_64 and arm64 (`linux-x86_64`, `linux-arm64`), with glibc
  from Ubuntu 22.04 or later and OpenSSL 3 (`libcrypto.so.3`)

```sh
vsn=0.2.1 target=macos-arm64   # or linux-x86_64, linux-arm64
base=https://github.com/ayarodionov/otp_debug_mcp/releases/download/v$vsn
curl -LO "$base/otp_debug_mcp-$vsn-$target.tar.gz"
curl -LO "$base/otp_debug_mcp-$vsn-$target.tar.gz.sha256"
shasum -a 256 -c "otp_debug_mcp-$vsn-$target.tar.gz.sha256"
mkdir -p ~/.local && tar -xzf "otp_debug_mcp-$vsn-$target.tar.gz" -C ~/.local
```

The server is then `~/.local/otp_debug_mcp/bin/otp_debug_mcp`. The
binaries aren't signed: on macOS, an archive downloaded with a browser
rather than `curl` is quarantined, and the server won't start until you
run `xattr -dr com.apple.quarantine ~/.local/otp_debug_mcp`.

### Build from source

Needs Elixir 1.19 and Erlang/OTP 27 or later:

```sh
mix deps.get
MIX_ENV=prod mix release
```

The server is then `_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp`.

### Register it with Claude Code

`--scope user` makes it available in every project:

```sh
claude mcp add otp-debug --scope user -- ~/.local/otp_debug_mcp/bin/otp_debug_mcp start
```

Or as a `.mcp.json` entry:

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/home/you/.local/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": { "OTP_DEBUG_MCP_ALLOW_EVAL": "false" }
    }
  }
}
```

For Cursor, GitHub Copilot or Claude Desktop, see
[docs/clients.md](docs/clients.md).

Install the skill too (it's in the release archive as well), so Claude
follows the debugging playbook:

```sh
mkdir -p ~/.claude/skills && cp -R ~/.local/otp_debug_mcp/skills/otp-debug ~/.claude/skills/
```

Notes:

- **Name mode is automatic.** `connect` starts distribution on demand in the
  mode the target uses: shortnames for `app@host` (the Mix release default),
  longnames for `app@1.2.3.4` or `app@host.domain`. Connecting to a target
  in the other mode switches modes, dropping the previous connection.
- **Reconnects.** If the target restarts, the next tool call reconnects and
  re-injects recon. If it's down, tools report `connection_lost`.
- **Cookie.** Without a `cookie` argument, the server uses the
  `OTP_DEBUG_MCP_COOKIE` environment variable if it's set, which keeps a
  production cookie out of the conversation, and otherwise
  `~/.erlang.cookie`, which matches `iex --sname`/`erl -sname`. Mix releases
  generate their own cookie (`RELEASE_COOKIE`, or `releases/COOKIE`).
- **Production nodes.** [docs/production.md](docs/production.md) covers
  firewalls and fixed distribution ports, targets that listen only on
  loopback (with an SSH tunnel recipe), and TLS distribution.
- **Pids look the same everywhere.** Every tool prints the target's pids
  and ports the way the target itself does (`<0.107.0>`), matching trace
  output and `remote_eval`, and `process_info` accepts them as given.
- **Erlang or Elixir syntax.** Terms from a plain Erlang node are shown in
  Erlang syntax, from an Elixir node in Elixir syntax.
- **stdout is the protocol stream.** All logging goes to stderr, and IO from
  the target during rpc calls and traces is redirected away from stdout.

Then, in Claude Code:

> Connect to myapp@127.0.0.1 and find out why memory keeps growing.

## Typical agent workflow

1. `connect(node: "myapp@127.0.0.1")`; if the node is in a cluster, it says
   so, and `cluster()` compares every node to find the one that differs
2. `diagnose()` → ranked findings
3. Drill in: `process_info` on offenders, `supervision_tree` for context,
   `trace_calls` to see live traffic
4. `snapshot(take)` → wait → `snapshot(diff)` to confirm leaks/trends

The Claude Code skill installed in [Setup](#register-it-with-claude-code),
`skills/otp-debug/SKILL.md`, encodes this workflow, so Claude follows it
automatically.

## Usage scenarios

[docs/scenarios.md](docs/scenarios.md) walks through each of these with an
example prompt, the tools involved, and what to watch out for:

- **Production problems:** memory growth, slow requests, high CPU, stuck
  processes and call timeouts, approaching system limits, crash loops and
  intermittent failures, one bad node in a cluster, incident triage
- **Understanding and verifying:** tracing a runtime problem to the code in
  your repo, seeing what a function really receives, verifying a fix or a
  deploy, watching a load test, learning an unfamiliar system
- **Other targets:** Erlang products you didn't write (message brokers,
  databases), and your own node during development

It ends with a checklist for production use and the scenarios the tool
doesn't support yet.

## Testing

```sh
mix test
```

The tests start real target nodes with OTP's `peer` module and connect to
them over distribution as hidden nodes, exactly as against a live system:
connection and name modes, reconnects, recon injection, every check,
snapshots, both tracing backends, and the tools' JSON output. Fixture code
for the targets is in `test/support/fixtures.ex`. Tests tagged `old_otp`
need a node running an older OTP release, which the Docker recipe below
provides; see `test/otp_debug_mcp/old_otp_test.exs`.

The whole suite also runs over TLS distribution, peers included, which
adds a test that the target sees the connection as TLS:

```sh
CONF=$(scripts/tls_dist_certs.sh /tmp/tls)
ERL_FLAGS="-proto_dist inet_tls -ssl_dist_optfile $CONF" mix test
```

CI (`.github/workflows/ci.yml`) runs the tests on OTP 27 and 28, again
over TLS distribution, the `old_otp` tests against an OTP 26 container,
and the smoke test below against the built release.

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
reconnect after a target restart; targets with their own recon (including
an old one missing functions) keep their running recon sessions across
repeat connects and checks; on OTP 28, `trace_calls` traces the same
function as an operator's `recon_trace` session without disturbing it; on
an OTP 26 target, recon is compiled on the target and every check works,
and `trace_calls` refuses while `dbg` is tracing unless forced; the whole
test suite over TLS distribution; a target on another Mac over the local
network (OTP 29, newer than the tool's OTP 28), reached by IP with a fixed
distribution port, where the smoke test and every tool passed and the
target saw the tool only as a hidden node; and, between the same two Macs,
both recipes in [docs/production.md](docs/production.md): an SSH tunnel to
a target listening only on loopback, and TLS distribution, which refused
plain-TCP connections and certificates from another CA.

[examples/erlang](examples/erlang) has the same kinds of demo in plain
Erlang/OTP, with no Elixir: a mailbox that never drains, an OTP
application in a crash loop, a session store leaking atoms and ETS rows,
and a cluster with one bad node. [examples/gleam](examples/gleam) has
Gleam ones, with `gleam_otp` actors and supervisors: a mailbox that never
drains, a supervised actor whose `let assert` panics in a loop, and a job
runner leaking processes. Each directory's `run.sh` builds and starts
them, and CI smoke-tests the release against the Erlang and Gleam shops
too.

`scripts/cluster_demo.sh start` runs a three-node cluster on this host in
which only `shop_b` has the cache bug. Pointed at the healthy `shop_a`, a
headless Claude Code session ran `cluster` first and went straight to
`shop_b` and the cause.

`scripts/crash_loop_target.exs` runs a payment gateway in a crash loop
just under its supervisor's restart limit, failing intermittently. Asked
*"payments@yourhost fails payments now and then; find out why"*, a headless
Claude Code session got the cause and the file and line from `diagnose`
alone.

`scripts/recon_target.exs` is the scenario of a target with its own recon: a node with an operator's
recon_trace session open, logging once a second whether it's still alive:

```sh
STATUS_FILE=/tmp/status.log elixir --sname rt -pa _build/prod/lib/recon/ebin \
  --no-halt scripts/recon_target.exs &
python3 scripts/mcp_call.py _build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp "[
  [\"connect\", {\"node\": \"rt@$(hostname -s)\"}], [\"diagnose\", {}],
  [\"connect\", {\"node\": \"rt@$(hostname -s)\"}]
]"
tail -1 /tmp/status.log   # operator_trace=alive
```

An older OTP release runs best in Docker. Distribution through a published
port works without epmd: the target listens on a fixed port, and the tool
connects to that port without listening itself:

```sh
docker run -d --rm --name otp26 -p 9100:9100 erlang:26-slim \
  erl -noinput -name old@127.0.0.1 -setcookie testcookie -erl_epmd_port 9100 \
  -eval 'spawn(fun() -> timer:apply_interval(100, queue, new, []), receive after infinity -> ok end end).'
ERL_FLAGS="-erl_epmd_port 9100" python3 scripts/mcp_call.py \
  _build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp '[
  ["connect", {"node": "old@127.0.0.1", "cookie": "testcookie"}],
  ["diagnose", {}],
  ["trace_calls", {"module": "queue", "function": "new", "max_events": 4}]
]'
```

## Releasing

1. Set the new version in `mix.exs`, and add a `## <version>` section for
   it at the top of `CHANGELOG.md`.
2. Commit, then tag and push: `git tag v<version> && git push origin v<version>`.

The [Release workflow](.github/workflows/release.yml) builds and
smoke-tests each platform's archive, checks the tag matches `mix.exs`, and
publishes the GitHub release with the changelog section as its notes. Run
it by hand (`gh workflow run Release`) to build and test without
publishing.

## Status / TODO

Open items:

- [ ] Targets on an older OTP release than the tool, without the `compiler`
      application (common in slim rebar3 releases), get no recon: ship recon
      precompiled for older releases
- [ ] trace_calls on OTP 26 and earlier still goes through recon_trace, which
      ends other tracing (with permission): a small tracer of our own
