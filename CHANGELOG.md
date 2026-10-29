# Changelog

## 0.12.0

Six tools: a sampling profiler (`hot_spots`) and a benchmark
(`benchmark`) for tuning code on a live node; two Erlang products,
EMQX (`emqx`) and ejabberd (`ejabberd`), each against its Docker image,
in CI too; Ranch listeners of any protocol (`ranch`); and Phoenix
applications, LiveView included (`phoenix`). Each has a demo, a
scenario and a walkthrough.

- `phoenix`: a Phoenix application, sampled a window apart with its
  telemetry between: endpoints (where they listen, their sockets,
  code_reloader and the like); routers, and routes an earlier route
  makes unreachable; LiveView processes by view (one per open page):
  memory, how many grew and how fast, mailboxes, the busy ones, and for
  the biggest, which assigns hold the memory; channels by module;
  PubSub topics by subscribers; LiveView callbacks, channel messages
  and requests over the window, slowest first. The `telemetry` tool
  now groups LiveView and channel events by view, channel and event. A
  LiveView demo (`examples/elixir/live_shop`, `run.sh live`: an orders
  dashboard whose assigns keep every order), scenarios 1 and 2, and
  walkthrough 31.
- `ranch`: Ranch listeners, whatever protocol they run, sampled a window
  apart: limits and connections per connection supervisor, acceptors
  waiting for room; connection processes grouped by where they are and
  the first frame of the protocol's code; connections that did nothing
  through the window (no reductions, no bytes), stuck in their
  handshake, or with bytes waiting for a slow reader; connections
  removed from the count; and connection processes that crashed, from
  Ranch's log lines, by reason. A Ranch demo (`examples/elixir`, `run.sh
  ranch`: a point-of-sale server whose tills behind a NAT leave dead
  connections open), scenario 15, and walkthrough 30.
- `ejabberd`: ejabberd, the XMPP server, through its own APIs and tables,
  sampled a window apart: version, hosts, database, cluster nodes running
  and down; users online by host; client connections (c2s processes)
  backed up, by memory as well as mailbox (ejabberd's p1_server moves the
  mailbox onto the heap), with their growth, whether their socket is
  still open and what they're doing; users with the most offline
  messages against their `max_user_offline_messages` (past it, messages
  bounce); the message archive (mod_mam), on Mnesia its dets table's
  size and how long one look at it takes; MUC rooms and ejabberd's own
  processes with long mailboxes; s2s connections. An ejabberd demo
  (`examples/ejabberd`, ejabberd in Docker and XMPP clients), scenario
  26, and walkthrough 29. Tests against an ejabberd node in Docker, in
  CI's new ejabberd target job.
- `emqx`: EMQX, the MQTT broker, through its own APIs and tables: version,
  cluster, overload protection, its active alarms, listeners and how full
  they are, clients and sessions; its counters over a window (messages
  received and delivered, dropped by reason, sessions taken over or
  discarded, authentication failures); clients that can't keep up (in
  flight unacknowledged, queues full, drops, from its channel table);
  client ids reconnecting; rules and actions failing or disconnected. An
  EMQX demo (`examples/emqx`, EMQX in Docker and misbehaving MQTT
  clients), scenario 26, and walkthrough 28. Tests against an EMQX node
  in Docker, in CI's new EMQX target job.
- `hot_spots`: where a node's CPU goes, by function, without tracing: the
  busiest processes' stacks sampled every 10 ms (and a scan for busy
  short-lived ones), ranked by own time, time with callees and the first
  frame of your code, with the hottest stacks, the busiest processes and
  the share of time collecting garbage.
- `benchmark`: a function called on the node with the same arguments,
  repeatedly, by fresh processes: time per call (p50 to max), reductions
  per call, calls a second; several functions compared, each checked to
  return what the first does, and several spawn options (a larger
  `min_heap_size`) tried. A tuning demo (`examples/erlang/run.sh
  tuning`, with a tuned version to load and compare), scenario 3, and
  walkthrough 27.

## 0.11.0

Four tools for what an application runs on: Postgrex connection pools
(`postgrex`), Mnesia (`mnesia`), telemetry handlers
(`telemetry_handlers`) and shackle client pools (`shackle`), each with a
demo, a scenario and a walkthrough.

- `postgrex`: the node's Postgrex connection pools (Ecto's Postgres repos
  too), from DBConnection's own tables: each pool's connections up or
  reconnecting, idle or checked out, who holds each checked-out one,
  where in their code and whether in a transaction while doing something
  else, and the callers waiting for a connection, how long and from
  where. With `server: true`, `pg_stat_activity` and lock waits, through
  a short-lived connection of the pool's own options, matched to the
  pool's connections and callers. A Postgrex demo
  (`examples/elixir/run.sh postgrex`, with its own PostgreSQL), scenario
  2, and walkthrough 26. Tests run a throwaway PostgreSQL when its
  binaries are there.
- `mnesia`: Mnesia on the node, through its own `system_info` and
  `table_info`: its db nodes and which run, its tables (storage, size,
  memory, copies, where to read them, growth), the transactions running
  and their commits, aborts and restarts a second, and its own
  processes' mailboxes. Through the window it samples the lock queue,
  for the records transactions wait for a lock on and where in the code
  their holders are, and subscribes to Mnesia's system events (overload,
  `inconsistent_database`, `mnesia_down`). A Mnesia demo
  (`examples/erlang/run.sh mnesia`), scenarios 4 and 9, and
  walkthrough 25.
- `telemetry_handlers`: the telemetry handlers attached on the node and
  what they cost. Each handler's events and function, and whether that
  function exists; over a window, from sampling the processes' stacks,
  how many processes are inside each handler at a time (which handler is
  read from telemetry's own frame, as a handler may tail-call away) and
  about how long it takes per event; handlers that raised and were
  detached, from telemetry's `[telemetry, handler, failure]` event; one
  function attached twice to an event; handlers attached per process or
  request, piling up. A telemetry demo (`examples/elixir/run.sh
  telemetry`), scenario 2, and walkthrough 24.
- `shackle`: the node's shackle client pools (and the clients built on
  shackle: marina, anchor, buoy): each pool's client, backend, size,
  strategy, backlog size and retries, each connection up or reconnecting
  with its requests in flight and its mailbox, and the callers waiting
  for a reply grouped by where they called from, all read from shackle's
  own counters without touching the connections. Over a window, shackle's
  telemetry by client: replies and their times, timeouts, calls refused
  with `{error, no_server}` and why (connections full or down), late
  replies. Findings include one connection backed up while the others
  idle: head-of-line blocking. A shackle demo
  (`examples/elixir/run.sh shackle`), scenario 4, and walkthrough 23.
- `diagnose`'s `stale_code` no longer reports modules compiled at run
  time and loaded under a bare file name (foil's, under shackle;
  mochiglobal's) as removed from disk: they never had a file.

## 0.10.0

A tool for Yaws web servers (`yaws`), with a demo, a scenario and a
walkthrough.

- `yaws`: the node's Yaws web servers: each listening server's virtual
  servers and appmods, its connections against `max_connections` (past
  which Yaws closes new connections at once), what its acceptor processes
  are doing (accepting, pooled, waiting for a keep-alive request, or
  handling one, which runs `out/1`), the requests in flight grouped by
  where they wait and those still running at the end of the window; and
  its cookie sessions: how many, how fast they grow, how many were never
  used again after the request that started them, and expired ones kept
  until the hourly sweep. A Yaws demo (`examples/elixir/run.sh yaws`),
  scenarios 1 and 15, and walkthrough 22. Yaws is a test-only dependency,
  fetched from GitHub; its build needs PAM headers.

## 0.9.0

A tool for Cowboy web servers (`cowboy`), and a look at the riak_dt
CRDTs a riak_core node keeps (`riak_core` with `crdts: true`), each with
a demo, a scenario and a walkthrough.

- `cowboy`: the node's Cowboy web servers, through Ranch: each
  listener's connection limit (Ranch caps each connection supervisor, so
  the real limit is `max_connections` × `num_conns_sups`), acceptors
  blocked waiting for room, which leaves new clients unaccepted with
  nothing logged, idle and WebSocket connections, the requests in flight
  grouped by where they wait and those still running at the end of the
  window, timeouts and routes. Over the window, Ranch's accept and close
  rates and, with cowboy_telemetry, requests by status, the slowest
  routes, handler crashes and early errors. A Cowboy demo
  (`examples/elixir/run.sh cowboy`), scenario 15 and walkthrough 21.
- `riak_core` with `crdts: true`: the riak_dt sets (ORSWOTs) and maps the
  connected node's vnodes hold, in their state or the ETS tables they
  own, as terms or riak_dt binaries: the largest, by key, with their
  actors, elements or fields and deferred removes. Findings: more actors
  than the ring has partitions (the actor is a client, a request or a
  process rather than the vnode, so the clock grows with every update),
  a value over 1 MB, deferred removes. Each vnode is asked for its state
  (`sys:get_state`), so with `OTP_DEBUG_MCP_CONFIRM=changes` it asks
  first; a busy vnode is skipped after 2 s. Without it, `riak_core` says
  when riak_dt is loaded.
- A wishlist demo (`examples/elixir/run.sh wishlist`): riak_dt sets whose
  actor is each request's process. Scenario 16 and walkthrough 20.

## 0.8.1

Approving an investigation step by step.

- `OTP_DEBUG_MCP_CONFIRM`: to approve the investigation step by step.
  `all` asks the user before every tool call, `changes` before each one
  that does something on the node beyond reading it (connecting,
  `diagnose`, tracing, profiling, attaching a handler, `remote_eval`...).
  The dialog says what the step does, on which node, with which
  arguments; declined, nothing runs and the agent is told to ask the user
  how to go on. The answer counts only for that call, a client's "always
  allow" doesn't skip it, and a client that can't ask gets a refusal.

## 0.8.0

Tools for two kinds of system, a Phoenix or Bandit web server (`bandit`)
and a riak_core cluster (`riak_core`), a look inside ETS tables
(`ets_table`), and four more checks in `diagnose`: where the logs go,
where scheduler time goes, code that isn't what's on disk, and traffic
between nodes. Each comes with a demo, a scenario and a walkthrough.

- `riak_core`: a riak_core cluster (Riak KV, riak_core_lite, and systems
  built on them) from one member, through riak_core's own API: the
  members, their status and whether this node reaches them, the claimant,
  partition ownership and the ownership changes awaiting handoff, this
  node's vnodes (primaries, and fallbacks held for unreachable owners),
  the longest vnode mailboxes on every member it reaches, of the vnodes
  and their proxies, handoffs running, the services up on each member, and
  riak_core's own ringready and transfers. Findings, worst first: a member
  or the claimant unreachable, a vnode past or near its overload
  threshold, a vnode module registered under an application that isn't
  running (riak_core then never hands its vnodes off), handoffs off while
  changes wait.
- `bandit`: Phoenix and Bandit web servers, through Thousand Island
  under them. For each server: where it listens, its connection limit
  (acceptors × connections per acceptor) and how full it is, in total
  and per acceptor; acceptors waiting for room for a new connection,
  while new clients wait unaccepted; its timeouts; and its connections,
  idle keep-alives, reading, sending or handling a request, the busy ones
  grouped by the function they wait in and the first frame of the
  application's code. Then, over a window, from its telemetry: requests
  per second by status, the slowest routes, requests that raised, socket
  errors by reason, and connections refused at the limit, which Thousand
  Island doesn't log. Findings, worst first: refused connections are
  critical.
- `telemetry` groups Bandit's requests by method, path and status
  (`GET /products/:id -> 200`), failed ones by their error, and Thousand
  Island's events by their error; Bandit's exception events now show
  their exception.
- `ets_table`: what's in one ETS table. Its type, protection, owner and
  heir, row count and memory, its first rows, and a scan of up to 10,000
  rows (100,000 at most) read in chunks: the average row, the largest
  rows, and for a bag the keys with the most rows. A large row comes back
  as its key and size only, and a private table, which only its owner can
  read, as its settings only.
- `logs` check, in `diagnose`: where the node's logs go (its primary
  level, its handlers and what they write to, the files found with their
  size and last write). With no file, it says that errors from before
  anyone listened are gone and to start a `recent_errors` watch early; a
  primary level that hides errors is a warning.
- `stale_code` check, in `diagnose`: modules with old code still loaded
  after a hot load, and the processes still running it (killed by the
  module's next load), and loaded modules whose `.beam` on the code path
  is different (a deploy that was never loaded, or code loaded by hand),
  or whose file is gone. A module merely off the code path, as Mix leaves
  Hex's, isn't flagged, nor is recon when connect injected it.
- `distribution` check, in `diagnose`: the node's connections to other
  nodes over 1 s, with their type and state, bytes sent and received per
  second, and bytes waiting to be sent against the VM's busy limit; a
  connection near the limit, or stuck pending, is a warning. This tool's
  own connection is marked.
- `scheduler_time` check, in `diagnose`: where the time of each
  kind of VM thread goes over 2 s, from microstate accounting: Erlang
  code, garbage collection, ports, I/O polling, and busy-waiting (in
  `other`). `gc_share_of_work` counts the dirty CPU schedulers too, where
  large heaps are collected, and `gc_schedulers` is the schedulers' worth
  of time garbage collection took: 30% of the work and half a scheduler
  or more is a warning, whatever the machine's size. Accounting is turned on only for the window,
  and left alone if someone else has it on. It runs alongside
  `long_schedules`' 2 s window, so `diagnose` takes no longer.

## 0.7.0

Found by running the "Plausible but wrong" examples of the books
Learning Erlang from Claude and Learning Elixir from Claude on live nodes
(`examples/books`, `docs/plausible-but-wrong.md`): deadlocks that a
timeout already ended, the exceptions of one process wherever they're
raised, and a fix for `call_chains` on the commonest deadlock.

- Fixed: `call_chains`, and with it `diagnose`, failed with "Internal
  error" while processes waited in `gen_server:call/2` (the default
  timeout) or `Task.await`, so a deadlock of two gen_servers calling each
  other the plain way, the commonest kind, broke the check that finds it.
  It now reads the request and timeout of `gen_server:call/2` and of
  `gen_statem:call/3` with `infinity` too.
- `recent_errors` reports `deadlocks`: processes that crashed within 2
  seconds of each other, each while calling the next in a cycle, with each
  one's request. That's a deadlock a call's timeout broke, which
  `call_chains` sees only while it lasts.
- `trace_calls` takes a `process`: only the calls that process makes.
  With `exceptions: true` the module can be left out, to see every
  exported function and BIF that raises in that process, even when it
  catches the exception (5 s by default, at most 10, since every call on
  the node is a little slower meanwhile). With `exceptions: true`, each
  failing call also says where it was called from, with the line on OTP
  27+.
- `telemetry` with `list: true` says when no handler is attached to any
  event on the node: what's left when telemetry has detached a handler
  that raised.

## 0.6.0

Debugging native code and ports, errors and crashes that already
happened (`recent_errors`, `crash_dump`), deadlocks and chains of calls
(`call_chains`), Elixir libraries' telemetry (`telemetry`), and the calls
that fail (`trace_calls` with `exceptions: true`).

### Deadlocks, telemetry and failing calls

- `call_chains` (in `diagnose`): who waits on whom. It finds the processes
  waiting in a call (`gen_server`, `GenServer`, `gen_statem`), in
  `Task.await`, or in `start_link` for an init, and the process each
  waits on. Sampling twice, a second apart, it keeps the calls still
  pending on the same monitor and reports deadlocks (cycles), each
  process with its request, its timeout and how many others wait on it;
  chains of calls, ending at the process that holds them up; and the
  processes most waited on. Critical for a deadlock.
- `telemetry`: what the node's `:telemetry` events say over a window.
  Phoenix requests by route, Ecto queries by table and query, Oban jobs
  by worker, HTTP client requests by host, each with count, p50/p95/max
  of each duration (Ecto's `queue_time` too) and the slowest example; the
  errors of exception events; the events that didn't happen. Without
  events it listens to those the node's handlers listen to and the known
  events of the libraries running there (`list: true` lists them). A
  handler that keeps only small metadata sends events to a collector on
  the node, capped, detached afterwards; nothing is loaded.
- `trace_calls` with `exceptions: true`: only the calls that raise, each
  with its arguments and the exception, even when the caller catches it.
  In its own trace session on OTP 27+; before, in the legacy session,
  refused while others trace.
- `examples/erlang/run.sh locks`: two gen_servers that deadlock, with
  shoppers stuck behind them; CI smoke-tests the release against it. The
  orders demo also has a coupon service that fails silently. Scenarios 2,
  4 and 14 cover the new tools, and walkthroughs 11, 12 and 13 are
  recorded sessions with them.

### Errors and crash dumps

- `recent_errors`: the errors the node logs, grouped by who failed and
  why. A crash group is one process and reason, however often, with its
  stack, the arguments of a `function_clause`, the reports it caused and
  how many processes it was; a log group is one message from one place,
  with where it was logged. It listens for a window, or with
  `watch_minutes` in the background, read by later calls and ended with
  `stop: true`. It also groups the errors in the start and the end of the
  node's log files (its logger handlers' files, and a release's
  `erlang.log.N`), which hold what happened before. Nothing is loaded on
  the node: a logger handler whose filter is evaluated code sends the
  events to a process there, and is removed when it ends, even if that
  process is killed.
- `crash_dump`: why a node died, from its `erl_crash.dump`, read in one
  pass, so dumps of gigabytes work. What the slogan means (out of memory
  and in which allocator, a permanent application that stopped, a full
  atom table, a failed boot, a signal), findings on what stands out, the
  process that was running, the biggest processes and longest mailboxes
  with their stacks and what proc_lib processes run, the first messages
  of the longest mailbox decoded, and memory, ETS, ports and atoms.
  `process:` shows one process in full. Dumps of OTP 26 to 29 are read;
  no connection is needed.
- `supervisor_restarts` points to `recent_errors` for children that crash
  less often than its sample catches.
- `examples/erlang/run.sh orders`: an orders service whose errors only its
  logs show; `examples/erlang/run.sh crash`: a node that runs out of
  memory within a minute and leaves a crash dump. CI smoke-tests the
  release against both. `docs/scenarios.md` has a scenario for each (7
  and 8; the ones after them are renumbered), and `docs/walkthroughs.md`
  a recorded session for each (9 and 10).

### Ports

- `ports` (in `diagnose`) tells what the ports are: by type (`tcp_inet`,
  external programs by command, drivers), the processes holding the most,
  the ports with data waiting to be written, with `owner_blocked` when the
  owner is stuck sending to a slow peer, and the external programs with
  their OS pids, OTP's own helpers apart. It also counts sockets of the
  `socket` module, which aren't ports.
- Snapshot diffs report `port_delta_by_type` and `port_delta_by_owner`:
  which kind of port grew, and which processes opened them, named.
- `socket_traffic` (in `diagnose`): the inet sockets moving the most bytes
  over a second, with peer and local address and owner.
- `port_info`: one port in detail. For a socket, its addresses, statistics
  (`send_pend`) and options (`active`, `packet`, buffers, watermarks); for
  an external program, its OS pid; its owner, links, I/O and queue.
- `trace_port`: a port's traffic (what its owner sends it, what it sends
  back, truncated), or with `opened: true` the ports opened and closed in
  a window, summed up by who opened them. Capped like `trace_calls`; in its
  own trace session on OTP 27+, refused before while others trace.
- `long_schedules` names the driver and owner of a port in its events.
- `examples/erlang/run.sh ports`: a shop that leaks sockets and external
  programs and fills a slow peer's socket. CI smoke-tests the release
  against it. `docs/scenarios.md` has a scenario for ports (now 12), and
  `docs/walkthroughs.md` an eighth recorded
  session against the demo.

### Native code

- `long_schedules` (in `diagnose`): over 2 seconds, the processes that
  held a scheduler for more than 10 ms without yielding, which is native
  code (a NIF or BIF), with each process's name, initial call and the
  longest and total time; plus garbage collections over 50 ms and
  processes suspended on busy ports. On OTP 28+ it runs in its own trace
  session (`trace:system/3`), so the node's `system_monitor` is left
  alone; before OTP 28 it uses `system_monitor`, and skips the check if
  another process holds it.
- `schedulers` also measures the dirty CPU and I/O schedulers, which dirty
  NIFs run on, and their run queues, and warns when the dirty CPU
  schedulers are saturated with work waiting.
- `native_memory` (in `diagnose`): the memory the OS charges the node
  against what the VM's allocators hold. The difference is memory NIFs and
  drivers allocate themselves, which `erlang:memory()` never shows.
  Snapshot diffs report its growth, `native_memory_delta_mb`, and
  `os_memory_delta_mb`. The OS's figure counts memory compressed or
  swapped out: macOS's physical footprint, `VmRSS` plus `VmSwap` on Linux.
  Resident memory alone can miss a leak under memory pressure, since
  leaked memory nobody touches is the first to be compressed or swapped.
- `native_code` (in `diagnose`): the native libraries in applications'
  `priv` directories, OTP's own apart, and the loaded port drivers.
- `module_code` marks NIFs: functions in `-nifs`, or whose stub calls
  `erlang:nif_error`, with a note that the code shown is only the stub.
- `examples/erlang/run.sh native`: an OTP application with a C NIF
  library whose `checksum/1` holds a scheduler for 80 ms and whose
  `parse/1` leaks 256 KB a call. CI smoke-tests the release against it.
  `docs/scenarios.md` has a scenario for native code (9; the ones after
  it are renumbered), and `docs/walkthroughs.md` a seventh recorded
  session against the demo.

### Other changes

- `module_code` labels each anonymous fn uniquely (`anonymous fn/1 in
  init/1 (fun-2)`), and takes a function as listed, as name/arity, or by
  its compiled name (`-init/1-fun-2-`), quoted or not. Compiled names
  with slashes used to be refused.
- The Erlang demos are compiled with debug info, as rebar3 builds are, so
  `module_code` shows their code as Erlang.
- `module_code`: what a module on the target really contains, including
  the functions macros generated, which its source doesn't show. It lists
  each function's origin: written in the module, or generated by a macro
  (which macro's module, the line that called it and, with `quote
  location: :keep`, the line in the macro). It shows a function's code
  after macro expansion, and which function a stack frame's `file:line` is
  in. It reads the module's `.beam` from the node's code path and decodes
  it here. With Elixir debug info, code is Elixir; with Erlang's, Erlang.
  A release strips debug info by default, and then the line table, which
  it keeps, still gives each function's file, and code is BEAM assembly.
  A node on a newer OTP than the server's disassembles its own `.beam`.
- A macro is listed and shown under the name its source gives it
  (`timed/2`, kind `defmacro`), not as the compiled `MACRO-timed/3`, with
  a note that its code after expansion is the code that builds what it
  returns. Function heads are formatted so a `[do: block]` argument stays
  an argument.
- `examples/elixir` has a billing demo (`run.sh billing`) whose routes are
  defined with a macro DSL, and whose `timed` macro records every charge
  twice: a bug that exists only after expansion. `docs/scenarios.md` has a
  scenario for code that macros generated, and `docs/walkthroughs.md` a
  fifth recorded session, finding that bug from the node alone.
- `examples/elixir/phoenix_shop` (`run.sh phoenix`): a Phoenix 1.8 JSON
  API whose product search always returns 404, because the `GET
  /products/:id` route that `resources` generates matches it first. The
  source never mentions `:id`, and it compiles without a warning;
  `module_code` shows the router's expanded `__match_route__/3` clauses
  in matching order.
- `module_code` reports a function some macros define without recording
  it as theirs, such as Phoenix.Router's `__match_route__/3`, as
  "probably a macro of" the macro called on the line it's defined on,
  rather than as written there.
- `docs/walkthroughs.md` has a sixth recorded session: the Phoenix demo's
  shadowed search route, found from the node alone.
- CI also tests against an OTP 29 node (`new_otp`): every check,
  `trace_calls`, `profile` and `module_code`.

## 0.5.0

Profiling by function with `profile`, a Docker image of the server, and
debugging nodes in Docker containers and Kubernetes pods.

### Profiling

- `profile`: where the CPU time goes on the target, by function. For one
  module, one function or one process (or, when asked, every module), it
  counts calls, own time and memory allocated per function over a short
  window (default 5s, at most 30s), with the runtime's call_time and
  call_memory counters, and ranks them, with the processes making the
  calls. On OTP 27+ it runs in its own trace session and never sees or
  disturbs other tracing; on older nodes it refuses while there is any,
  unless forced. It needs nothing from OTP's `tools` application, which
  releases usually leave out, and leaves no counters or trace flags
  behind. Anonymous functions are named as Elixir does
  (`anonymous fn/1 in MyMod.fun/1`). The smoke test profiles each demo.

### Docker and Kubernetes

- A Docker image of the server, `ghcr.io/ayarodionov/otp_debug_mcp`,
  for amd64 and arm64, published with each release (0.4.0 too) and
  smoke-tested against a node in another container first. The
  `Dockerfile` builds it from a published Linux release.
- `docs/production.md` covers nodes in Docker containers. Either run the
  image in a container that shares the app container's network, which
  needs no changes to the app and no published ports, or publish the
  node's distribution port and have the server dial it, configured for a
  Mix release by environment variables alone. There's a prompt that has
  Claude Code set up the first.
- Nodes in Kubernetes pods. The release has `bin/otp-debug-k8s`, which
  Claude Code runs as the MCP server: it starts the server as a pod in
  the app's namespace, from the release's Docker image, with the cookie
  from the app's Secret, and deletes the pod when the session ends, even
  if the session is stopped. `docs/production.md` has the set-up, the
  smallest Role it needs (no access to Secrets), and port forwarding.
  Tested on a kind cluster with nodes named by pod IP and by DNS name.
- The server can start distribution where the machine has no fully
  qualified host name, such as in a container or a pod. Connecting to a
  node with a long name used to fail there with `nodistribution`; the
  server now falls back to naming itself by the address it reaches the
  target from.

### Docs

- The README's Setup says how to stop, restart and remove the server:
  `/mcp`'s Reconnect and Disable in Claude Code, the commands that undo
  the install (including the `epmd` the server leaves running), and
  prompts that have Claude Code remove or upgrade it.

## 0.4.0

Trying a fix on the live node with `load_module`, only with the user's
approval each time, recorded walkthroughs, and installing with Claude
Code.

### Trying a fix on the live node

- `load_module`: hot-load a fixed module's `.beam` onto the target to try
  a fix, or `revert` to the node's own version. Every load asks the user
  in a dialog from their MCP client, with the md5 and path of the new code
  and of the version running now. That approval comes from the user, not
  the agent, and is needed even when the tool is allowed in the client's
  permissions. Clients that can't ask (no MCP 2026-07-28 form
  elicitation) get a refusal. The approval covers that exact code on that
  node: if the file changes, the user is asked again. Code still running
  is never purged, so no process is killed, and OTP's own modules aren't
  replaced.

### Docs

- `docs/walkthroughs.md`: four recorded sessions against the Elixir
  demos to follow along with (the mailbox that never drains, the crash
  loop, the cluster with one bad node, and trying the crash loop's fix on
  the node with `load_module`), each with the prompt, every tool call and
  its real result, trimmed, and the conclusion. The fix for the last one
  is in `examples/elixir/fixes/`.
- The install steps in the README work when pasted into zsh, macOS's
  default shell: a trailing `# comment` on a command line isn't a comment
  there, so the first line failed and the download addresses came out
  wrong. No shell example in the docs has an inline comment any more.
- The README's registration steps work for a build from source too: they
  used the downloaded release's `~/.local` paths only, which don't exist
  then (the server is `_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp`,
  the skill `skills/otp-debug` in the checkout). They also say what to do
  when `otp-debug` is already registered. `docs/clients.md` gives both
  paths.
- The README has an "Install with Claude Code" section: one prompt that
  has Claude Code download the release for your machine, verify its
  checksum, register it and install the skill, asking before each
  command.

## 0.3.0

Binary leaks through slices found by `diagnose`, LFE demo targets, and
setup guides for Cursor, GitHub Copilot and Claude Desktop.

### `diagnose` finds more

- `binary_leak` also lists the processes holding the most binary memory,
  and for the largest, samples the binaries in its state to tell slices
  pinning larger binaries (fix: `binary:copy/1`) from whole binaries
  piling up. Live references were invisible to it before: garbage
  collection frees nothing.

### Clearer output

- `process_info` takes quoted names (`'log-index'`), answers with the pid
  even when given a name, and reports the process's binary memory and,
  with `include_state`, a summary of the state's shape and size.
- Traced arguments and return values are cut at 300 characters each, so
  one big state doesn't fill every event.

### Safety

- `sys:get_state` is only sent to processes waiting in an OTP behaviour's
  loop (gen_server, gen_statem, gen_event) or a Gleam actor's: other
  processes may not understand it, and some crash on it.

### Demos and docs

- `examples/lfe`: demo targets in LFE (Lisp Flavoured Erlang).
- The Elixir demos moved from `scripts/` to `examples/elixir`, with a
  `run.sh` and README like the other languages' (nodes `shop_ex`,
  `payments_ex`, `ex_a`..`ex_c`, and the `demo_shop` release). `scripts/`
  now holds only test tooling. The README has a "Demo targets" section
  for all four languages.
- `docs/clients.md`: setting the tool up in Cursor, GitHub Copilot (VS Code
  and the CLI) and Claude Desktop, with commands that turn the playbook
  into a Cursor rule or Copilot instructions.

## 0.2.1

A faster `diagnose`, and a more exact measure of the tool's own footprint.

- `diagnose` runs its checks in parallel, in two phases, so the checks
  that measure load and atom growth don't see the others' work: about
  twice as fast on a node it has seen before (2 to 3 seconds instead of 4
  to 6), a little faster the first time.
- `atom_table` samples its second in two halves: growth in both is a
  steady leak, and only that can be critical; growth in one, such as a
  module loading, is a warning.
- The tool's own footprint is measured more exactly: atoms it sends that
  already exist on the node aren't counted, its first-time calls are
  measured one at a time (overlapping ones were double-counted), and the
  atom sample waits for them.

## 0.2.0

Whole clusters at once, `diagnose` catching atom and process leaks, and
Erlang and Gleam targets on an equal footing with Elixir ones.

### New

- `cluster`: every node of the target's cluster at once. `compare` puts key
  metrics side by side, flags the nodes that stand out from the others, and
  finds partitions (members that don't see each other); `diagnose` runs
  the full diagnose on every node; `snapshot_take` and `snapshot_diff` show
  which node grows. Members are discovered through each node's own view,
  so a node partitioned from the current target is still found.
  `connect` says when the node is in a cluster.
- Demo targets in plain Erlang/OTP (`examples/erlang`) and in Gleam with
  `gleam_otp` (`examples/gleam`), next to the Elixir ones, each with a bug
  to find. CI smoke-tests the release against all three.

### `diagnose` finds more

- `atom_table` measures atom growth over a second (not counting the tool's
  own atoms) and how long until the table is full: critical if within a
  day, a warning for any growth. It used to call a node leaking hundreds of
  atoms a second healthy.
- `process_count` measures growth over a second and the time until the
  process limit, and groups every process by initial call and current
  function, with a sample's stack for the largest groups: a process leak
  shows up as one big group whose stack names the code.

### Clearer output

- Terms from plain Erlang nodes (Erlang and Gleam) are shown in Erlang
  syntax; Elixir nodes keep Elixir syntax.
- Offender lists show the real initial call of proc_lib processes (every
  gen_server, supervisor, Gleam actor) instead of proc_lib's wrapper.
- `process_info` names the parent of a process no supervisor started and
  says nothing restarts it, says when state wasn't requested, and its age
  explanation says what the estimate rests on.
- `trace_calls` says what stopped it (`stopped_by`), and its timestamps
  are in UTC, marked `Z`, like snapshot times.
- Better advice: `message_queues` says to trace the sending side to find
  who floods a mailbox; `top_reductions` that a busy process matters even
  when the schedulers aren't saturated; `memory_breakdown` explains
  `other_system`; `allocator_fragmentation` marks `ll_alloc`'s slack as
  normal.

### Fixes

- Snapshot diffs no longer count modules a first trace loads (when it
  formats its first event) as the node's own growth.

### Tested

- Against a target on another machine, OTP 29, including the SSH tunnel
  and TLS recipes in `docs/production.md`.

## 0.1.0

The first release.

### Tools

- `connect`: attach to a running node as a hidden node, in shortnames or
  longnames mode, with a cookie from the call, `OTP_DEBUG_MCP_COOKIE`, or
  `~/.erlang.cookie`. Reconnects after a target restart. recon is loaded
  into targets that don't have it, compiled on the target when it runs an
  older OTP release, and never loaded over a copy the target already has.
- `diagnose` and `run_check`: message queues, supervisor restarts and
  crash loops (naming the restarting child, with its exit reason and stack
  trace), binary leaks, memory breakdown, allocator fragmentation, process,
  atom and port limits, ETS tables, scheduler usage and top reductions,
  ranked worst first, each with an interpretation.
- `process_info`: recon's process info, an estimate of the process's age
  (with a hard upper bound), its supervisor's restart history, and
  optionally its state.
- `supervision_tree`: an application's tree, with each supervisor's
  strategy and restart history.
- `trace_calls`: rate-limited call tracing with arguments, returns and
  exceptions. On OTP 27+ in an isolated trace session that never touches
  other tracing; before that through recon_trace, refusing to end someone
  else's tracing unless forced.
- `snapshot`: take and diff, excluding the atoms and code the tool itself
  adds to the node.
- `remote_eval`: Erlang evaluation on the target, off unless enabled.

### Safety

- The server's own node accepts no connections: no listening port,
  nothing registered with epmd, and a random cookie.
- Pids and ports appear in the target's own form in every tool.
- stdout carries only the MCP protocol; the target's IO is kept off it.

### Platforms

- Targets: Erlang/OTP 26 and later (tested on 26, 27 and 28), including
  over TLS distribution.
- Prebuilt releases for Linux (x86_64, arm64) and macOS (arm64), each
  bundling its own Erlang runtime.
