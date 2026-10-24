# Usage scenarios

Ways to use otp_debug_mcp with Claude Code (or any MCP client). Each
scenario gives the situation, a prompt to start with, the tools the agent
typically reaches for, and what to watch out for.

The prompts are only starting points. The agent picks tools itself; with the
`otp-debug` skill installed it follows the same playbook: connect, run
`diagnose`, drill into what it flags, then confirm trends with `snapshot`.

Contents:

- **Production problems**
  - [1. Memory keeps growing](#1-memory-keeps-growing)
  - [2. Requests are getting slow](#2-requests-are-getting-slow)
  - [3. High CPU](#3-high-cpu)
  - [4. A process is stuck, or calls time out](#4-a-process-is-stuck-or-calls-time-out)
  - [5. Approaching a system limit](#5-approaching-a-system-limit)
  - [6. Crash loops and intermittent failures](#6-crash-loops-and-intermittent-failures)
  - [7. Errors only the logs show](#7-errors-only-the-logs-show)
  - [8. A node that died](#8-a-node-that-died)
  - [9. One node in a cluster misbehaves](#9-one-node-in-a-cluster-misbehaves)
  - [10. Incident triage](#10-incident-triage)
  - [11. Native code: a NIF that blocks or leaks](#11-native-code-a-nif-that-blocks-or-leaks)
  - [12. Sockets, ports and external programs](#12-sockets-ports-and-external-programs)
- **Understanding and verifying**
  - [13. Finding the bug in the code, not just the node](#13-finding-the-bug-in-the-code-not-just-the-node)
  - [14. Seeing what a function really receives](#14-seeing-what-a-function-really-receives)
  - [15. Verifying a fix or a deploy](#15-verifying-a-fix-or-a-deploy)
  - [16. Trying a fix on the live node](#16-trying-a-fix-on-the-live-node)
  - [17. Code that macros generated](#17-code-that-macros-generated)
  - [18. Watching a load test](#18-watching-a-load-test)
  - [19. Getting to know an unfamiliar system](#19-getting-to-know-an-unfamiliar-system)
- **Other kinds of targets**
  - [20. Erlang products you didn't write](#20-erlang-products-you-didnt-write)
  - [21. Your own node during development](#21-your-own-node-during-development)
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
| nothing: the OS sees far more than `erlang:memory()` reports | allocator fragmentation: carriers kept alive by a few live blocks | `allocator_fragmentation` |

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
that a cache was handling 1 message for every 170 it received. If the
process is busy rather than waiting, `profile` on its module shows which
of its functions use the time.

On an Elixir node, `telemetry` is often the faster start. It listens to
the events Phoenix, Ecto, Oban, Finch and the like already emit, for ten
seconds, and gives each route, query and job its count, its p50, p95 and
maximum duration, and its slowest example. Ecto queries also come with
`queue_time_ms`, the time spent waiting for a connection from the pool.
It costs far less than tracing, so it's the right first look on a busy
node. Against the Phoenix demo (`examples/elixir/run.sh phoenix`), it
showed in its first call that every request to `/api/products/search`
was dispatched to the route `/api/products/:id`, action `show`, and
answered 404.

**Typical findings.** One process serializing work for everyone (a registry,
a single DB connection, the owner of an ETS table doing all writes), or
fire-and-forget casts with no backpressure. From `telemetry`: one route or
query far slower than the rest, a p95 far above the p50 (some calls wait
on something), queries waiting on the pool (`queue_time_ms`), or one
request running many fast queries.

### 3. High CPU

**Situation.** Monitoring shows the node near 100% CPU.

> CPU on `worker@batch-2` is pegged. Is it really busy, and doing what?

**What the agent does.** `run_check(schedulers)` first. OS CPU% overstates a
BEAM node because schedulers busy-wait; scheduler utilization is the real
number. If schedulers are saturated, `top_reductions` names the processes
burning CPU, and `profile` on their hot module ranks its functions by the
time they use, with call counts and memory allocated. `trace_calls` on the
top one then shows the arguments it's called with.

> Profile `Pricing` on `worker@batch-2` for 5 seconds. Which functions use
> the time?

**Typical findings.** Real saturation (all schedulers near 1.0) versus one
pegged scheduler with the rest idle, which points to a long-running NIF
(scenario 11: `long_schedules` names it).
A profile usually puts most of the time in a few functions: a loop over a
large list, repeated encoding or decoding, a regex compiled on every call.

**Watch out.**
- Counting slows down every profiled call, so profile one module for a few
  seconds on production nodes. `all_modules` counts every function on the
  node: much more expensive.
- Only time spent running counts. A function that's slow because it waits
  for a reply, a lock or a sleep shows little time in a profile; that's
  scenario 2, and `trace_calls` timestamps.

### 4. A process is stuck, or calls time out

**Situation.** A feature hangs, or calls to one GenServer time out.

> Calls to `Billing.Ledger` time out after 5 seconds. Why?

**What the agent does.** `diagnose` includes `call_chains`. It finds the
processes waiting on another process: in a `gen_server`, `GenServer` or
`gen_statem` call, in `Task.await`, or in `start_link` for a new
process's init. It samples them twice, a second apart, and from the calls
still pending it reports:
- **deadlocks:** processes waiting on each other in a cycle, each with
  its request and timeout, and how many others wait on it;
- **chains:** calls waiting on calls, ending at the process that holds
  them all up;
- **the processes most waited on.**

Against the locks demo (`examples/erlang/run.sh locks`), it named the two
gen_servers calling each other and what each had asked the other, with
timeout infinity, and the shoppers stuck behind them.

`process_info` on the process by name tells more. Its age
and its supervisor's restart history tell a long-stuck process from one
that keeps crashing and coming back. `current_function` and the stack
trace show where it's blocked: waiting on
another process's call, a receive, a port or a lock. `include_state: true`
fetches its state, and a `sys:get_state` timeout is itself a finding:
the process is too busy or blocked to answer. `supervision_tree` shows
what it depends on and what restarts with it.

**Typical findings.** Two processes calling each other (deadlock), often
one calling back into the other from a callback, a call to a slow
external service made inside a GenServer, or a process blocked behind its
own backlog.

### 5. Approaching a system limit

**Situation.** You want to know whether a node is on its way to dying with
`system_limit`.

> Check `chat@edge-5` for anything heading toward a system limit.

**What the agent does.** `diagnose` covers processes, ports (scenario 12) and atoms
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
on the crashing function then shows the arguments it fails on, and
`recent_errors` collects the crash reports of a child that crashes less
often than that sample catches (scenario 7). In testing,
this took the agent from "fails now and then" to a malformed URL and the
line that parses it, from `diagnose` alone.

**Typical findings.** Bad config or input that a child trips over a moment
after every start. The worst case is a loop that stays below the
supervisor's restart limit: nothing ever fails over, so it runs forever and
shows up only as intermittent errors. A supervisor `at_limit` is one crash
away from giving up and taking its siblings down with it.

### 7. Errors only the logs show

**Situation.** Something goes wrong but the node looks healthy by every
number: users see errors, or a job quietly doesn't happen. The evidence is
in the logs, on the node's machine, in a container, or nowhere you can
read.

> `orders@prod-1` loses some imported orders, and payments fail now and
> then. What is it logging?

**What the agent does.** `recent_errors` listens to the node's logger for
a while (10 seconds by default) and groups what it catches:
- **Crashes:** a group per process and reason, with the reports the crash
  caused and how many different processes it was (one restarted again and
  again is a crash loop). Each group has the stack, and for a
  `function_clause` the arguments.
- **Log messages:** a group per message, with the place it was logged
  from (`logged_at`, from the logger's metadata).

It also reads the start and the end of the node's log files, grouped the
same way. That's where the errors from before it listened are: an error
logged once at boot gets a group of its own, instead of being lost among
a loop's thousands. For errors that happen rarely, `watch_minutes` keeps
listening in the background, and later calls return what it caught. From
a stack frame, `module_code` with `at:` finds the code and `trace_calls`
the arguments.

In testing against the orders demo (`examples/erlang/run.sh orders`), a
session with only these tools found all three of its problems in a
minute (walkthrough 9). `diagnose` caught the crash loop. `recent_errors`
added the failing payments, with the line that logs them, and the error
the node logged once at boot, which only its log file still had.

**Typical findings.**
- A crash loop under its supervisor's restart limit, which `diagnose`
  catches only if a crash falls within its sample.
- A warning logged on every call: a dependency is slow.
- An error at boot that the node carried on from: a missing config file,
  a fallback silently in use.

**Watch out.**
- Listening adds a logger handler to the node. It's removed when the
  window or the watch ends; a watch also expires on its own, after at
  most 4 hours.
- Elixir nodes don't log OTP's crash and supervisor reports unless
  `handle_sasl_reports` is set, so only the GenServer's own report shows.
- Nothing below the node's primary logger level is logged at all; the
  tool says when that hides warnings.
- Log lines go to the AI provider, like any tool output.

### 8. A node that died

**Situation.** A node crashed and was restarted (by systemd, Kubernetes,
heart), and you want to know why before it happens again. It left an
`erl_crash.dump`.

> `events@prod-3` died last night; its crash dump is at
> /srv/events/erl_crash.dump. Find out why.

**What the agent does.** `crash_dump` reads the dump. No connection is
needed: the file is read on the machine running the server. It says what
the slogan, the VM's last words, means: out of memory (and in which
allocator), a permanent application that stopped (and which one), a full
atom table, a failed boot, a signal. Its findings name what stands out: a
process holding most of the memory, a mailbox of a million messages, a
process leak. It also shows:
- the process that was running when the node died;
- the biggest processes and the longest mailboxes, with their stacks;
- the first messages of the longest mailbox, decoded, which say what was
  piling up and often who sent it;
- memory, ETS tables, ports and atoms.

With `process:`, it shows one process in full.

In testing on the dump of the crash demo (`examples/erlang/run.sh crash`,
128 MB), a session given only the dump's path found in 23 seconds why the
node died (walkthrough 10). It named the writer that held 74% of memory
in a million queued events and the source that was sending them, and saw
from the oldest event that the writer had kept up with about 1%.

**Typical findings.**
- A consumer that can't keep up with its producer, until the node runs
  out of memory.
- A binary or ETS leak.
- An application that stopped because a child crashed more often than its
  supervisor allows. The dump shows the node after the crashes, so the
  node's logs, or `recent_errors` on the restarted node, show why it
  crashed.
- Atoms made from input.

**Watch out.**
- Copy the dump to the machine running the server first (`docker cp`,
  `kubectl cp`).
- A dump has no logs.
- A node killed by the OS (the OOM killer, `kill -9`) writes no dump at
  all; in a container, running out of memory usually ends that way.
- Point `ERL_CRASH_DUMP` at a volume that outlives the container, or the
  dump goes with it.
- A large dump takes a few seconds per hundred MB.

### 9. One node in a cluster misbehaves

**Situation.** A cluster of nodes running the same code gets slow or
unstable, and it isn't clear which node is to blame, or the symptoms show
up on a healthy node that depends on a sick one.

> `shop@node-1` is part of a cluster that's getting slow. Find out which
> node is the problem and why.

**What the agent does.** `connect` reports that the node is in a cluster,
and `cluster` compares every node: memory, process, port and atom counts,
run queue, scheduler usage, the largest mailbox, and supervisors
restarting children. It flags the nodes that stand out from the others,
and nodes that don't see each other (a netsplit). `cluster` with
`action: "diagnose"` runs the full diagnose everywhere, and
`snapshot_take` then `snapshot_diff` show which node grows. The agent then
connects to the odd node and drills in with the single-node tools. In
testing, pointed at a healthy node of a three-node cluster, the agent ran
`cluster` first and went straight to the one node with the bug.

**Typical findings.** One node with a backed-up process or a leak the
others don't have (uneven load, a stuck singleton), a node that never
joined or lost its links, or a node whose atom count has crept up.

**Watch out.** Nodes are attached with the current target's cookie, as a
cluster shares one; a node with another cookie shows as unreachable.

### 10. Incident triage

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

### 11. Native code: a NIF that blocks or leaks

**Situation.** Latency spikes for everything on the node now and then, or
the OS shows the node's memory growing while `erlang:memory()` stays flat.
Both point at native code: a NIF that runs too long without yielding, or
one that allocates memory it never frees. Native code is invisible to most
BEAM tooling, and a NIF that blocks a scheduler stalls every process on it.

> `native_erl@yourhost` stalls for tens of milliseconds now and then, and
> the OS says it uses more memory every minute, though erlang:memory()
> doesn't change. Find out why.

**What the agent does.**
- `diagnose` runs `long_schedules`, which watches for two seconds for
  processes that held a scheduler for more than 10 ms. Erlang code yields
  long before that, so these are native calls, named by the process that
  made them.
- `module_code` on that process's modules marks which functions are NIFs.
  `trace_calls` or `profile` on them shows which call takes how long.
- For memory, `native_memory` compares the memory the OS charges the node
  with what the VM's allocators hold, and snapshot diffs show the gap
  growing, as `native_memory_delta_mb`, while `memory_delta` stays flat.
  The OS's figure includes memory compressed or swapped out (macOS's
  physical footprint, `VmRSS` plus `VmSwap` on Linux): leaked memory
  nobody touches gets compressed or swapped under memory pressure, and
  resident memory (RSS) alone can stop showing the leak at all.
- `native_code` lists the native libraries the node can load.
- `schedulers` covers the dirty schedulers that dirty NIFs run on, and
  their run queues.

In testing against the native demo (`examples/erlang/run.sh native`), a
session with only these tools took a minute (walkthrough 7).
`long_schedules` named the pricing worker holding a scheduler for over
100 ms at a time, and a trace showed the NIF it calls,
`native_nif:checksum/1`, taking that long per call, and another worker's
call held until it returned. Snapshot diffs showed native memory growing
about 2.5 MB a second while `erlang:memory()` grew 0.04 MB, and
`native_code` showed `native_nif.so` as the only native library outside
OTP.

**Watch out.**
- A NIF that crashes takes the node down with it, and nothing connected to
  the node can help afterwards. Enable core dumps on the node's host to see
  where it crashed, and run the NIF's tests on OTP's debug or
  AddressSanitizer emulators (`-emu_type debug`, `-emu_type asan`).
- On a node before OTP 28, `long_schedules` needs the node's single
  `system_monitor`, and skips the check if another process holds it.
  OTP 28's trace sessions watch for long schedules by themselves.
- A single `native_memory` reading says little: the VM's allocators count
  memory the OS hasn't backed yet. Watch it change in snapshot diffs.
- Native memory is a total for the node. It says that native code leaks,
  and `native_code` which libraries are suspects, but not which NIF:
  that takes the library's source, or its tests under AddressSanitizer
  or Valgrind.

### 12. Sockets, ports and external programs

**Situation.** The port count climbs toward the limit, sends block or time
out, a peer can't keep up, or OS processes the node started pile up.
Ports are how the node talks to the outside: sockets, external programs
(`open_port`) and port drivers.

> `ports_erl@yourhost`'s port count keeps climbing, and one of its
> connections stops sending now and then. Find out why.

**What the agent does.**
- `diagnose` runs `ports`: ports by type (`tcp_inet`, external programs by
  command), the processes holding the most, ports with data waiting to be
  written (and whether the owner is blocked sending), and the external
  programs with their OS pids. It also counts sockets of the `socket`
  module, which aren't ports.
- Snapshot diffs say which kind of port grew and which owner opened the
  new ones: a leak names its code.
- `socket_traffic` shows the sockets moving the most bytes, with peers.
- `port_info` on one port gives its socket addresses, statistics
  (`send_pend`) and options (`active`, `packet`, buffers, watermarks).
- `trace_port` traces a port's traffic, or with `opened: true` the ports
  opened and closed in a window, with who opened them.

In testing against the ports demo (`examples/erlang/run.sh ports`), a
session with only these tools found all three of its bugs in under a
minute (walkthrough 8): `ports` named the owner holding 147 sockets, the
one running 59 copies of `cat`, and a feed blocked sending with 7.5 MB
queued; `port_info` showed the feed's 8 MB high watermark; and
`trace_port` and a snapshot diff confirmed 161 ports opened in 13 seconds,
none closed.

**Typical findings.** A process that opens a connection or an external
program per request and never closes it; a socket whose peer reads slower
than it's written to, with sends blocking at the high watermark; an
owner with `{active, true}` flooding its own mailbox.

**Watch out.**
- Sockets opened with the `socket` backend (`{inet_backend, socket}`)
  aren't ports: `ports` counts them, but `port_info`, `trace_port` and
  `socket_traffic` don't cover them. Open files haven't been ports since
  OTP 21.
- `trace_port` shows the data a port carries, truncated: it's real
  traffic, and goes to the AI provider like everything else.
- Before OTP 27, `trace_port` uses the node's legacy trace session, and
  refuses while anyone else traces.

## Understanding and verifying

### 13. Finding the bug in the code, not just the node

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

Functions that macros generate aren't in the source to open; scenario 17
finds them on the node.

### 14. Seeing what a function really receives

**Situation.** Production behaves differently from your tests, and you
suspect the inputs.

> On `pricing@prod-2`, trace a few calls to `Pricing.quote/2` and show me
> the arguments and return values.

**What the agent does.** `trace_calls` with a function name and a small
`max_events`. Each event shows the arguments and, on return, the result.
Long terms are truncated so the result fits the agent's context.

When only some calls fail, `exceptions: true` reports only the calls that
raise (an error, an exit or a throw), each with its arguments and the
exception. That works even when the caller catches the error, so nothing
is logged, and on a function called thousands of times a second, where
the failing calls would be lost among the others. On the orders demo,
`trace_calls` on `orders_importer:parse_line/1` with `exceptions: true`
shows the line with `n/a` that raises `badarg`.

**Watch out.**
- Traced arguments are real production data and go to the AI provider
  along with everything else the tools return. Don't trace functions that
  handle secrets or personal data.
- On OTP 27+ the trace runs in its own trace session and never affects
  anyone else's. On older nodes, if someone else is tracing, `trace_calls`
  refuses and says what it found. Forcing it ends their trace, so the agent
  should ask you first.

### 15. Verifying a fix or a deploy

**Situation.** You've shipped a fix and want evidence that it worked.

> We deployed the cache fix to `shop@prod-4` an hour ago. Is the mailbox
> backlog gone, and is memory flat now?

**What the agent does.** `diagnose`, then `snapshot` and two `diff`s a minute
or so apart. A fixed leak shows near-zero deltas under the same load that
used to produce growth. The same before-and-after comparison works for
config changes, such as a new pool size.

### 16. Trying a fix on the live node

**Situation.** You have a fix and want to see it work on the node before
going through a deploy, or you need a stopgap now.

> I've compiled the fix for the gateway crash to
> `_build/default/lib/payments/ebin`. Load `payments_gateway` onto
> `payments@staging` and check that the crashes stop.

**What the agent does.** `load_module` with the `.beam` file. You get a
dialog showing the new code's md5 and path and the running version's, and
nothing loads until you approve. Then `supervisor_restarts` or
`trace_calls` to show the crashes have stopped. Tested on the Erlang
payments demo, the restarts went from 10 in the supervisor's window to 0.
Later, `load_module(revert: ...)` puts back the node's own version, again
only with your approval. [Walkthrough 4](walkthroughs.md#4-trying-the-fix-on-the-live-node)
is a recorded session of it on the Elixir payments demo.

**Watch out.**
- It lasts until the node restarts. The node's files aren't changed, so
  deploy the fix properly as well.
- Compile it with the node's OTP major version or an older one. A newer
  one may produce code the node rejects.
- State is kept as it is: there's no `code_change`. If the fix changes the
  shape of a gen_server's state, the running processes will have the old
  shape.
- Processes in a function of an older version (a plain `receive` loop
  calling itself without its module name) keep running it. While they do,
  the tool refuses to load that module again, rather than kill them.

### 17. Code that macros generated

**Situation.** A stack trace or a trace names a function you can't find in
your source, or points into a library's file: `gen_server.ex:887`, a
router, an Ecto schema, a DSL of your own. Macros wrote that code at
compile time: the callbacks `use GenServer` adds, the clauses a router
macro defines, functions built in a `for` loop.

> `billing_ex@yourhost` records every charge twice. Find out why.

> This crash report shows `gen_server.ex:887` in `MyApp.Cache`. Which
> function is that, and what does it do?

**What the agent does.** `module_code` reads the module's `.beam` on the
node. Without arguments it lists every function with its origin: written
in the module, or generated by a macro, with the macro's module, the line
that called it and, with `quote location: :keep`, the line in the macro.
With `function` it shows that function's code after macro expansion: what
actually runs. With `at` it finds which function a stack frame's
`file:line` is in. Generated functions then trace and profile by name like
any other.

In testing against the billing demo, where a `timed` macro runs the block
it wraps twice, the agent found the generated `handle("/charge", req)`
clause calling `Billing.Ledger.record/2` twice, traced the two calls on
every request, and proposed the fix to the macro. Walkthrough 5 has the
session. Against the Phoenix demo, whose search route is shadowed by the
`GET /products/:id` that `resources` generates, the agent read the
router's `__match_route__/3` clauses in matching order and caught a search
arriving at `show` with `id: "search"` (walkthrough 6). That bug compiles
without a warning; `mix phx.routes` also lists the routes in matching
order. Against a release, it listed the six functions `use GenServer`
generates and explained what each does with a message it doesn't handle.

**Watch out.**
- A release strips the code after expansion (the debug info) by default.
  There, where each function came from is still known, from the line table
  stack traces use, but the code is BEAM assembly. To keep the expanded
  code on a staging node, build its release with
  `strip_beams: [keep: ["Dbgi"]]`.
- A macro's own code after expansion is the code that builds what it
  returns, with its `quote` already expanded into tuples. What it generates
  reads better in the module that calls it.
- `module_code` reads the `.beam` on the node's code path. A module
  compiled in memory (an `.exs` script, `Code.compile_string/1`) has none,
  and after `load_module` the file may not be the code that runs; the tool
  says so.

### 18. Watching a load test

**Situation.** You're load testing and want to know what breaks first and
why.

> I'm starting a load test against `api@perf-1`. Snapshot now, then every
> few minutes, and tell me which process becomes the bottleneck first.

**What the agent does.** Repeated `snapshot`/`diff`, `message_queues` and
`schedulers` checks while the load ramps up. The first mailbox to grow, or
the point where schedulers saturate, is your capacity limit, and
`process_info` says which code it's in.

### 19. Getting to know an unfamiliar system

**Situation.** You've inherited a system, or are onboarding, and want to see
how it's actually put together at runtime.

> Connect to `legacy@ops-1` and explain how it's structured: which
> applications, what each supervisor runs, and what looks unusual.

**What the agent does.** `supervision_tree` for each application, plus a
`diagnose` baseline. Combined with the source (scenario 13), it can map
runtime processes to modules and explain restart strategies and limits,
which the tree shows for every supervisor along with its recent restarts.
That's often quicker than reading the code alone, because the runtime
shows what's actually started, including dynamic children, and which parts
have been restarting.

---

## Other kinds of targets

### 20. Erlang products you didn't write

**Situation.** A third-party system built on the BEAM misbehaves: a message
broker, a database, an XMPP server, anything written in Erlang, Elixir, Gleam
or LFE.

> Connect to `rabbit@mq-1` with the cookie from
> `/var/lib/rabbitmq/.erlang.cookie`. Which processes use the most memory,
> and are any mailboxes backing up?

**What the agent does.** The same checks as for your own code, on Erlang,
Gleam and LFE nodes as on Elixir ones (see the demo targets in
[examples/erlang](../examples/erlang), [examples/gleam](../examples/gleam)
and [examples/lfe](../examples/lfe)). Nothing has to be installed on the target, because the tool attaches over Erlang
distribution as a hidden node. If the product ships its own recon, that copy
is used as-is.

**Watch out.** You won't have the source in the session, so findings stop at
"this process, in this function." Products often have their own diagnostics
too, such as RabbitMQ's `rabbitmq-diagnostics`; use both. Locate the cookie
with care: it grants full control of the node.

### 21. Your own node during development

**Situation.** You're developing locally and want runtime answers while you
code.

```sh
iex --sname dev -S mix
```

(or `iex --sname dev -S mix phx.server` for a Phoenix app)

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
- **`load_module` changes running code.** Each load needs your approval in
  a dialog, and lasts until the node restarts. Read the dialog: it says
  which code goes onto which node.
- **Tool output goes to the AI provider.** That includes process state,
  traced arguments and ETS contents. Mind secrets and personal data.
- **Tracing on pre-27 nodes is one at a time.** There `trace_calls` won't
  start while another `recon_trace` session or similar tracing is active,
  because it would end it. Only force it if you know whose trace that is.
  OTP 27+ nodes have isolated trace sessions, and this doesn't apply.
- **Network.** Erlang distribution needs epmd (port 4369) and the
  target's distribution port reachable from wherever the tool runs; see
  [production.md](production.md) for firewalls, loopback-only targets and
  TLS.

## Not supported yet

These would be natural scenarios, but the tool can't do them well yet (see
the README's TODO list):

- **Nodes on an older OTP release without a compiler.** Recon has to be
  compiled on such a node, and slim releases often leave the compiler out,
  so the recon-based checks are unavailable there.
- **Tracing alongside other tracing on OTP 26 and earlier.** There
  `trace_calls` would end someone else's trace, so it asks first.
