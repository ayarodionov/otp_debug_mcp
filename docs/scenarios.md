# Usage scenarios

Ways to use otp_debug_mcp with Claude Code (or any MCP client). Each
scenario gives the situation, a prompt to start with, the tools the agent
typically reaches for, and what to watch out for.

The prompts are only starting points. The agent picks tools itself; with the
`otp-debug` skill installed it follows the same playbook: connect, run
`diagnose`, drill into what it flags, then confirm trends with `snapshot`.

Contents:

- **Production problems**
  1. [Memory keeps growing](#1-memory-keeps-growing)
  2. [Requests are getting slow](#2-requests-are-getting-slow)
  3. [High CPU](#3-high-cpu)
  4. [A process is stuck, or calls time out](#4-a-process-is-stuck-or-calls-time-out)
  5. [Approaching a system limit](#5-approaching-a-system-limit)
  6. [Crash loops and intermittent failures](#6-crash-loops-and-intermittent-failures)
  7. [Incident triage](#7-incident-triage)
- **Understanding and verifying**
  8. [Finding the bug in the code, not just the node](#8-finding-the-bug-in-the-code-not-just-the-node)
  9. [Seeing what a function really receives](#9-seeing-what-a-function-really-receives)
  10. [Verifying a fix or a deploy](#10-verifying-a-fix-or-a-deploy)
  11. [Watching a load test](#11-watching-a-load-test)
  12. [Getting to know an unfamiliar system](#12-getting-to-know-an-unfamiliar-system)
- **Other kinds of targets**
  13. [Erlang products you didn't write](#13-erlang-products-you-didnt-write)
  14. [Your own node during development](#14-your-own-node-during-development)
- [Before pointing it at production](#before-pointing-it-at-production)
- [Not supported yet](#not-supported-yet)

---

## Production problems

### 1. Memory keeps growing

**Situation.** The node's memory climbs over hours or days, and eventually
it's OOM-killed or restarted.

> Connect to `myapp@prod-3` (cookie in `$RELEASE_COOKIE`). Memory grows
> about 200 MB an hour. Find out where it's going.

**What the agent does.** `diagnose`, then follows the memory breakdown to the
category that's large:

| Large category | Likely cause | Tools that confirm it |
|---|---|---|
| `processes`, with one huge mailbox | a process that can't keep up | `message_queues`, `process_info` |
| `processes`, with process count rising | spawned processes that never exit | `process_count`, `supervision_tree` child counts |
| `binary` | refc binaries held by long-lived processes | `binary_leak` |
| `ets` | a table without eviction | `ets_tables` |
| `atom` | atoms created from input | `atom_table` |

It then takes a `snapshot`, waits under real load, and diffs it. A single
large number is a guess; a number that keeps growing across diffs is the
evidence.

**Watch out.** `binary_leak` forces a garbage collection in every process.
That's cheap, but say so if the node is under pressure.

### 2. Requests are getting slow

**Situation.** Latency creeps up, or `GenServer.call` timeouts start to
appear in the logs.

> `shop@api-1` has gotten slower over the last hour. Find the bottleneck.

**What the agent does.** `diagnose` usually flags a growing mailbox on one
process. `process_info` on it shows what it's busy doing (`current_function`
and stack trace). `trace_calls` on its callbacks shows the per-message
work. Tracing the *sender* side, e.g. `GenServer.cast` or `GenServer.call`,
shows who floods it and how fast. In testing, this is how the agent found
that a cache was handling 1 message for every 170 it received.

**Typical findings.** One process serializing work for everyone (a registry,
a single DB connection, the owner of an ETS table doing all writes), or
fire-and-forget casts with no backpressure.

### 3. High CPU

**Situation.** Monitoring shows the node near 100% CPU.

> CPU on `worker@batch-2` is pegged. Is it really busy, and doing what?

**What the agent does.** `run_check(schedulers)` first. OS CPU% overstates a
BEAM node because schedulers busy-wait; scheduler utilization is the real
number. If schedulers are saturated, `top_reductions` names the processes
burning CPU, and `trace_calls` on their hot module shows the calls.

**Typical findings.** Real saturation (all schedulers near 1.0) versus one
pegged scheduler with the rest idle, which points to a long-running NIF.

### 4. A process is stuck, or calls time out

**Situation.** A feature hangs, or calls to one GenServer time out.

> Calls to `Billing.Ledger` time out after 5 seconds. Why?

**What the agent does.** `process_info` on the process by name.
`current_function` and the stack trace show where it's blocked: waiting on
another process's call, a receive, a port or a lock. `include_state: true`
fetches its state, and a `sys:get_state` timeout is itself a finding:
the process is too busy or blocked to answer. `supervision_tree` shows
what it depends on and what restarts with it.

**Typical findings.** Two processes calling each other (deadlock),
a call to a slow external service made inside a GenServer, or a process
blocked behind its own backlog.

### 5. Approaching a system limit

**Situation.** You want to know whether a node is on its way to dying with
`system_limit`.

> Check `chat@edge-5` for anything heading toward a system limit.

**What the agent does.** `diagnose` covers processes, ports and atoms
against their limits. Repeated `snapshot` diffs show the direction of each.
For a growing process count, `supervision_tree` finds the supervisor whose
child count keeps climbing (it reports `child_count` even when there are too
many children to list).

**Typical findings.** Sockets or files opened and never closed (port count),
atoms created from user input, or dynamic children that never terminate.

### 6. Crash loops and intermittent failures

**Situation.** Something fails now and then, with no clear pattern, or
the logs fill with crash reports for the same process.

> `payments@prod-2` fails payments now and then. Find out why.

**What the agent does.** `diagnose` includes `supervisor_restarts`, which
reads each supervisor's own restart history. It names the supervisor and
the child that keeps restarting, and when a child dies during its short
sample, its exit reason with the stack trace, file and line. `trace_calls`
on the crashing function then shows the arguments it fails on. In testing,
this took the agent from "fails now and then" to a malformed URL and the
line that parses it, from `diagnose` alone.

**Typical findings.** Bad config or input that a child trips over a moment
after every start. The worst case is a loop that stays below the
supervisor's restart limit: nothing ever fails over, so it runs forever and
shows up only as intermittent errors. A supervisor `at_limit` is one crash
away from giving up and taking its siblings down with it.

### 7. Incident triage

**Situation.** Something is wrong right now, and you need a first picture
fast.

> `api@prod-1` is misbehaving. Give me a quick health summary before we
> decide whether to restart it.

**What the agent does.** `connect` and `diagnose`, nothing else. The findings
come back ranked worst first, so one call usually answers "is it memory,
CPU, a stuck process, or a limit?" That's enough to decide between digging
in and restarting.

**Watch out.** Before restarting, take one `snapshot` and keep the
`diagnose` output. Most of the evidence lives in the running node and is
gone after a restart.

---

## Understanding and verifying

### 8. Finding the bug in the code, not just the node

**Situation.** You want the fix, not just the diagnosis.

This is where running the tool from Claude Code, inside the project's
repository, pays off. The agent sees both the live node and the source.

> `myapp@staging` leaks memory. Find the cause on the node, then find the
> responsible code in this repo and propose a fix.

**What the agent does.** The runtime diagnosis as in scenarios 1 and 2. Stack
traces from `process_info` and `trace_calls` name modules, functions and
often line numbers, and the agent opens those files and reads the code. In
testing, it went from a mailbox backlog to the `Process.sleep` in the
offending `handle_cast/2` on its own.

### 9. Seeing what a function really receives

**Situation.** Production behaves differently from your tests, and you
suspect the inputs.

> On `pricing@prod-2`, trace a few calls to `Pricing.quote/2` and show me
> the arguments and return values.

**What the agent does.** `trace_calls` with a function name and a small
`max_events`. Each event shows the arguments and, on return, the result.
Long terms are truncated so the result fits the agent's context.

**Watch out.**
- Traced arguments are real production data and go to the AI provider
  along with everything else the tools return. Don't trace functions that
  handle secrets or personal data.
- On OTP 27+ the trace runs in its own trace session and never affects
  anyone else's. On older nodes, if someone else is tracing, `trace_calls`
  refuses and says what it found. Forcing it ends their trace, so the agent
  should ask you first.

### 10. Verifying a fix or a deploy

**Situation.** You've shipped a fix and want evidence that it worked.

> We deployed the cache fix to `shop@prod-4` an hour ago. Is the mailbox
> backlog gone, and is memory flat now?

**What the agent does.** `diagnose`, then `snapshot` and two `diff`s a minute
or so apart. A fixed leak shows near-zero deltas under the same load that
used to produce growth. The same before-and-after comparison works for
config changes, such as a new pool size.

### 11. Watching a load test

**Situation.** You're load testing and want to know what breaks first and
why.

> I'm starting a load test against `api@perf-1`. Snapshot now, then every
> few minutes, and tell me which process becomes the bottleneck first.

**What the agent does.** Repeated `snapshot`/`diff`, `message_queues` and
`schedulers` checks while the load ramps up. The first mailbox to grow, or
the point where schedulers saturate, is your capacity limit, and
`process_info` says which code it's in.

### 12. Getting to know an unfamiliar system

**Situation.** You've inherited a system, or are onboarding, and want to see
how it's actually put together at runtime.

> Connect to `legacy@ops-1` and explain how it's structured: which
> applications, what each supervisor runs, and what looks unusual.

**What the agent does.** `supervision_tree` for each application, plus a
`diagnose` baseline. Combined with the source (scenario 8), it can map
runtime processes to modules and explain restart strategies. That's often
quicker than reading the code alone, because the runtime shows what's
actually started, including dynamic children.

---

## Other kinds of targets

### 13. Erlang products you didn't write

**Situation.** A third-party system built on the BEAM misbehaves: a message
broker, a database, an XMPP server, anything written in Erlang, Elixir, Gleam
or LFE.

> Connect to `rabbit@mq-1` with the cookie from
> `/var/lib/rabbitmq/.erlang.cookie`. Which processes use the most memory,
> and are any mailboxes backing up?

**What the agent does.** The same checks as for your own code. Nothing has to
be installed on the target, because the tool attaches over Erlang
distribution as a hidden node. If the product ships its own recon, that copy
is used as-is.

**Watch out.** You won't have the source in the session, so findings stop at
"this process, in this function." Products often have their own diagnostics
too, such as RabbitMQ's `rabbitmq-diagnostics`; use both. Locate the cookie
with care: it grants full control of the node.

### 14. Your own node during development

**Situation.** You're developing locally and want runtime answers while you
code.

```sh
iex --sname dev -S mix          # or: iex --sname dev -S mix phx.server
```

> Connect to `dev@<your-host>`. Did my new `Notifications.Supervisor`
> start all its workers? Then trace `Notifications.Worker.handle_info/2`
> while I click through the UI.

**What the agent does.** `supervision_tree` to check the layout,
`trace_calls` to watch messages arrive while you exercise the feature. With
`OTP_DEBUG_MCP_ALLOW_EVAL=true` set for the server, `remote_eval` can poke
the running system, such as calling a function or reading ETS. Only enable
that on a dev machine.

---

## Before pointing it at production

- **The cookie is full access.** Anyone with the cookie can run any code on
  the node. Giving it to the tool gives that power to the agent driving it.
- **Keep `remote_eval` off** (the default) for production nodes.
- **Tool output goes to the AI provider.** That includes process state,
  traced arguments and ETS contents. Mind secrets and personal data.
- **Tracing on pre-27 nodes is one at a time.** There `trace_calls` won't
  start while another `recon_trace` session or similar tracing is active,
  because it would end it. Only force it if you know whose trace that is.
  OTP 27+ nodes have isolated trace sessions, and this doesn't apply.
- **Network.** Erlang distribution needs epmd (port 4369) and the
  distribution port range reachable from wherever the tool runs. Connecting
  to another machine hasn't been tested yet.

## Not supported yet

These would be natural scenarios, but the tool can't do them well yet (see
the README's TODO list):

- **Memory the OS sees but the VM doesn't account for** (allocator
  fragmentation). There's no `recon_alloc` check yet.
- **Multi-node clusters.** The tool talks to one node at a time. You can
  `connect` to each in turn, but it doesn't compare or correlate nodes.
