# Usage scenarios

Ways to use otp_debug_mcp with Claude Code (or any MCP client). Each
scenario gives the situation, a prompt to start with, the tools the agent
typically reaches for, and what to watch out for.

Each scenario ends with **Try it**: the command that starts a demo node
showing it, from the repository's root, and a prompt to give the agent.
`yourhost` is the output of `hostname -s`, and `run.sh stop`, in the same
directory, stops the demo's nodes.

The prompts are only starting points. The agent picks tools itself; with the
`otp-debug` skill installed it follows the same playbook: connect, run
`diagnose`, drill into what it flags, then confirm trends with `snapshot`.

[talks/three-scenarios.pptx](../talks/three-scenarios.pptx) is a 15-minute
talk, with speaker notes, on scenarios 6 and 22, 7 and 8, with the tool
output of their walkthroughs.

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
  - [13. Garbage collection eating the CPU](#13-garbage-collection-eating-the-cpu)
  - [14. Traffic between nodes](#14-traffic-between-nodes)
  - [15. A web server refusing or stalling connections](#15-a-web-server-refusing-or-stalling-connections)
  - [16. A riak_core cluster in trouble](#16-a-riak_core-cluster-in-trouble)
- **Understanding and verifying**
  - [17. Finding the bug in the code, not just the node](#17-finding-the-bug-in-the-code-not-just-the-node)
  - [18. Seeing what a function really receives](#18-seeing-what-a-function-really-receives)
  - [19. What's in an ETS table](#19-whats-in-an-ets-table)
  - [20. Verifying a fix or a deploy](#20-verifying-a-fix-or-a-deploy)
  - [21. A deploy or a hot load that didn't take](#21-a-deploy-or-a-hot-load-that-didnt-take)
  - [22. Trying a fix on the live node](#22-trying-a-fix-on-the-live-node)
  - [23. Code that macros generated](#23-code-that-macros-generated)
  - [24. Watching a load test](#24-watching-a-load-test)
  - [25. Getting to know an unfamiliar system](#25-getting-to-know-an-unfamiliar-system)
- **Other kinds of targets**
  - [26. Erlang products you didn't write](#26-erlang-products-you-didnt-write)
  - [27. Your own node during development](#27-your-own-node-during-development)
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
| `ets` | a table without eviction | `ets_tables`, then `ets_table` for what's in it; `yaws` when it's Yaws's cookie sessions |
| `atom` | atoms created from input | `atom_table` |
| nothing: the OS sees far more than `erlang:memory()` reports | allocator fragmentation: carriers kept alive by a few live blocks | `allocator_fragmentation` |
| `processes`, on a Phoenix node with LiveViews | assigns that grow for as long as a page is open | `phoenix` |

It then takes a `snapshot`, waits under real load, and diffs it. A single
large number is a guess; a number that keeps growing across diffs is the
evidence.

On a Phoenix node, `phoenix` looks at the LiveView processes, one per
open page, by view: how many, their memory, how many grew through the
window and how fast. For the biggest, it reads which assigns hold the
memory, and how long a list is. A LiveView keeps its assigns for as long
as the page is open, so a list that gains an item with every PubSub
message grows in every open tab. Against the LiveView demo
(`examples/elixir/run.sh live`), it found an orders dashboard whose
`orders` assign kept every order since the page opened (walkthrough 31).

**Watch out.** `binary_leak` forces a garbage collection in every process.
That's cheap, but say so if the node is under pressure.

**Try it.**

```sh
examples/elixir/run.sh shop        # a mailbox that never drains
examples/erlang/run.sh sessions    # atoms and ETS rows piling up
examples/books/run.sh slice        # small slices pinning large binaries
examples/elixir/run.sh yaws        # a Yaws API starting a session on every request
examples/elixir/run.sh live        # a LiveView dashboard whose assigns keep growing
```

> `shop_ex@yourhost` is getting slower and using more memory; find out why.

> The staff's orders dashboard, a LiveView on `live_ex@yourhost`
> (http://localhost:4050/), gets sluggish the longer it's open, and the
> node's memory keeps growing. Find out why.

Walkthroughs 1, 14 and 31.

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
answered 404 (walkthrough 12).

`phoenix` gives the same window's LiveView callbacks (mount,
handle_params, handle_event, by view and event) and channel messages,
slowest first. A LiveView handles one message at a time, so a slow
`handle_event` holds up everything else for that page, its PubSub
messages included. It also lists the routes that an earlier route for
the same verb makes unreachable, as the Phoenix demo's search was.

On a Phoenix or Bandit node whose clients get connection resets or wait
before the first byte, `bandit` shows whether the server is at its
connection limit and what holds the connections (scenario 15).

When requests wait on the database, `postgrex` shows why from the
pool's side: each Postgrex pool (an Ecto repo's too), its connections up
or reconnecting, idle or checked out, who holds each checked-out one,
where in their code, and whether in a transaction while doing something
else, and the callers waiting for a connection, how long and from where.
All of it is read from DBConnection's own tables, without asking the
pool anything. With `server: true` it also reads `pg_stat_activity`
through a short-lived connection of the pool's own options: backends idle
in a transaction, and queries waiting for a lock another backend holds,
each matched to the pool's connection and the caller holding it. Against
the Postgrex demo (`examples/elixir/run.sh postgrex`), it found product
pages waiting for connections that checkouts held through a payment call
(walkthrough 26).

Telemetry itself can be the cause. A handler runs in the process that
emits the event, inside `telemetry:execute`, so every request waits for
every handler attached to its events. `telemetry_handlers` lists the
handlers and what they cost: it samples the processes' stacks through
the window for those inside a handler (which one, read from telemetry's
own frame) and divides the average number inside by the events a second
the handler gets, which is about its time per event, without tracing.
It also reports handlers that raised in the window (telemetry detaches
them for good, so what they reported stops, with one log line), handlers
whose function doesn't exist, one function attached twice to an event,
and handlers attached per process or request that pile up. Against the
telemetry demo (`examples/elixir/run.sh telemetry`), it found thousands
of handlers attached one per checkout, never detached, all run on every
payment (walkthrough 24).

**Typical findings.** One process serializing work for everyone (a registry,
a single DB connection, the owner of an ETS table doing all writes), or
fire-and-forget casts with no backpressure. From `telemetry`: one route or
query far slower than the rest, a p95 far above the p50 (some calls wait
on something), queries waiting on the pool (`queue_time_ms`), or one
request running many fast queries. From `postgrex`: a pool exhausted by
connections held through slow work in a transaction (a call out, inside
`Repo.transaction`), and the rows those transactions wrote, locked for
everyone meanwhile. From `telemetry_handlers`: a handler
that calls a busy process (a metrics reporter behind a `GenServer.call`),
handlers piling up, or metrics that stopped because their handler raised
once and was detached.

**Try it.**

```sh
examples/elixir/run.sh shop
examples/elixir/run.sh phoenix
examples/elixir/run.sh telemetry
examples/elixir/run.sh postgrex
```

> `shop_ex@yourhost` is getting slower and using more memory; find out why.

> `phoenix_ex@yourhost` is a Phoenix API. Tell me what requests it's
> serving right now, how fast, and whether anything looks wrong.

> Checkout on `telemetry_ex@yourhost` (`Shop.Checkout.run/1`) gets
> slower the longer the shop runs, and its CPU use creeps up. Find out
> why.

> Product pages on `postgrex_ex@yourhost` (`Shop.Catalog.show/1`) are
> slow now and then, and some fail with "connection not available and
> request was dropped from queue", though their query takes a
> millisecond. Find out why.

The Postgrex demo runs its own PostgreSQL (`initdb` and `pg_ctl` on the
PATH), created in `examples/elixir/postgrex_shop/pgdata` and listening on
127.0.0.1:5544; `run.sh stop` stops it. Walkthroughs 1, 12, 24 and 26.

### 3. High CPU, and making code faster

**Situation.** Monitoring shows the node near 100% CPU, or one operation
is slower than it should be and you want it faster.

> CPU on `worker@batch-2` is pegged. Is it really busy, and doing what?

**What the agent does.** `run_check(schedulers)` first. OS CPU% overstates a
BEAM node because schedulers busy-wait; scheduler utilization is the real
number. `scheduler_time`, in `diagnose`, says what the busy schedulers
spend the time on: Erlang code, garbage collection, ports, I/O polling, or
spinning while they wait for work. If schedulers are saturated running
code, `top_reductions` names the processes
burning CPU, and `profile` on their hot module ranks its functions by the
time they use, with call counts and memory allocated. `trace_calls` on the
top one then shows the arguments it's called with.

> Profile `Pricing` on `worker@batch-2` for 5 seconds. Which functions use
> the time?

To tune a program, the loop is: find where the time goes, measure, change,
measure again. `hot_spots` is the first step on any node, as it needs no
module to start from and traces nothing: it samples the busiest
processes' stacks every 10 ms and ranks functions by their share of the
samples, at the top of the stack (own time) and anywhere in it, with the
first frame of your code (the place to change), the hottest stacks, and
the time spent collecting garbage. `profile` on the module it points to
then counts calls and time exactly. `benchmark` measures the function:
called with the same arguments by fresh processes, for a while, it gives
the time per call (p50 to max), reductions per call and calls a second.
Given several functions, it compares them and checks each returns
exactly what the first did, so a rewritten version loaded under another
name (`load_module`, with the user's approval) is measured against the
original. Given several spawn options, it tries a process's tuning, such
as a larger `min_heap_size` for a function that allocates a lot. Against
the tuning demo (`examples/erlang/run.sh tuning`), the loop took a quote
for a 3000-line order from about a second to a few milliseconds
(walkthrough 27).

**Typical findings.** Real saturation (all schedulers near 1.0) versus one
pegged scheduler with the rest idle, which points to a long-running NIF
(scenario 11: `long_schedules` names it). A large `gc_share_of_work` in
`scheduler_time`: much of the work is garbage collection, from big heaps
or many short-lived terms; large heaps are collected on the dirty CPU
schedulers, so it counts those too.
A profile usually puts most of the time in a few functions: a loop over a
large list, repeated encoding or decoding, a regex compiled on every call.
The usual tunings: `lists:nth` or `length` in a loop (quadratic: walk the
list once), lookups in a list (`lists:keyfind` on a big list: a map or
ETS), `++` onto a growing list or string (build an iolist, reversed or
not, and flatten once), work repeated per call that could be done once
(a catalog rebuilt, a regex compiled), and for a function that allocates
a lot, a larger `min_heap_size` for the process running it.

**Watch out.**
- Counting slows down every profiled call, so profile one module for a few
  seconds on production nodes. `all_modules` counts every function on the
  node: much more expensive.
- Only time spent running counts. A function that's slow because it waits
  for a reply, a lock or a sleep shows little time in a profile; that's
  scenario 2, and `trace_calls` timestamps.

**Try it.**

```sh
examples/erlang/run.sh reports     # CPU spent collecting garbage
examples/erlang/run.sh native      # a NIF holding a scheduler
examples/erlang/run.sh tuning      # quotes that take a second: profile and tune
```

> `reports_erl@yourhost` uses a lot of CPU for what it does: it only adds
> up the day's sales. Find out where the CPU goes.

> Quotes for big orders on `tuning_erl@yourhost` take about a second each
> (`quote:build/1`, e.g. `quote:build(quote:sample_order(3000))`).
> Profile it, find what to change, and measure.

Walkthroughs 15, 7 and 27.

### 4. A process is stuck, or calls time out

**Situation.** A feature hangs, or calls to one GenServer time out, or
calls to a backend through a client pool time out or are refused now
and then.

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
timeout infinity, and the shoppers stuck behind them (walkthrough 11).

`process_info` on the process by name tells more. Its age
and its supervisor's restart history tell a long-stuck process from one
that keeps crashing and coming back. `current_function` and the stack
trace show where it's blocked: waiting on
another process's call, a receive, a port or a lock. `include_state: true`
fetches its state, and a `sys:get_state` timeout is itself a finding:
the process is too busy or blocked to answer. `supervision_tree` shows
what it depends on and what restarts with it.

On Mnesia, the waits are for locks. `mnesia` reads Mnesia through its
own `system_info` and `table_info`: its nodes and tables (storage,
size, memory, where their copies are, and whether any is reachable), the
transactions running and their commits, aborts and restarts a second;
it samples the lock queue through the window for the records
transactions wait for a lock on, with where in the code their holders
are; and it subscribes to Mnesia's system events meanwhile (overload, a
partitioned network, a node down). Against the Mnesia demo
(`examples/erlang/run.sh mnesia`), it found every order waiting for the
day's stats record, held by transactions that call a fraud check while
holding it (walkthrough 25).

For calls to a backend through shackle (and the clients built on it:
marina for Cassandra, anchor for memcached, buoy for HTTP), `shackle`
reads each pool: its backend, size, `backlog_size` and retries, each
connection up or reconnecting with its requests in flight, the
callers waiting for a reply grouped by where they called from; and over
a window shackle's telemetry: replies and their times, timeouts, and
calls refused. Against the shackle demo (`examples/elixir/run.sh
shackle`), it found one connection's backlog full while the other three
were idle, an export holding it up (walkthrough 23).

**Typical findings.** Two processes calling each other (deadlock), often
one calling back into the other from a callback, a call to a slow
external service made inside a GenServer, or a process blocked behind its
own backlog. On Mnesia: a hot record (a counter every transaction
updates) and slow work inside a transaction, which holds its locks
until it ends, with many restarts (Mnesia restarts the younger of two
transactions that would wait for each other, running its fun again: a
fun with side effects does them again). With shackle: head-of-line blocking (a backend that
answers a connection's requests in order, so one slow request holds up
every request behind it on that connection, and they time out while the
other connections idle); connections down and reconnecting; and calls
refused with `{error, no_server}`, which is what shackle returns when
the connections a call picked were full (`backlog_size`) as well as
when they were down, once `max_retries` (0 by default) ran out.

**Try it.**

```sh
examples/erlang/run.sh locks
```

> Shoppers on `locks_erl@yourhost` say their reservations all time out
> now, though it worked when it started. Find out why.

Walkthrough 11. `examples/books/run.sh lock` has a deadlock that a
timeout ends every few seconds ([plausible-but-wrong.md](plausible-but-wrong.md)).

```sh
examples/elixir/run.sh shackle
```

> On `shackle_ex@yourhost`, price lookups (`price_api:lookup/1`) fail
> now and then, though the pricing backend answers a lookup in a
> millisecond. Find out why.

It fetches shackle from Hex the first time; its pricing backend runs in
the same node, on port 8097. Walkthrough 23.

```sh
examples/erlang/run.sh mnesia
```

> Placing an order on `mnesia_erl@yourhost`
> (`mnesia_shop:place_order/2`) takes up to a second at busy times,
> though an order's work takes about 30 ms. Find out why.

Walkthrough 25.

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

**Try it.**

```sh
examples/erlang/run.sh sessions    # the atom table filling up
examples/erlang/run.sh ports       # ports opened and never closed
```

> Check `sessions_erl@yourhost` for anything heading toward a system limit.

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

**Try it.**

```sh
examples/elixir/run.sh payments    # or examples/erlang/run.sh payments
```

> `payments_ex@yourhost` fails payments now and then. Find out why.

Walkthrough 2.

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
the arguments. `diagnose`'s `logs` check says where the node's logs go;
when no file keeps them, errors from before anyone listened are gone,
and a watch started early is the way to catch the next ones.

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

**Try it.**

```sh
examples/erlang/run.sh orders
```

> `orders_erl@yourhost` loses some of the orders it imports, and payments
> fail now and then, but its numbers look healthy. Find out why.

Walkthrough 9.

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

**Try it.**

```sh
examples/erlang/run.sh crash
```

> `crash_erl` died a minute after it started. It left a crash dump at
> `examples/erlang/dumps/crash_erl.dump`. Find out why it died.

It dies within a minute; ask once it's gone (`pgrep -f crash_erl` finds
nothing). Walkthrough 10.

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
joined or lost its links, or a node whose atom count has crept up. On one
node, `diagnose`'s `distribution` check shows its connections: bytes per
second each way, and bytes waiting to be sent against the busy limit,
past which every process sending to that node is suspended. On a
Mnesia cluster, `mnesia` names the db nodes Mnesia isn't running on,
the tables with fewer copies for it or none reachable at all, and a
partition healed with tables that may differ (`inconsistent_database`),
which Mnesia doesn't merge by itself.

**Watch out.** Nodes are attached with the current target's cookie, as a
cluster shares one; a node with another cookie shows as unreachable.

**Try it.**

```sh
examples/elixir/run.sh cluster     # or examples/erlang/run.sh cluster
```

> `ex_a@yourhost` is part of a cluster that's getting slower. Find out why.

Only `ex_b` has the bug. Walkthrough 3.

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

**Try it.**

```sh
examples/erlang/run.sh payments
```

> `payments_erl@yourhost` is misbehaving. Give me a quick health summary
> before we decide whether to restart it.

Any demo will do.

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

**Try it.**

```sh
examples/erlang/run.sh native
```

> `native_erl@yourhost` stalls for tens of milliseconds now and then, and
> the OS says it uses more memory every minute, though erlang:memory()
> doesn't change. Find out why.

It needs a C compiler, to build the NIF library. Walkthrough 7.

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

**Try it.**

```sh
examples/erlang/run.sh ports
```

> `ports_erl@yourhost`'s port count keeps climbing, and one of its
> connections stops sending now and then. Find out why.

Walkthrough 8.

### 13. Garbage collection eating the CPU

**Situation.** The node uses far more CPU than its work seems to need, and
profiling points at ordinary code: list building, a sort, a map update.

> `reports@batch-1` uses a lot of CPU for what it does: it only adds up
> the day's sales. Find out where the CPU goes.

**What the agent does.** `diagnose`'s `scheduler_time` check splits the
schedulers' time over 2 seconds by what they did, from the VM's
microstate accounting: running Erlang code, collecting garbage, running
ports, polling for I/O, or spinning while they wait for work.
`gc_share_of_work` is garbage collection's share of the work of the
normal and the dirty CPU schedulers, where large heaps are collected,
and `gc_schedulers` the schedulers' worth of time it took.
`top_reductions` names the busy processes, and `profile` on their module
shows which functions run and how much memory each allocates. Against
the reports demo (`examples/erlang/run.sh reports`), 42% of the work was
garbage collection, almost a scheduler's worth of time, and the profile
showed each report allocating 24 MB to build and sort a list it only
adds up (walkthrough 15).

**Typical findings.** Big intermediate lists built and dropped (a
comprehension, then a sort, then a fold), large heaps copied by message
passing, a process whose heap grows and shrinks with every request. The
fix is to allocate less: one pass instead of several, no sort a sum
doesn't need.

**Watch out.** Microstate accounting is turned on for the check's 2
seconds only, and left alone if it was already on; its cost is small.

**Try it.**

```sh
examples/erlang/run.sh reports
```

> `reports_erl@yourhost` uses a lot of CPU for what it does: it only adds
> up the day's sales. Find out where the CPU goes.

Walkthrough 15.

### 14. Traffic between nodes

**Situation.** The network between nodes is saturated, calls to another
node are slow, or nodes disconnect under load.

> The network link between `api@node-1` and `api@node-2` is saturated.
> Find out what's using it.

**What the agent does.** `diagnose`'s `distribution` check lists the
node's connections to other nodes, with bytes per second each way over a
second, and the bytes waiting to be sent against the VM's busy limit
(`+zdbbl`, 1 MB by default). Past that limit the connection is busy, and
every process sending to that node is suspended until it drains;
`long_schedules` names the processes suspended that way
(`busy_dist_port`). `process_info` and `module_code` on such a process
show what it sends. Against the dist demo (`examples/erlang/run.sh dist`),
the agent ran `distribution` first: 17 MB/s from `dist_a` to `dist_b`.
`long_schedules` named the `catalog` process, suspended 19 times in 2
seconds, and its code sent the whole catalog ten times a second
(walkthrough 17).

**Typical findings.** Large terms sent where a change would do, a cache
or state replicated whole on every update, chatty calls in a loop, a
`:global` or `:pg` storm after a netsplit heals. All traffic between two
nodes shares one connection, so small calls wait behind big messages.

**Watch out.** A TLS connection's controller is a process, not a port:
for it, `pending_bytes` is that process's message queue length, and the
byte rates aren't available.

**Try it.**

```sh
examples/erlang/run.sh dist
```

> The network link between `dist_a@yourhost` and `dist_b@yourhost` is
> saturated. Find out what's using it.

Walkthrough 17.

### 15. A web server refusing or stalling connections

**Situation.** Some clients of a Phoenix, Bandit, Cowboy, Yaws or Ranch
service get their connections reset, or wait seconds before the first
byte, while the request times the server reports look fine and nothing
is logged; or the server's memory keeps growing under steady traffic.

> Some clients of `shop@web-2` get their connections reset, or wait
> seconds before the first byte, but the request times Bandit reports
> look fine and nothing is logged. Find out why.

**What the agent does.** `bandit` looks at every Bandit server on the
node, through Thousand Island, the socket server under it. Now: where it
listens, its connection limit (acceptors × connections per acceptor) and
how full it is, acceptors waiting for room for a new connection, and its
connections, idle keep-alives or busy, the busy ones grouped by the
function they wait in and the first frame of the application's code.
Then, over a window, from its telemetry: requests per second by status,
the slowest routes, requests that raised, socket errors by reason, and
connections refused because the limit was reached, which Thousand Island
doesn't log. Against the Bandit demo (`examples/elixir/run.sh bandit`),
it found the server at 100 of 100 connections, all four acceptors
waiting, 30 connections held in a 3-second upstream call, 70 in idle
keep-alives, and connections refused (walkthrough 18).

`cowboy` does the same for Cowboy, through Ranch, the acceptor pool
under it: each listener's limit, acceptors blocked waiting for room,
idle and WebSocket connections, the requests in flight (each runs in a
process of its own) grouped by where they wait, those still running at
the end of the window, its timeouts and routes; and over the window,
Ranch's accept and close rates and, when `cowboy_telemetry_h` is in the
listener's stream handlers, requests by status, the slowest routes,
handler crashes and early errors. Against the Cowboy demo
(`examples/elixir/run.sh cowboy`), it found every connection held by a
report request waiting on one gen_server, and the acceptors blocked
(walkthrough 21).

`yaws` does it for Yaws: each listening server's virtual servers and
appmods, its connections against `max_connections`, what its acceptor
processes are doing (Yaws handles each connection, and runs `out/1`, in
one: accepting, pooled, waiting for a keep-alive request, or handling
one), the requests in flight grouped by where they wait and those still
running at the end of the window, and its cookie sessions: how many,
how fast they grow, how many were never used again after the request
that started them, and expired ones still kept. Against the Yaws demo
(`examples/elixir/run.sh yaws`), it found a new session on every
request (walkthrough 22).

`ranch` looks at the Ranch listeners themselves, whatever protocol they
run: HTTP under Cowboy, AMQP under RabbitMQ, or a protocol of your own.
It reports each listener's limit per connection supervisor and the
acceptors waiting for room, and groups the connection processes by
where they are in the protocol's code. Then it lists the connections
that did nothing through the window (no reductions, no bytes), those
stuck in a handshake, and those with bytes waiting for a slow reader,
and counts the connection processes that crashed, from Ranch's own log
lines. Against the Ranch demo (`examples/elixir/run.sh ranch`), it
found a point-of-sale server full, 60 of its 100 connections idle in a
`recv` with no timeout, and the acceptors waiting (walkthrough 30).

**Typical findings.** A connection limit set far below the default
(16,384 per acceptor), slow requests holding connections (an upstream
call, a pool checkout), idle keep-alives holding the rest for up to
`read_timeout`, and a slow route that the request times show but don't
connect to the refused clients: the time a client spends waiting to be
accepted is before Bandit starts timing the request. With Cowboy, Ranch's
`max_connections` (1,024 by default) caps each connection supervisor,
one per acceptor unless `num_conns_sups` says otherwise, so the real
limit is their product and one supervisor can fill before the listener
does. At the cap Ranch refuses nothing: the acceptor waits, and new
clients wait unaccepted in the listen backlog, with nothing logged. And
Cowboy's `request_timeout` is the time to receive a request's headers,
not a limit on the handler. Yaws, past `max_connections` (no limit by
default), closes each new connection as soon as it accepts it, and logs
"Max connections reached". Its cookie sessions are kept for 30 minutes
after their last use, and expired ones are removed only by an hourly
sweep, so code that starts a session per request (or clients that don't
send the cookie back) piles up an hour and a half of sessions. A
protocol of your own on Ranch that waits with an `infinity` timeout
keeps every client that went away without closing (behind a NAT, a
laptop put to sleep) until the listener is full.

**Watch out.** Listening attaches a telemetry handler for the window,
detached afterwards; nothing else is loaded. Connections are looked at
one by one, up to 5,000 (and with Cowboy, up to 500 requests). Without
cowboy_telemetry, `cowboy` still sees the listeners, connections and
requests in flight, but not requests by status.

**Try it.**

```sh
examples/elixir/run.sh bandit
```

> Some clients of `bandit_ex@yourhost` get their connections reset, or
> wait seconds before the first byte, but the request times Bandit
> reports look fine and nothing is logged. Find out why.

It fetches Bandit from Hex the first time. Walkthrough 18.

```sh
examples/elixir/run.sh cowboy
```

> Browsing products on `cowboy_ex@yourhost` (GET
> http://localhost:8090/products) takes several seconds, though the
> products handler just returns a constant. Find out why.

It fetches Cowboy from Hex the first time, and serves port 8090.
Walkthrough 21.

```sh
examples/elixir/run.sh ranch
```

> New tills can't connect to our point-of-sale server,
> `ranch_ex@yourhost` (port 5555): they time out, while the tills
> already connected keep working. Restarting it helps for a minute or
> so. Find out why.

It fetches Ranch from Hex the first time. Walkthrough 30.

```sh
examples/elixir/run.sh yaws
```

> The memory of `yaws_ex@yourhost`, a Yaws API, keeps growing, though
> its traffic is steady. Find out why.

It fetches Yaws from GitHub the first time (it builds a PAM driver:
`libpam0g-dev` on Debian and Ubuntu), and serves port 8095.
Walkthrough 22.

### 16. A riak_core cluster in trouble

**Situation.** A cluster built on riak_core (Riak KV, riak_core_lite, a
system of your own) is slow or loses requests: a member went down,
handoffs don't finish after a join, one partition is overwhelmed, or the
CRDTs its vnodes keep grow without end.

> Writes to our riak_core cluster have got slow, and some time out.
> Find out why.

**What the agent does.** `riak_core` reads the cluster through
riak_core's own API, from the node it's connected to: the members, their
status and whether this node reaches them, the claimant, partition
ownership and the ownership changes awaiting handoff, this node's vnodes
(primaries, and fallbacks held for unreachable owners), the longest vnode
mailboxes on every member it reaches, of the vnodes and their proxies,
the handoffs running, the services up on each member, and riak_core's
own ringready and transfers. Its findings come worst first. Against the
riak demo (`examples/elixir/run.sh riak`), it found from `riak_a` both a
member down, with fallbacks holding its partitions, and a vnode on
`riak_b` with 9,000 commands queued, all for one hot key (walkthrough 19).
With `crdts: true` it also measures the riak_dt sets and maps this
node's vnodes hold, in their state or their ETS tables: the largest,
their actors, elements and deferred removes, each with the key it's
under. Against the wishlist demo (`examples/elixir/run.sh wishlist`) it
found sets of 30 items with thousands of actors, one per request
(walkthrough 20).

**Typical findings.**
- A member down or unreachable: fallbacks hold its writes until hinted
  handoff, and a down claimant blocks every ownership change.
- Ownership changes that never complete: handoff concurrency 0, or a
  vnode module registered outside a running application, which riak_core
  waits for forever before handing off.
- A hot partition: one key, or a few, taking a vnode past its overload
  threshold, where its proxy starts refusing requests.
- Members whose rings disagree, after a partition or a botched join.
- CRDTs that only grow: a riak_dt set or map with more actors than the
  ring has partitions, because its actor is a client, a request or a
  process rather than the vnode, so every update adds one to its clock
  for good; or removes deferred, waiting for adds that never arrive.

**Watch out.** It's read-only, and asks the other members for their
vnodes' mailboxes over distribution: a member it can't reach is reported,
not waited on. Connect to another member to see its own side in full.
`crdts: true` asks each of this node's vnodes for its state
(`sys:get_state`), so it waits behind a vnode's queue: a busy one is
skipped after 2 s. It sees values held in memory, as riak_dt terms or
binaries, not those in a disk backend (bitcask, leveldb) or inside Riak
KV's objects.

**Try it.**

```sh
examples/elixir/run.sh riak
```

> Writes to our riak_core shop cluster (`riak_a@yourhost`,
> `riak_b@yourhost`, `riak_c@yourhost`) have got slow, and some time
> out. Find out why.

It fetches riak_core_lite from Hex the first time, forms the cluster,
then takes `riak_c` down. Walkthrough 19.

```sh
examples/elixir/run.sh wishlist
```

> In our riak_core shop (`riak_a@yourhost`, `riak_b@yourhost`), adding
> to a wishlist gets slower the longer the shop runs, and `riak_a`'s
> memory keeps growing. Find out why.

The same project with riak_dt: two nodes, and wishlists kept as riak_dt
sets. Walkthrough 20.

## Understanding and verifying

### 17. Finding the bug in the code, not just the node

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

Functions that macros generate aren't in the source to open; scenario 23
finds them on the node.

**Try it.**

```sh
examples/elixir/run.sh shop
```

> `shop_ex@yourhost` is getting slower. Find the cause on the node, then
> find the responsible code in this repo and propose a fix.

Run Claude Code in this repository, so it can open the demo's source
(`examples/elixir/src/shop.exs`).

### 18. Seeing what a function really receives

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
the failing calls would be lost among the others. On the orders demo, a
coupon service turns every failure into no discount without logging it;
`trace_calls` on its `discount/1` with `exceptions: true` showed the two
codes that fail, and why, in five seconds (walkthrough 13).

**Watch out.**
- Traced arguments are real production data and go to the AI provider
  along with everything else the tools return. Don't trace functions that
  handle secrets or personal data.
- On OTP 27+ the trace runs in its own trace session and never affects
  anyone else's. On older nodes, if someone else is tracing, `trace_calls`
  refuses and says what it found. Forcing it ends their trace, so the agent
  should ask you first.

**Try it.**

```sh
examples/erlang/run.sh orders
```

> On `orders_erl@yourhost`, trace a few calls to `orders_coupons:discount/1`
> and show me the arguments and return values.

> Customers of `orders_erl@yourhost` say some coupon codes give them no
> discount, but nothing about coupons is in the logs. Find which codes,
> and why.

Walkthrough 13.

### 19. What's in an ETS table

**Situation.** An ETS table is large or growing, and you want to know
what's in it.

> The `sessions` table on `auth@prod-2` keeps growing. What's in it?

**What the agent does.** `diagnose`'s `ets_tables` check lists the
largest tables. `ets_table` on one shows its type, protection, owner and
heir, row count and memory, its first rows, and a scan of up to 10,000
rows read in chunks: the average row size, the rows at least twice that
size, and for a bag, the keys with the most rows. Against the sessions
demo (`examples/erlang/run.sh sessions`), its rows showed a new atom as
every key and nothing ever deleted, which with `atom_table`'s growth
made the cause plain (walkthrough 14).

**Typical findings.** Keys from input that are never deleted (sessions,
request ids), a cache without eviction, a few huge rows (a whole list or
map under one key, copied out on every lookup), a bag's hot key.

**Watch out.**
- Rows go to the AI provider like any tool output: mind personal data.
- A private table can only be read by its owner: only its settings are
  shown.
- A large row is shown by its key and size, not copied out whole.

**Try it.**

```sh
examples/erlang/run.sh sessions
```

> The `sessions` table on `sessions_erl@yourhost` keeps growing. What's in it?

Walkthrough 14.

### 20. Verifying a fix or a deploy

**Situation.** You've shipped a fix and want evidence that it worked.

> We deployed the cache fix to `shop@prod-4` an hour ago. Is the mailbox
> backlog gone, and is memory flat now?

**What the agent does.** `diagnose`, then `snapshot` and two `diff`s a minute
or so apart. A fixed leak shows near-zero deltas under the same load that
used to produce growth. The same before-and-after comparison works for
config changes, such as a new pool size.

First, though, check that the new code runs at all. `diagnose`'s
`stale_code` check lists modules whose `.beam` on the code path differs
from the code running (files deployed but never loaded), and processes
still in a module's old code after a hot load.

**Try it.**

```sh
examples/elixir/run.sh payments
elixirc -o _build/payments_fix examples/elixir/fixes/payments_gateway.ex
```

> Load `_build/payments_fix/Elixir.Payments.Gateway.beam` onto
> `payments_ex@yourhost`, then check that the crash loop is over.

`load_module` asks you to approve the load. Walkthrough 4.

### 21. A deploy or a hot load that didn't take

**Situation.** A fix was deployed, but the node behaves as before; or
someone loaded a module by hand, and something still runs the old code.

> We deployed a fix to `shop@prod-1`: discounts are 10% now, not 5%.
> Orders still get 5%. Find out why.

**What the agent does.** `diagnose`'s `stale_code` check lists loaded
modules whose `.beam` on the code path differs from the code running
(files copied but never loaded), or that have no `.beam` there at all,
and modules whose old version is still in memory after a hot load, with
the processes still running it. `module_code` on a module says whether
the running version is the file's, and `trace_calls` shows what the
running code returns. Against the deploy demo
(`examples/erlang/run.sh deploy`), `stale_code` named `discounts` as
different on disk, and a trace showed the running code still taking 5%
off (walkthrough 16).

**Typical findings.** A deploy that copied files and didn't load them
(no release upgrade, no restart), a module loaded on one node of a
cluster and not the others, a receive loop that calls itself locally and
so never leaves the old code, and is killed by the module's next load.

**Watch out.** recon, which this tool injects into a node that lacks it,
isn't on the node's code path; `stale_code` leaves it out.

**Try it.**

```sh
examples/erlang/run.sh deploy
```

> We deployed a fix to `deploy_erl@yourhost`: discounts are 10% now, not
> 5%. Orders still get 5%. Find out why.

Walkthrough 16.

### 22. Trying a fix on the live node

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
  `diagnose`'s `stale_code` check names them, and lists the module as
  different on disk until the fix is deployed.

**Try it.**

```sh
examples/elixir/run.sh payments
elixirc -o _build/payments_fix examples/elixir/fixes/payments_gateway.ex
```

> `payments_ex@yourhost` crash-loops in Payments.Gateway: the port in its
> URL is malformed. I've compiled a fix to
> `_build/payments_fix/Elixir.Payments.Gateway.beam`. Try it on the node
> and check that the crashes stop.

Walkthrough 4.

### 23. Code that macros generated

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

**Try it.**

```sh
examples/elixir/run.sh billing     # a macro DSL that records charges twice
examples/elixir/run.sh phoenix     # a route shadowed by one `resources` generates
```

> `billing_ex@yourhost` records every charge twice: acme's balance is
> double what was charged. Find out why.

Walkthroughs 5 and 6.

### 24. Watching a load test

**Situation.** You're load testing and want to know what breaks first and
why.

> I'm starting a load test against `api@perf-1`. Snapshot now, then every
> few minutes, and tell me which process becomes the bottleneck first.

**What the agent does.** Repeated `snapshot`/`diff`, `message_queues` and
`schedulers` checks while the load ramps up. The first mailbox to grow, or
the point where schedulers saturate, is your capacity limit, and
`process_info` says which code it's in.

**Try it.**

```sh
examples/elixir/run.sh bandit
```

> Snapshot `bandit_ex@yourhost` now and again in a minute, and tell me
> what becomes the bottleneck first.

No load-test demo of its own: the Bandit demo has its traffic built in.

### 25. Getting to know an unfamiliar system

**Situation.** You've inherited a system, or are onboarding, and want to see
how it's actually put together at runtime.

> Connect to `legacy@ops-1` and explain how it's structured: which
> applications, what each supervisor runs, and what looks unusual.

**What the agent does.** `supervision_tree` for each application, plus a
`diagnose` baseline. Combined with the source (scenario 17), it can map
runtime processes to modules and explain restart strategies and limits,
which the tree shows for every supervisor along with its recent restarts.
That's often quicker than reading the code alone, because the runtime
shows what's actually started, including dynamic children, and which parts
have been restarting.

**Try it.**

```sh
examples/elixir/run.sh phoenix
```

> Connect to `phoenix_ex@yourhost` and explain how it's structured: which
> applications, what each supervisor runs, and what looks unusual.

`examples/elixir/run.sh riak`, a three-node riak_core cluster, is a
bigger one to explore.

---

## Other kinds of targets

### 26. Erlang products you didn't write

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

For EMQX, the MQTT broker, `emqx` reads it through its own APIs and
tables: its version, cluster and overload protection, its own active
alarms, its listeners and how full they are, its clients and sessions,
its counters over a window (messages received and delivered, dropped by
reason, sessions taken over or discarded, authentication failures), the
clients that can't keep up (messages in flight unacknowledged, queues
full, drops, from its channel table), the client ids reconnecting, and
its rules and actions failing or disconnected. EMQX 5 listens for
distribution on port 4370 without epmd: the server dials that port when
its `ERL_FLAGS` say `-erl_epmd_port 4370` (a registration of its own, as
in [production.md](production.md)). Against the EMQX demo
(`examples/emqx/run.sh start`), it found a dashboard client that never
acknowledges, its messages dropped, and two devices sharing one client id
(walkthrough 28).

For ejabberd, the XMPP server, `ejabberd` reads its sessions, the c2s
process behind each client connection, mod_offline's queues and the
message archive. A connection backs up in memory rather than in its
mailbox, since ejabberd's p1_server moves the mailbox onto the heap; the
tool shows each one's growth, whether its socket is still open, and what
it's doing. It compares each offline queue with the user's
`max_user_offline_messages` (past it, messages bounce), and, with the
archive (mod_mam) on Mnesia, times a look at its dets table, which every
delivery waits on. The ejabberd image listens for distribution on its
`ERL_DIST_PORT`, without epmd, as EMQX does. Against the ejabberd demo
(`examples/ejabberd/run.sh start`), it found a logger bot whose
connection held a growing queue, the archive slowing every delivery, and
a support account whose queue was full (walkthrough 29).

**Watch out.** You won't have the source in the session, so findings stop at
"this process, in this function." (For EMQX and ejabberd, the findings are
about clients and configuration, where the fixes usually are.) Products often have their own diagnostics
too, such as RabbitMQ's `rabbitmq-diagnostics`; use both. Locate the cookie
with care: it grants full control of the node.

**Try it.**

```sh
examples/gleam/run.sh shop        # needs Gleam
examples/lfe/run.sh shop          # needs LFE
examples/emqx/run.sh start        # EMQX in Docker, and misbehaving MQTT clients
examples/ejabberd/run.sh start    # ejabberd in Docker, and XMPP clients
```

> `shop_gleam@yourhost` is getting slower and using more memory; find out why.

> Our dashboard (MQTT client `dashboard-1`) misses sensor readings, and
> device `sensor-7` keeps going offline. EMQX is `emqx@127.0.0.1`.
> Find out why.

> Order notifications to our logger bot, slowbot@localhost, arrive late
> or not at all, and ejabberd's memory keeps growing. Messages to
> support@localhost go missing too. ejabberd is `ejabberd@localhost`.
> Find out why.

The Gleam and LFE demos are BEAM code from other languages, debugged the
same way; the EMQX and ejabberd demos are third-party products, in
Docker (see [examples/emqx](../examples/emqx) and
[examples/ejabberd](../examples/ejabberd) for registering a server for
each). Walkthroughs 28 and 29.

### 27. Your own node during development

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

**Try it.**

```sh
cd examples/elixir/bandit_shop && mix deps.get && iex --sname dev -S mix
```

> Connect to `dev@yourhost`. Did `BanditShop.Supervisor` start all its
> children? Then trace `BanditShop.Router.call/2` for a few requests.

Any Mix project of yours works the same way; this demo has its traffic
built in.

---

## Before pointing it at production

- **The cookie is full access.** Anyone with the cookie can run any code on
  the node. Giving it to the tool gives that power to the agent driving it.
- **Keep `remote_eval` off** (the default) for production nodes.
- **`load_module` changes running code.** Each load needs your approval in
  a dialog, and lasts until the node restarts. Read the dialog: it says
  which code goes onto which node.
- **To approve every step,** start the server with
  `OTP_DEBUG_MCP_CONFIRM=all`, or `changes` for only the steps that do
  something on the node: each then asks you first, saying what it does
  there.
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
