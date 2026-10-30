# Walkthroughs

Thirty-five debugging sessions against the demo nodes in `examples/`, start to
finish, for following along on your own machine. Each one gives the
command that starts the demo, the prompt, every tool call the agent made
with the part of its result that mattered, and the conclusion. The
results are real, recorded from Claude Code with the `otp-debug` skill
installed (OTP 28; Elixir and Erlang demos), trimmed to the fields that drove each
step. Numbers such as queue lengths, pids and restart counts will
differ on your run; what they show won't.

[docs/scenarios.md](scenarios.md) covers the same ground as a catalogue
of situations; these walkthroughs show what one session looks like.

Before you start: the server is registered and `/mcp` lists `otp-debug`
as connected (see [Setup](../README.md#setup)). In the commands below,
`yourhost` is the output of `hostname -s`.

Contents:

1. [A mailbox that never drains](#1-a-mailbox-that-never-drains)
2. [A crash loop under the restart limit](#2-a-crash-loop-under-the-restart-limit)
3. [One bad node in a cluster](#3-one-bad-node-in-a-cluster)
4. [Trying the fix on the live node](#4-trying-the-fix-on-the-live-node)
5. [Code that a macro generated](#5-code-that-a-macro-generated)
6. [A Phoenix route that macros shadowed](#6-a-phoenix-route-that-macros-shadowed)
7. [NIFs that block a scheduler and leak memory](#7-nifs-that-block-a-scheduler-and-leak-memory)
8. [Leaking sockets, a slow peer, and external programs](#8-leaking-sockets-a-slow-peer-and-external-programs)
9. [Errors only the logs show](#9-errors-only-the-logs-show)
10. [A node that died](#10-a-node-that-died)
11. [Two gen_servers that deadlock](#11-two-gen_servers-that-deadlock)
12. [What a Phoenix API serves, from its telemetry](#12-what-a-phoenix-api-serves-from-its-telemetry)
13. [Failures that nothing logs](#13-failures-that-nothing-logs)
14. [What's in an ETS table](#14-whats-in-an-ets-table)
15. [CPU spent collecting garbage](#15-cpu-spent-collecting-garbage)
16. [A fix deployed but never loaded](#16-a-fix-deployed-but-never-loaded)
17. [A link between nodes saturated](#17-a-link-between-nodes-saturated)
18. [A Bandit server out of connections](#18-a-bandit-server-out-of-connections)
19. [A riak_core cluster: a member down, a vnode swamped](#19-a-riak_core-cluster-a-member-down-a-vnode-swamped)
20. [riak_dt sets whose actors pile up](#20-riak_dt-sets-whose-actors-pile-up)
21. [A Cowboy server whose acceptors wait for room](#21-a-cowboy-server-whose-acceptors-wait-for-room)
22. [A Yaws API whose cookie sessions pile up](#22-a-yaws-api-whose-cookie-sessions-pile-up)
23. [A shackle pool with one connection held up](#23-a-shackle-pool-with-one-connection-held-up)
24. [Telemetry handlers attached per checkout](#24-telemetry-handlers-attached-per-checkout)
25. [Mnesia transactions waiting on one record](#25-mnesia-transactions-waiting-on-one-record)
26. [A Postgrex pool held through a payment call](#26-a-postgrex-pool-held-through-a-payment-call)
27. [Profiling a slow function, and tuning it](#27-profiling-a-slow-function-and-tuning-it)
28. [EMQX: a client that never acknowledges, and a client id shared](#28-emqx-a-client-that-never-acknowledges-and-a-client-id-shared)
29. [ejabberd: a bot that reads slowly, an archive on Mnesia, a full offline queue](#29-ejabberd-a-bot-that-reads-slowly-an-archive-on-mnesia-a-full-offline-queue)
30. [Ranch: dead connections keep new clients out](#30-ranch-dead-connections-keep-new-clients-out)
31. [A LiveView whose assigns keep growing](#31-a-liveview-whose-assigns-keep-growing)
32. [A container's CPU quota, and its memory limit](#32-a-containers-cpu-quota-and-its-memory-limit)
33. [Callers waiting behind one slow request](#33-callers-waiting-behind-one-slow-request)
34. [RabbitMQ: a memory alarm, a consumer with no prefetch, a queue nobody reads](#34-rabbitmq-a-memory-alarm-a-consumer-with-no-prefetch-a-queue-nobody-reads)
35. [Sockets: Nagle's delay, an active socket flooding its owner, a blocked export](#35-sockets-nagles-delay-an-active-socket-flooding-its-owner-a-blocked-export)
36. [Cleaning up](#cleaning-up)

---

## 1. A mailbox that never drains

```sh
examples/elixir/run.sh shop
```

> `shop_ex@yourhost` is getting slower and using more memory; find out why.

**`connect`**

```json
{"connected": "shop_ex@yourhost",
 "recon": {"version": "2.5.6", "source": "injected"}}
```

The node never shipped recon, so the tool loaded it for the session.

**`diagnose`**. The worst finding comes first:

```json
{"status": "critical", "check": "message_queues",
 "findings": [{"pid": "<0.107.0>", "queue_len": 1386454,
   "info": {"registered_name": "Shop.PriceCache",
            "current_function": "{Process, :sleep, 1}"}}]}
```

Everything else is `ok`, and two of those results narrow things down:

- `memory_breakdown`: `processes` is 78.8% of memory, so the memory is
  in a process, not in binaries or ETS.
- `top_reductions`: an unnamed process, `<0.108.0>`, runs at 425,264
  reductions a second, 180 times more than `Shop.PriceCache` itself. That
  is what a producer flooding a mailbox looks like.
- `schedulers` are almost idle: this isn't a CPU problem.

**`process_info(pid: "Shop.PriceCache")`**. `include_state` is left
off: a process with a million-message mailbox would answer the `sys` call
last.

```
current_stacktrace: [
  {Process, :sleep, 1, ...},
  {Shop.PriceCache, :handle_cast, 2, [file: ~c"examples/elixir/src/shop.exs", line: 12]},
  ...
memory: 308870680,
message_queue_len: 1633510,
```

The queue grew by about 250,000 messages since `diagnose`, a few seconds
earlier, and the process holds 309 MB. Every message waits on a sleep
in `handle_cast`, at line 12.

**`process_info(pid: "<0.108.0>")`**, the busy unnamed process:

```
initial_call: {:erlang, :apply, 2},
current_stacktrace: [
  {Process, :sleep, 1, ...},
  {Enum, :"-each/2-fun-0-", 3, ...},
  {Stream, :do_unfold, 4, ...},
```

A spawned loop over `Stream.iterate |> Enum.each`, with no supervisor:
the producer.

**`trace_calls(module: "Elixir.Shop.PriceCache", max_events: 10, duration_ms: 5000)`**

```
22:01:56.366750Z <0.107.0> 'Elixir.Shop.PriceCache':handle_cast({update,664,11664}, #{...})
22:01:56.372431Z <0.107.0> 'Elixir.Shop.PriceCache':handle_cast/2 --> {noreply,#{...}}
22:01:56.372557Z <0.107.0> 'Elixir.Shop.PriceCache':handle_cast({update,665,11665}, #{...})
22:01:56.378383Z <0.107.0> 'Elixir.Shop.PriceCache':handle_cast/2 --> {noreply,#{...}}
```

About 6 ms per update, so roughly 170 a second. The cache is on update
11,664 while more than 1.6 million wait behind it, and the keys repeat
(`rem(i, 1000)`): most queued updates overwrite one another.

**`snapshot(action: "take")`**, wait 30 seconds, **`snapshot(action: "diff")`**

```json
{"window_seconds": 44,
 "total_message_queue_delta": 1089014,
 "memory_delta_mb": {"processes": 91.35, "system": 16.62, "total": 107.97,
                     "binary": 0.0, "ets": 0.0, "atom": 0.0},
 "process_count_delta": 0, "atom_count_delta": 0}
```

Over 44 seconds, a million more messages and 108 MB more memory, all of
it in processes, with no new processes, atoms, binaries or ETS rows. One
snapshot was a guess; the diff is the evidence. The node had reached
1.37 GB by then.

**The answer.** `Shop.PriceCache` takes about 6 ms per update and gets
them by `GenServer.cast`, which never waits, from a producer sending
far faster. Its mailbox grows without bound, which is where the memory
goes, and any `GenServer.call` to it waits behind the whole queue,
which is why the node gets slower.

**Fixes.** Any one of these stops the growth. Which one fits depends on
whether the producer can afford to wait, and whether every update
matters or only the latest price.

- **Backpressure.** Send with `GenServer.call` instead of `cast`. The
  producer then waits for each update to finish, so it can never get
  ahead of the cache, and the mailbox holds at most one message per
  producer. The cost is the producer's throughput, here about 170
  updates a second. A call also times out after 5 seconds by default,
  so a cache that slows down shows up as errors in the producer instead
  of as memory, which is easier to notice.
- **Make the update cheap.** Whatever the 5 ms stands for (a database
  write, an HTTP request, a computation) doesn't belong in a process
  that every caller goes through. Hand it to a task
  (`Task.Supervisor.async_nolink/3`) or a worker pool. Or drop the
  GenServer and keep prices in a public ETS table, which the producer
  writes and readers read directly, with no process in between:

  ```elixir
  :ets.new(:prices, [:named_table, :public, read_concurrency: true, write_concurrency: true])
  :ets.insert(:prices, {sku, price})
  ```

- **Coalesce updates.** The producer cycles through 1,000 SKUs, so of
  the 1.6 million queued updates, every one but the newest for each SKU
  is overwritten anyway. Keep the latest price per SKU in a map, on the
  producer's side or in the cache (merging in `handle_cast` without
  doing the slow work), and flush it on a timer set with
  `Process.send_after/3`. The slow work then runs at most once per SKU
  per interval, however fast updates arrive.
- **Spread the work.** If every update really needs its 5 ms, run
  several caches and send each SKU to one of them, e.g. with
  `PartitionSupervisor` (Elixir 1.14 and later) and
  `{:via, PartitionSupervisor, {Shop.PriceCaches, sku}}`. N partitions
  handle N times the rate, and the updates for one SKU stay in order.
- **Let the consumer set the pace.** When updates come from a source you
  don't control, such as a message queue or a feed, GenStage or
  Broadway have consumers ask for work instead of having it pushed at
  them, and Broadway adds batching and concurrency settings.
- **Shed load.** If stale prices can be dropped, the producer can look
  at the mailbox first and skip the update when it's long:

  ```elixir
  {:message_queue_len, n} = Process.info(Process.whereis(Shop.PriceCache), :message_queue_len)
  if n < 10_000, do: GenServer.cast(Shop.PriceCache, {:update, sku, price})
  ```

  That's a safety valve, not a fix, and `Process.info/2` works only on
  local processes.

Whichever you choose, start the cache under a supervisor: here a script
starts it with a plain `start_link`, and `process_info` reported that
nothing would restart it. Also alert on its `message_queue_len`, so a
mailbox that starts growing again is noticed in minutes, not when the
node runs out of memory.

---

## 2. A crash loop under the restart limit

```sh
examples/elixir/run.sh payments
```

> `payments_ex@yourhost` fails payments now and then. Find out why.

**`connect`**, then **`diagnose`**. One finding isn't `ok`:

```json
{"status": "warning", "check": "supervisor_restarts",
 "findings": {"restarted": [{
   "supervisor": "Payments.Supervisor", "application": "payments",
   "strategy": "one_for_one", "max_restarts": 15, "max_seconds": 10,
   "restarts_in_window": 11, "at_limit": false,
   "last_restart_seconds_ago": 0,
   "restarting_children": [{
     "id": "Payments.Gateway",
     "pid_before": "<0.335.0>", "pid_now": "<0.473.0>",
     "exit_reason": "{badarg,[{erlang,binary_to_integer,[<<\"443x\">>],...},
       {'Elixir.Payments.Gateway',handle_info,2,
        [{file,\"examples/elixir/src/payments.exs\"},{line,26}]},...]}"}]}]}}
```

That's the whole diagnosis in one result:

- `Payments.Gateway` died and was restarted while the check watched it
  (`pid_before` → `pid_now`).
- It crashed with `badarg` from `binary_to_integer(<<"443x">>)`, at
  `payments.exs` line 26, in `handle_info/2`.
- 11 restarts in the last 10 seconds against a limit of 15: the
  supervisor never gives up, so nothing fails over and the crash shows
  up only as payments that fail now and then.

The other checks are all `ok`. `top_reductions` has
`Payments.Supervisor` at the top: that's the restart churn, not a CPU
problem.

**`supervision_tree(app: "payments")`** shows where the gateway sits and
what restarts with it:

```json
{"name": "Payments.Supervisor", "strategy": "one_for_one",
 "restarts": {"max_restarts": 15, "max_seconds": 10,
              "restarts_in_window": 10, "at_limit": false},
 "children": [{"id": "Payments.Gateway", "pid": "<0.288.0>", "type": "worker"},
              {"id": "Payments.Ledger", "pid": "<0.116.0>", "type": "worker"}]}
```

`one_for_one`, so `Payments.Ledger` is unaffected; only the gateway
restarts. Its pid and the restart count differ from the `diagnose`
result above because they change with every crash, about once a second.

**The answer.** The gateway reads its port from the URL
`https://pay.example.com:443x/v2` with a regex and calls
`String.to_integer("443x")`, which raises. It does that a second after
every start, so it crashes about once a second, just under the
supervisor's limit.

**Fixes.** The bad value is in the configuration and the crash is in the
code, so there's something to fix in both, and in how the failure
showed itself.

- **Correct the URL.** It comes from `GATEWAY_URL`, falling back to a
  default in `init/1`. Setting `GATEWAY_URL` to
  `https://pay.example.com:443/v2` and restarting the node stops the
  crashes at once, with no change to the code.
- **Parse it properly.** Use `URI.new/1`, which rejects this URL with
  `{:error, ":"}`. Don't use `URI.parse/1`: on this URL it quietly
  returns port 443, the default for `https`, so a mistyped port would
  go unnoticed and the gateway would connect to a port nobody
  configured. And cover a URL that parses but has no host:
  `URI.new("foo")` returns `{:ok, %URI{host: nil, ...}}`.

  ```elixir
  case URI.new(url) do
    {:ok, %URI{host: host, port: port}} when is_binary(host) -> {:ok, host, port}
    {:ok, _no_host} -> {:error, {:bad_gateway_url, url, :no_host}}
    {:error, part} -> {:error, {:bad_gateway_url, url, part}}
  end
  ```

- **Check the configuration at start, not a second later.** Here the
  URL is parsed in `handle_info/2`, after `init/1` has returned, so
  every start looks successful and the crash comes a second later.
  Parse it in `init/1` and return `{:stop, reason}` when it's bad, or
  check it in `config/runtime.exs`. Then the application refuses to boot
  with an error that names the URL, instead of running half-broken.
- **Don't crash on failures that aren't bugs.** A gateway that's
  unreachable or answers with an error is an expected condition: log
  it, retry with backoff (`Process.send_after/3` with a growing delay),
  and give callers `{:error, :gateway_unavailable}` instead of an exit
  from a process that's dead. Let it crash is for bugs; a supervisor
  restarting a process every second doesn't fix the network.
- **Make crash loops loud.** 15 restarts in 10 seconds is a generous
  limit. With the `Supervisor` defaults, 3 restarts in 5 seconds, this
  loop would have hit the limit within seconds and stopped the
  application: loud, instead of intermittent. Raise the limit only for
  faults you know are transient. Alert on crash reports too: each
  restart logs one, so counting them catches a loop that stays under
  the limit, as `diagnose`'s `supervisor_restarts` check did here.

---

## 3. One bad node in a cluster

```sh
examples/elixir/run.sh cluster
```

Three connected nodes run the same code; only `ex_b` has the shop bug.
Point the agent at a healthy one:

> `ex_a@yourhost` is part of a cluster that's getting slower. Find out
> why.

**`connect(node: "ex_a@yourhost")`**

```json
{"connected": "ex_a@yourhost",
 "cluster": {"hint": "This node is in a cluster; the cluster tool compares all its nodes.",
             "other_nodes": ["ex_b@yourhost", "ex_c@yourhost"]}}
```

The skill says to compare the cluster first when `connect` reports one.

**`cluster(action: "compare")`**. One row per node (trimmed), then the
outliers:

| Node | Processes memory | Total memory | Atoms | Largest mailbox |
|---|---|---|---|---|
| `ex_a` | 14.3 MB | 49.3 MB | 13,733 | 0 |
| `ex_b` | 64.8 MB | 113.4 MB | 20,506 | 514,353 (`Shop.PriceCache`) |
| `ex_c` | 14.3 MB | 49.3 MB | 13,733 | 0 |

```json
"outliers": [
  {"node": "ex_b@yourhost", "metric": "memory_processes_mb", "value": 64.8, "others_median": 14.3},
  {"node": "ex_b@yourhost", "metric": "atom_count", "value": 20506, "others_median": 13733.0},
  {"node": "ex_b@yourhost", "metric": "max_message_queue", "value": 514353, "others_median": 0.0}
],
"partitions": []
```

Every node sees the others, so there's no netsplit; `ex_b` stands out on
three metrics. The shop demo running there would explain the extra atoms
(compiling and loading its script) and the memory (its mailbox).
`diagnose` on `ex_b` tells which matters.

**`connect(node: "ex_b@yourhost")`**, then **`diagnose`**, and from
here the session is [walkthrough 1](#1-a-mailbox-that-never-drains):
`message_queues` is critical for `Shop.PriceCache`.

**The answer.** `ex_b` alone has the bug. On the healthy node you were
pointed at, `diagnose` would have found nothing.

**Fixes.** The fix for the code is the one in
[walkthrough 1](#1-a-mailbox-that-never-drains), deployed to every node.
A cluster adds questions of its own:

- **Why only one node?** When every node runs the same code, the
  difference is in what reaches them. Here, only `ex_b` runs the shop
  script. In production, look for load that isn't spread evenly: a
  singleton or a `:global`-registered process, sticky routing, a hot
  partition key, or a scheduled job that runs on one node. Also look
  for a node on a different configuration or release version.
  `cluster(action: "compare")` shows each node's `otp_release`.
- **Contain it while the fix ships.** Take `ex_b` out of the load
  balancer, or restart it to buy time. A restart empties the mailbox,
  but the queued updates are lost and the mailbox starts growing again.
- **Alert on outliers, not only on thresholds.** A node with four times
  the process memory of its peers is worth a look before it crosses any
  absolute limit. Comparing each node with the median of the others,
  as `cluster compare` does, catches this early.

---

## 4. Trying the fix on the live node

This one picks up where [walkthrough 2](#2-a-crash-loop-under-the-restart-limit)
ends: the crash is found, and there's a fix to try on the node before
it's deployed. `examples/elixir/fixes/payments_gateway.ex` is that fix,
the `Payments.Gateway` from the demo with its URL parsed by `URI.new/1`.
A bad URL is logged, and the gateway stays up instead of crashing. Start
the demo and compile the fix:

```sh
examples/elixir/run.sh payments
elixirc -o _build/payments_fix examples/elixir/fixes/payments_gateway.ex
```

> `payments_ex@yourhost` crash-loops in Payments.Gateway: the port in its
> URL is malformed. I've compiled a fix to
> `_build/payments_fix/Elixir.Payments.Gateway.beam`. Try it on the node
> and check that the crashes stop.

**`connect`**, then **`diagnose`**, as in walkthrough 2:
`supervisor_restarts` has `Payments.Gateway` dying on
`binary_to_integer(<<"443x">>)` at `payments.exs` line 26, with 11
restarts in the window against a limit of 15. The agent said it was
about to load the fix, that an approval dialog would come, and that the
load lasts only until the node restarts.

**`load_module(path: ".../Elixir.Payments.Gateway.beam")`**. Nothing is
loaded yet. The tool asks Claude Code to show you a form:

```
MCP server "otp-debug" requests your input
Load new code for Payments.Gateway on payments_ex@yourhost?
New code: md5 13d019f38b7e547daf963f6a44724b0e, .../_build/payments_fix/Elixir.Payments.Gateway.beam
Running now: md5 efd7f714cf290664ba674b7ab72ad7d0, no file: compiled in memory
❯ * Load it: ☐
      Every process at once, until the node restarts
  Accept    Decline
```

The md5s say exactly which code replaces which. "No file" is because the
demo compiles its modules from an `.exs` script, in memory. Tick the box
(Space) and accept. Claude Code then repeats the call with your answer,
and only then does the code load:

```json
{"loaded": "Payments.Gateway", "node": "payments_ex@yourhost",
 "md5": "13d019f38b7e547daf963f6a44724b0e",
 "replaced": {"md5": "efd7f714cf290664ba674b7ab72ad7d0",
              "file": "no file: compiled in memory"},
 "lasts": "until the node restarts: its files aren't changed. The node has no
   Payments.Gateway on its code path, so revert can't undo it; a restart does."}
```

Declining, or pressing Esc, loads nothing, and the agent is told not to
ask again unless you say so. That holds even though `load_module` was
allowed in Claude Code's permissions in this session: the form comes from
the server, every time.

**`run_check(check: "supervisor_restarts")`**, three seconds later:

```json
{"supervisor": "Payments.Supervisor", "restarts_in_window": 8,
 "last_restart_seconds_ago": 3, "restarting_children": []}
```

No child died during the 2-second sample. The 8 restarts are the old
ones, still inside the 10-second window.

**`process_info(pid: "Payments.Gateway", include_state: true)`**

```
pid: "<0.568.0>", status: :waiting,
current_stacktrace: [{:gen_server, :loop, 5, ...}, ...]
message_queue_len: 0
state: %{
  error: {:bad_gateway_url, "https://pay.example.com:443x/v2"},
  url: "https://pay.example.com:443x/v2"
}
```

The gateway that started after the load ran the new code. It rejected the
URL, recorded the error, and is idle.

**`run_check(check: "supervisor_restarts")`** again, nine seconds after
the last restart: `restarts_in_window` is down to 2, and still nothing
restarting. The crash loop is over.

**The answer.** The fix stops the crashes. Payments still don't go
through, because `GATEWAY_URL` is still wrong: the gateway now says so
in its state and its log instead of dying every second. The agent's
summary also noted:

- The load is temporary. Restarting the node brings back the old code,
  and so the crash loop, until the fix is deployed.
- Here, `revert` can't undo it. The original was compiled in memory, so
  the node has no copy of it on its code path, and only a restart goes
  back. For a module loaded from a release's or a Mix project's `.beam`
  files, `load_module(revert: "Payments.Gateway")` reloads that version,
  again only once you approve.

**Fixes.**

- **Deploy the fix.** Put it in the source, here
  `examples/elixir/src/payments.exs`, and deploy as usual. Loading it was
  a way to check it on the real node, not a release.
- **Correct the URL as well.** The fix makes a bad URL visible instead of
  fatal, but only the right value makes payments work. See walkthrough 2.
- **Cover every result of the parse.** An earlier version of this fix
  matched `{:ok, %URI{host: host}} when is_binary(host)` and
  `{:error, _}` only. The agent pointed out that `URI.new("foo")`
  succeeds with no host, which neither clause matches, so the gateway
  would crash again on a URL like that. The fix now handles anything
  that isn't a URL with a host as a bad one.

---

## 5. Code that a macro generated

```sh
examples/elixir/run.sh billing
```

`billing_ex` is a small billing service whose routes are defined with a
macro DSL, `Billing.Router`: `route "/charge" do ... end` defines a clause
of `Billing.API.handle/2`, and `timed "charge" do ... end` runs a block and
logs it if it's slow. A client charges account `acme` 10 every 200 ms.
`run.sh` compiles `src/billing.ex` to `.beam` files rather than running it
as a script, so `module_code` can read them.

> `billing_ex@yourhost` records every charge twice: acme's balance is
> double what was charged. Find out why.

This session was recorded with only the otp-debug tools allowed, so the
agent couldn't read the source: everything it found came from the node.

**`connect`**, then **`diagnose`**. Every check is `ok`. Nothing crashes,
queues or leaks: the bug is in what the code does, not in how the node
runs.

**`module_code(module: "Billing.Client")`** and **`"Billing.Ledger"`**. Each
function's origin: the ones written in `billing.ex`, and the six callbacks
`use GenServer` generated (`"generated_by": "a macro of GenServer"`). The
agent read the client's `handle_info/2` and the ledger's `record/2` and
`handle_call/3`: the client calls `Billing.API.handle("/charge", ...)`
once per tick, and the ledger records what it's given. Both are right.

**`module_code(module: "Billing.API")`**. Its only function is generated:

```json
{"function": "handle/2", "clauses": 3, "kind": "def",
 "generated_by": "a macro of Billing.Router",
 "called_at": "examples/elixir/src/billing.ex:45"}
```

**`module_code(module: "Billing.API", function: "handle/2")`**, the code
that runs, after macro expansion:

```elixir
def handle("/charge", req) do
  {micros, _} = :timer.tc(fn -> Billing.Ledger.record(req.account, req.amount) end)

  case :erlang.>(micros, 50000) do
    false -> nil
    true -> IO.puts(:stderr, <<"charge"::binary, " took ", ...>>)
  end

  Billing.Ledger.record(req.account, req.amount)
end

def handle("/balance", req) do
  Billing.Ledger.balance(req.account)
end

def handle(_path, _req) do
  {:error, :not_found}
end
```

`Billing.Ledger.record/2` is in the `"/charge"` clause twice: once inside
`:timer.tc`, and again at the end. The source of the route has it once.
The third clause is the catch-all that `__before_compile__` adds.

**`module_code(module: "Billing.Router", function: "timed/2")`**. The
macro, listed as `"kind": "defmacro"` at `billing.ex:26`. Its code after
expansion is the code that builds what it returns, its `quote` already
expanded into tuples, and the agent read from it that `block` goes in
twice:

```elixir
defmacro timed(label, [do: block]) do
  {:__block__, [],
   [
     {:=, [], [{{:micros, [], Billing.Router}, {:_, [], Billing.Router}},
               {{:., [], [:timer, :tc]}, [], [{:fn, [], [{:->, [], [[], ...block]}]}]}]},
     {:if, ...},
     :elixir_quote.shallow_validate_ast(block)
   ]}
end
```

**`trace_calls(module: "Billing.Ledger", function: "record", max_events: 8)`**
confirms it on the live node: two calls from the client for every tick.

```
17:18:06.688182Z <0.103.0> 'Elixir.Billing.Ledger':record(<<"acme">>, 10)
17:18:06.688634Z <0.103.0> 'Elixir.Billing.Ledger':record/2 --> ok
17:18:06.688640Z <0.103.0> 'Elixir.Billing.Ledger':record(<<"acme">>, 10)
17:18:06.688819Z <0.103.0> 'Elixir.Billing.Ledger':record/2 --> ok
17:18:06.889186Z <0.103.0> 'Elixir.Billing.Ledger':record(<<"acme">>, 10)
```

**`process_info(..., include_state: true)`** on both: the client counts
1970 charged, and the ledger holds about 400 entries of 10 for `acme`. Its
list of 10s prints as `~c"\n\n\n..."`, because a list of 10s is also a
charlist of newlines.

**The answer.** The `timed` macro runs the block it wraps twice: once
inside `:timer.tc` to time it, discarding the result, and once more to
return the result. Every route wrapped in `timed` runs its body twice,
and `/charge` writes to the ledger twice. The bug isn't in any route's
source: it exists only after expansion.

**Fixes.**

- **Run the block once.** Keep the result `:timer.tc` already returns:

  ```elixir
  defmacro timed(label, do: block) do
    quote do
      {micros, result} = :timer.tc(fn -> unquote(block) end)
      if micros > 50_000, do: IO.puts(:stderr, "#{unquote(label)} took #{micros} us")
      result
    end
  end
  ```

  Every module that uses `timed` has the second call compiled in, so it
  needs recompiling too: here `Billing.API`. (The agent offered to try the
  fixed `Billing.API` on the node with `load_module`.)
- **Unquote each argument once.** A macro that puts the same `unquote` in
  two places evaluates that expression twice, side effects included. Bind
  it once (`value = unquote(expr)`) and use the variable.
- **Test what a macro generates, not just its result.** A test that
  checks `handle("/charge", ...)` returns `:ok` passes with this bug. One
  that counts the ledger entries after a request, or checks
  `Macro.expand_once/2` of a `timed` call, catches it.
- **Correct the data.** Charges already recorded stay doubled, for every
  account charged through a `timed` route.

---

## 6. A Phoenix route that macros shadowed

```sh
examples/elixir/run.sh phoenix
```

`phoenix_ex` runs `phoenix_shop`, a small Phoenix 1.8 JSON API, on port
4040, with a built-in shopper that calls it over HTTP every 500 ms. Its
router:

```elixir
scope "/api", PhoenixShopWeb do
  pipe_through :api

  resources "/products", ProductController, only: [:index, :show]
  get "/products/search", ProductController, :search
end
```

> `phoenix_ex@yourhost` runs a Phoenix API. Product search
> (`GET /api/products/search?q=...`) always returns 404 "product not
> found", but opening a product (`GET /api/products/2`) works. Find out
> why.

As in walkthrough 5, only the otp-debug tools were allowed: the agent saw
the node, not the source.

**`connect`**, then **`diagnose`**: every check `ok`. A 404 isn't a crash,
so nothing on the node looks wrong.

**`module_code(module: "PhoenixShopWeb.Router")`** (after a first guess at
the name, `PhoenixEx.Router`, that the node doesn't have). Nearly every
function in it comes from Phoenix's macros:

```json
{"function": "__match_route__/3", "clauses": 4, "kind": "def",
 "generated_by": "probably a macro of Phoenix.Router",
 "called_at": "lib/phoenix_shop_web/router.ex:2",
 "note": "the debug info doesn't name the macro, but it's defined on the line where Phoenix.Router's macro was called"}
{"function": "call/2", "generated_by": "a macro of Phoenix.Router",
 "called_at": "lib/phoenix_shop_web/router.ex:2",
 "macro_code_at": "deps/phoenix/lib/phoenix/router.ex:468"}
{"function": "api/2", "generated_by": "a macro of Phoenix.Router",
 "called_at": "lib/phoenix_shop_web/router.ex:4"}
```

`__match_route__/3` is the function Phoenix generates from the routes:
one clause per route, tried in order. `api/2` is the `:api` pipeline.

**`module_code(module: "PhoenixShopWeb.Router", function: "__match_route__/3")`**,
trimmed to each clause's head and route:

```elixir
def __match_route__("GET", ["api", "products"], _) do
  {%{route: "/api/products", plug_opts: :index, ...}, ...}
end

def __match_route__("GET", ["api", "products", arg0], _) do
  {%{route: "/api/products/:id", plug_opts: :show, path_params: %{"id" => arg0}, ...}, ...}
end

def __match_route__("GET", ["api", "products", "search"], _) do
  {%{route: "/api/products/search", plug_opts: :search, ...}, ...}
end

def __match_route__(_verb, _path, _host) do
  :error
end
```

The second clause matches any third segment, `"search"` included, so the
third can never run. That second clause is the `show` route `resources`
generated: the router's source never mentions `:id`.

**`trace_calls(module: "PhoenixShopWeb.ProductController", max_events: 20)`**
catches the shopper's next search, trimmed to the action and its params:

```
<0.526.0> 'Elixir.PhoenixShopWeb.ProductController':show(#{...}, #{<<"id">> => <<"search">>,<<"q">> => <<"lamp">>})
<0.526.0> 'Elixir.PhoenixShopWeb.ProductController':show/2 --> #{..., status => 404, ...}
```

`search/2` is never called.

**The answer.** `resources "/products", ..., only: [:index, :show]`
generates `GET /api/products/:id`, and it comes before
`get "/products/search"` in the router, so it matches `/api/products/search`
first. Search requests reach `show` with `id: "search"`, which finds no
such product and returns 404. `GET /api/products/2` works because `"2"` is
a real id.

**Fixes.**

- **Put the specific route first.** Move
  `get "/products/search", ProductController, :search` above the
  `resources` line. The agent, which couldn't see the source, suggested
  replacing `resources` with three explicit `get` routes in that order,
  which also works.
- **Check the routes as Phoenix expands them.** `mix phx.routes` lists
  them in matching order, with `/api/products/:id` above
  `/api/products/search`. This bug compiles without a warning, so that
  list, or a test that requests `/api/products/search` and expects 200, is
  what catches it.
- **Watch for it with every generated route.** A `:id` route shadows
  any literal path with the same verb and the same number of segments
  declared after it. `resources` generates them for `show`, `update`
  and `delete`, so `GET /products/:id` shadows `GET /products/search`,
  and `DELETE /products/:id` would shadow a `DELETE /products/all`.

---

## 7. NIFs that block a scheduler and leak memory

```sh
examples/erlang/run.sh native
```

`native_erl` runs `native_shop`, an Erlang application with a C NIF
library, `priv/native_nif.so`, built with the system's C compiler. Two
workers call its NIFs: `native_pricing` calls `native_nif:checksum/1` every
300 ms, and `native_ingest` calls `native_nif:parse/1` every 100 ms.

> `native_erl@yourhost` stalls for tens of milliseconds now and then, and
> the OS says it uses more memory every minute, though erlang:memory()
> doesn't change. Find out why.

Only the otp-debug tools were allowed, so the agent couldn't read the C
code: everything came from the node.

**`connect`**, then **`diagnose`**. The checks for native code:

```json
{"check": "long_schedules", "status": "critical",
 "findings": {"via": "its own trace session", "watched_ms": 2000,
   "long_schedules": [{"name": "native_pricing", "pid": "<0.91.0>",
     "initial_call": "{native_shop_worker,init,1}",
     "times": 4, "max_ms": 118, "total_ms": 445,
     "scheduled_in": "{gen_server,loop,5}", "scheduled_out": "{gen_server,loop,5}"}],
   "long_gcs": [], "busy_ports": []}}
{"check": "native_memory",
 "findings": {"os_memory_bytes": 118670128, "os_memory_measure": "phys_footprint",
   "vm_allocated_bytes": 84525056, "erlang_memory_total_bytes": 49571748,
   "outside_vm_bytes": 34145072}}
{"check": "native_code",
 "findings": {"native_libraries": [{"app": "native_shop", "files": ["priv/native_nif.so"]}],
   "otp_apps_with_native_libraries": ["crypto"],
   "loaded_drivers": ["tcp_inet", "udp_inet", "ram_file_drv"]}}
```

`native_pricing` held a scheduler for up to 118 ms at a time, 445 ms of
the 2 s window. Erlang code yields within a millisecond, so this is native
code. `schedulers` agreed: one normal scheduler 24% busy, the other nine
idle, the dirty schedulers unused. `native_code` shows the one native
library outside OTP. The agent took a snapshot to watch memory.

**`module_code`** on the workers' modules. `native_shop_worker` runs a
`Fun` it's given on a timer, and `native_shop_sup:init/1` shows which:

```erlang
[Worker(native_pricing, 300, fun() -> native_nif:checksum(Order) end),
 Worker(native_ingest, 100, fun() -> native_nif:parse(Record) end)]
```

and `module_code(module: "native_nif")` marks both as NIFs:

```json
{"function": "checksum/1", "nif": "native code: the module's NIF library replaces this function when it loads"}
{"function": "parse/1", "nif": "native code: the module's NIF library replaces this function when it loads"}
```

**`trace_calls(module: "native_nif", max_events: 20)`** times the calls,
and shows the stall:

```
18:39:36.559620Z <0.92.0> native_nif:parse/1 --> 1024
18:39:36.655341Z <0.91.0> native_nif:checksum(<<11,250,21,...>>)
18:39:36.762290Z <0.91.0> native_nif:checksum/1 --> 6584402008498996368
18:39:36.762369Z <0.92.0> native_nif:parse(<<39,78,0,...>>)
18:39:36.762790Z <0.92.0> native_nif:parse/1 --> 1024
```

`checksum/1` took 107 ms. `parse` is due every 100 ms, but its next call
came 203 ms after the previous one, 79 µs after `checksum` returned: it
was waiting for the scheduler `checksum` held. Every process on that
scheduler waits the same way. `parse/1` itself takes about 0.5 ms.

**`snapshot(diff)`**, 16 s after the first snapshot:

```json
{"window_seconds": 16, "os_memory_delta_mb": 36.05, "native_memory_delta_mb": 35.8,
 "memory_delta_mb": {"total": 0.04, "binary": 0.01, ...},
 "process_count_delta": 0, "atom_count_delta": 0}
```

36 MB more memory outside the VM in 16 s, about 2.5 MB/s, while
`erlang:memory()` grew 0.04 MB. A second diff, over 4 s, gave 10.5 MB.
`native_memory` a minute after the first reading showed 111 MB outside the
VM, up from 34 MB.

**The answer.** Both symptoms come from `native_nif.so`:

- `checksum/1` runs for around 100 ms on a normal scheduler without
  yielding. Every process on that scheduler stalls for as long, which is
  the "tens of milliseconds now and then".
- Native memory grows about 2.5 MB/s: memory the library allocates and
  never frees, which `erlang:memory()` can't see.

The agent couldn't tell which NIF leaks, and said so. Native memory is a
total for the node, and both NIFs run all the time. It worked out what
each would leak per call if it were the one: about 250 KB for `parse/1`,
or 780 KB for `checksum/1`. (It's `parse/1`, at 256 KB a call.) It offered
to call each NIF on its own through `remote_eval` and compare, which needs
your approval because it leaks more memory on the node.

**Fixes.**

- **Don't block a normal scheduler.** A NIF should return within about
  1 ms. Run `checksum` as a dirty CPU NIF (`ERL_NIF_DIRTY_JOB_CPU_BOUND`
  in its `ErlNifFunc` entry), or split the work and yield with
  `enif_schedule_nif`, using `enif_consume_timeslice` to know when.
- **Free what the NIF allocates.** In `parse`, the buffer from `malloc` is
  never freed. Free it before returning, or use `enif_alloc`/`enif_free`;
  for data that outlives the call, a resource whose destructor frees it.
- **Find the leaking NIF before production.** Run each NIF in a loop in a
  test under AddressSanitizer or Valgrind, or OTP's `asan` emulator
  (`-emu_type asan`): they report the allocation that's never freed.
- **Watch native memory.** A snapshot diff with `native_memory_delta_mb`
  growing and `memory_delta` flat is a native leak, which
  `erlang:memory()`-based monitoring never alerts on.

---

## 8. Leaking sockets, a slow peer, and external programs

```sh
examples/erlang/run.sh ports
```

`ports_erl` runs `ports_shop`, which talks to an upstream on the same
node. Three processes misuse ports: `ports_client` connects to the
upstream for every request, `ports_feed` streams to it over one
connection, and `ports_thumbnailer` starts an external program for every
job.

> `ports_erl@yourhost`'s port count keeps climbing, and one of its
> connections stops sending now and then. Find out why.

Only the otp-debug tools were allowed.

**`connect`**, then **`diagnose`**. `ports` says what the ports are, and
whose:

```json
{"check": "ports", "status": "warning",
 "findings": {"count": 361,
   "by_type": [{"type": "tcp_inet", "count": 300}, {"type": "external: cat", "count": 59},
               {"type": "external: inet_gethost", "count": 1}, {"type": "forker", "count": 1}],
   "top_owners": [{"owner_name": "ports_client", "ports": 147, "types": {"tcp_inet": 147}},
                  {"owner_name": "ports_thumbnailer", "ports": 59, "types": {"external: cat": 59}}],
   "write_queues": [{"owner_name": "ports_feed", "port": "#Port<0.7>", "type": "tcp_inet",
                     "peer": "127.0.0.1:52893", "queued_bytes": 7552540,
                     "owner_blocked": "in {prim_inet,send,4}, until the port takes more data"}],
   "external_programs": {"count": 59, "otp_helpers": 1,
                         "running": [{"command": "cat", "os_pid": 80771, "owner": "<0.90.0>"}, ...]}}}
```

Three leads at once. `ports_client` holds 147 sockets and
`ports_thumbnailer` 59 copies of `cat`, both after 45 seconds of
uptime. `ports_feed` is stuck sending, with 7.5 MB queued for its peer.
`inet_gethost` is OTP's own DNS helper, counted apart. `process_count` is
growing 4 a second, and `socket_traffic`'s busiest socket is the
upstream's end of the feed, receiving 36,864 bytes a second; the feed's
own socket isn't in it, since it sent nothing while blocked.

**`snapshot(take)`**, then **`port_info(port: "#Port<0.7>")`**, the
feed's socket:

```json
{"kind": "socket", "name": "tcp_inet", "queue_bytes": 6931440, "output_bytes": 9559116,
 "socket": {"peer": "127.0.0.1:52893", "local": "127.0.0.1:52894",
   "stats": {"send_pend": "6931440", "send_oct": "9555000", "recv_oct": "0"},
   "options": {"active": "false", "high_watermark": "8388608", "low_watermark": "4096",
               "send_timeout": "infinity", "sndbuf": "343596"}},
 "owner_process": {"name": "ports_feed", "current_function": "{prim_inet,send,4}", "status": "waiting"}}
```

The socket queues up to its 8 MB high watermark before sends block, and
then they stay blocked until it drains to the 4 KB low watermark, with no
`send_timeout` to give up.

**`module_code(module: "ports_shop")`**, then each function in turn. With
debug info, the agent read the bugs directly: `client/1` connects and
drops the socket (`{ok, _Socket} = gen_tcp:connect(...)`), `thumbnailer/1`
opens a port and drops it (`_ = open_port({spawn, "cat"}, [])`),
`feed_loop/2` sends 65,000 bytes every 50 ms, and the upstream's
`read_slowly/1` reads 4,096 bytes every 100 ms, about 40 KB a second.

**`trace_port(opened: true, duration_ms: 3000)`** confirms the leaks live,
summed up by who opened what:

```json
{"opened": 9, "closed": 0, "backend": "isolated trace session",
 "opened_by": [{"owner_name": "ports_client", "ports": 6, "what": {"tcp_inet": 6}},
               {"owner_name": "ports_thumbnailer", "ports": 3, "what": {"cat": 3}}]}
```

```
19:28:18.796385Z #Port<0.640> open <0.90.0> cat
19:28:18.836048Z #Port<0.641> open <0.88.0> tcp_inet
19:28:18.836641Z #Port<0.642> getting_linked <0.1149.0>
```

The third event is the upstream's end of the new connection, handed to a
new reader process.

**`snapshot(diff)`**, 13 s after the first:

```json
{"window_seconds": 13, "port_count_delta": 161,
 "port_delta_by_type": {"tcp_inet": 134, "external: cat": 27},
 "port_delta_by_owner": [{"owner_name": "ports_client", "ports_added": 67, "ports_now": 277},
                         {"owner_name": "ports_thumbnailer", "ports_added": 27, "ports_now": 111}],
 "process_count_delta": 67}
```

161 more ports in 13 seconds, none closed: 67 sockets from `ports_client`,
67 more at the upstream's end, and 27 programs.

**The answer.**

- `ports_client` opens a TCP connection every 200 ms and never closes it.
  Each one also leaves a port and a reader process at the upstream's end,
  since the reader only stops when the connection closes: that's the
  process count growing too.
- `ports_thumbnailer` starts `cat` every 500 ms and never closes the port,
  so OS processes pile up.
- `ports_feed` sends about 1.3 MB/s to a peer that reads 40 KB/s. The
  socket fills to its 8 MB high watermark in seconds, then sends block
  until the reader drains it to 4 KB, which at 40 KB/s takes over three
  minutes: the connection that "stops sending now and then".

**Fixes.**

- **Close what you open.** `gen_tcp:close/1` when a connection is done, or
  keep one connection, or a pool, and reuse it; `port_close/1` for an
  external program once its job is done. A process that owns sockets or
  ports and lives on keeps all of them open.
- **Match the producer to the consumer.** A send that can block for
  minutes stalls its process. Read faster or in larger chunks on the other
  end, send less, or set `{send_timeout, T}` with
  `{send_timeout_close, true}` so a stuck peer is dropped instead of
  silently stalling the sender.
- **Watch ports by type and owner.** A rising port count says little;
  `port_delta_by_type` and `port_delta_by_owner` in snapshot diffs name
  the leak, and alerting on them catches it early.

---

## 9. Errors only the logs show

```sh
examples/erlang/run.sh orders
```

`orders_erl` runs `orders`, an OTP application that keeps working while
it fails, and logs to `examples/erlang/log/orders_erl.log`. Nothing it
does shows in the numbers: no queue builds up, nothing leaks.

> `orders_erl@yourhost` loses some of the orders it imports, and payments
> fail now and then, but its numbers look healthy. Find out why.

Only the otp-debug tools were allowed. The session took a minute.

**`connect`**, then **`diagnose`**. Everything is ok but
`supervisor_restarts`, which caught the importer dying during its sample:

```json
{"check": "supervisor_restarts", "status": "warning",
 "findings": {"restarted": [{"supervisor": "orders_sup", "max_restarts": 10, "max_seconds": 10,
   "restarts_in_window": 5, "at_limit": false,
   "restarting_children": [{"id": "orders_importer",
     "exit_reason": "{badarg,[{erlang,binary_to_integer,[<<\"n/a\">>],...},{orders_importer,parse_line,1,[...,{line,26}]},..."}]}]}}
```

That's the import, but not the payments. **`recent_errors`** with
`duration_ms: 15000` listens to the node's logger, and reads its log file:

```json
{"listened_ms": 15000, "events": 38, "by_level": {"error": 26, "warning": 12},
 "groups": [
   {"kind": "crash", "level": "error", "who": "orders_importer", "reason": "badarg",
    "events": 24, "processes": 8, "supervisor": "orders_sup",
    "reports": {"gen_server terminated": 8, "crash report": 8, "supervisor report": 8},
    "stack": ["erlang:binary_to_integer/1",
              "orders_importer:parse_line/1 (examples/erlang/src/orders_importer.erl:26)",
              "orders_importer:handle_info/2 (examples/erlang/src/orders_importer.erl:18)", ...],
    "called_with": "[<<\"n/a\">>]"},
   {"kind": "log", "level": "error", "events": 2,
    "message": "payment for order 2074 failed: {provider,timeout}",
    "logged_at": "orders_payments:charge/3 (examples/erlang/src/orders_payments.erl:24)"},
   {"kind": "log", "level": "warning", "events": 12,
    "message": "payment provider slow: 597 ms for order 2073",
    "logged_at": "orders_payments:charge/3 (examples/erlang/src/orders_payments.erl:26)"}],
 "log_files": [{"file": ".../examples/erlang/log/orders_erl.log", "read": "all of it",
   "matching_entries": 127,
   "groups": [
     {"level": "error", "entries": 1,
      "first": "2026-10-24T16:45:13.748480-04:00 error: pricing rules: couldn't read priv/pricing_rules.csv (enoent); every order is charged its list price"},
     {"level": "error", "entries": 27, "first": "... error: Generic server orders_importer terminating. Reason: {badarg,..."},
     {"level": "error", "entries": 27, "first": "... error: crasher: initial call: orders_importer:init/1, ..."},
     {"level": "error", "entries": 27, "first": "... error: Supervisor: {local,orders_sup}. Context: child_terminated. ..."},
     {"level": "warning", "entries": 42, "first": "... warning: payment provider slow: 659 ms for order 2004"},
     {"level": "error", "entries": 3, "first": "... error: payment for order 2032 failed: {provider,timeout}"}]}]}
```

Eight crashes in 15 seconds, by eight processes: one, restarted each
time. Each crash logs three reports, grouped into one with the bad
argument. Payments fail on a timeout, and the provider is slow on about
every other charge, each logged from a known line. And at the top of the
log file, once, from before anything listened: the pricing rules never
loaded.

**`module_code`** for `orders_importer` and `orders_payments`, then
`handle_info`, `parse_line`, `init` and `charge`: one batch of four lines,
`<<"1003;n/a;7.50">>` among them, parsed in one list comprehension;
`imported` counted in the state, which starts at 0. **`supervision_tree`**
for `orders` confirms `one_for_one` with 10 restarts in 10 seconds.

**The answer.**

- **Lost imports.** `parse_line/1` calls `binary_to_integer/1` on the
  quantity, and one line has `n/a` there: `badarg`. The batch is parsed in
  one list comprehension, so one bad line crashes the importer and loses
  the batch's three good orders too, and the restarted importer tries the
  same batch again. It crashes 5 or 6 times in 10 seconds, under the
  supervisor's limit of 10, so it never gives up, and nothing fails over:
  27 crashes in the log since boot. The `imported` counter starts at 0 on
  every restart, so it has never shown a single import.
- **Failed payments.** `charge/3` logs a timeout on about one charge in
  ten, and `handle_info` moves on to the next order whatever happened: a
  failed charge is never retried.
- **From the boot log.** The pricing rules were never read
  (`enoent`), and the node carried on with list prices: nothing else shows
  it.

**Fixes.**

- **Handle bad input per line.** Have `parse_line` return
  `{ok, Order}` or `{error, Line}`, keep the good orders, and log the bad
  lines; and find what sends `n/a` as a quantity.
- **Retry or queue a failed charge** instead of moving on.
- **Read files from `code:priv_dir(orders)`**, not a relative `priv/`, and
  decide whether starting without pricing rules should be an error.

---

## 10. A node that died

```sh
examples/erlang/run.sh crash
```

`crash_erl` runs `events_shop`, and may use only 300 MB. It dies within a
minute, writing `examples/erlang/dumps/crash_erl.dump` (128 MB); this one
lasted 28 seconds. Once it's gone (`pgrep -f crash_erl` finds nothing),
ask:

> `crash_erl` died a minute after it started. It left a crash dump at
> `~/prj/otp_debug_mcp/examples/erlang/dumps/crash_erl.dump`. Find out why
> it died.

Only the otp-debug tools were allowed. No node to connect to: the session
took 23 seconds.

**`crash_dump`** on the dump:

```json
{"slogan": "eheap_alloc: Cannot allocate 128 bytes of memory (of type \"heap_frag\").",
 "cause": {"kind": "out_of_memory",
   "explanation": "The VM asked the OS for 128 more bytes (heap_frag, from eheap_alloc) and didn't get them, so it stopped. The node had 252.4 MB. A process heap was growing: one process's data or mailbox got too big."},
 "findings": [
   "<0.87.0> (events_writer) held 74% of the node's memory (185.8 MB), with 1055805 messages in its mailbox",
   "<0.87.0> (events_writer) had 1055805 messages waiting: it couldn't keep up with what it was sent"],
 "memory_mb": {"total": 252.4, "processes": 195.8, "binary": 0.0, "ets": 0.4, "code": 4.8},
 "running_when_it_died": {"process": "<0.88.0>", "name": "events_source", "state": "Running",
   "current_function": "events_shop:'-source/2-lc$^0/1-0-'/4", "stack": ["events_shop:source/2"]},
 "processes": {"count": 49,
   "top_memory": [
     {"pid": "<0.87.0>", "name": "events_writer", "memory_mb": 185.8, "share_of_memory": 74,
      "message_queue_len": 1055805, "reductions": 89844, "state": "Scheduled",
      "current_function": "timer:sleep/1", "stack": ["events_shop:writer/1"]},
     {"pid": "<0.50.0>", "name": "code_server", "memory_mb": 0.3},
     {"pid": "<0.88.0>", "name": "events_source", "memory_mb": 0.1, "reductions": 2767058}]},
 "largest_mailbox": {"name": "events_writer", "message_queue_len": 1055805,
   "first_messages": [
     "{event,clicks,11951,#{at => 1792874821321,user => 227,page => <<\"/products\">>}}",
     "{event,clicks,11952,#{at => 1792874821321,user => 228,page => <<\"/products\">>}}", ...]},
 "atoms": {"count": 10147, "limit": 1048576, "percent": 1}}
```

Out of memory, and one process held three quarters of it, all in its
mailbox. The writer was sleeping, from `writer/1`; the process the VM
was running when it died was `events_source`, sending, with 30 times the
writer's reductions. The oldest event waiting is number 11,951: the
writer had stored about 1% of what it was sent. Then **`crash_dump`** with
`process:` for each of the two shows their spawn and heap details, and
the writer's first messages again.

**The answer.** `events_source` sent events to `events_writer` far
faster than the writer stores them (it sleeps between events), with
nothing slowing the sender down. The writer's mailbox grew to a million
events, about 180 bytes each, until the node's 250 MB were gone. Nothing
else was big: ETS, binaries and atoms were small.

**Fixes.**

- **Make the source wait for the writer:** a `gen_server:call`, or an
  acknowledgement per batch, instead of a plain send; or check the
  writer's queue length and slow down or drop when it's too long.
- **Make the writer faster:** take events in batches, without a sleep
  per event.
- **Have the dump outlive the node:** in production, point
  `ERL_CRASH_DUMP` at a volume, or a restarted container takes the
  evidence with it.

---

## 11. Two gen_servers that deadlock

```sh
examples/erlang/run.sh locks
```

`locks_erl` runs `locks_shop`: `locks_stock` reserves items for 20
shoppers, and asks `locks_pricing` for each item's price; `locks_pricing`
refreshes its prices every 3 seconds, asking `locks_stock` for levels.

> Shoppers on `locks_erl@yourhost` say their reservations all time out
> now, though it worked when it started. Find out why.

Only the otp-debug tools were allowed. The session took 48 seconds.

**`connect`**, then **`diagnose`**. Everything is ok but `call_chains`,
critical:

```json
{"check": "call_chains", "status": "critical",
 "findings": {"waiting_now": 22, "waiting_over_1s": 22, "by_kind": {"call": 22},
   "deadlocks": [[
     {"process": "<0.87.0>", "name": "locks_stock", "initial_call": "{locks_stock,init,1}",
      "waits_on": "a call to locks_pricing (<0.88.0>)", "call": "gen_server:call/3",
      "request": "{price,3}", "timeout": "infinity",
      "message_queue_len": 120, "also_waiting_on_it": 20},
     {"process": "<0.88.0>", "name": "locks_pricing", "initial_call": "{locks_pricing,init,1}",
      "waits_on": "a call to locks_stock (<0.87.0>)", "call": "gen_server:call/3",
      "request": "{level,0}", "timeout": "infinity", "message_queue_len": 1}]],
   "chains": [], "most_waited_on": []}}
```

`locks_stock` is in a call to `locks_pricing` for the price of item 3;
`locks_pricing` is in a call to `locks_stock` for the level of item 0.
Neither can answer the other, and with timeout infinity, neither ever
gives up. All 20 shoppers wait on `locks_stock` too, and the 120
messages in its mailbox are their timed-out reservations.

**`module_code`** for both modules' `handle_call`, `locks_pricing`'s
`handle_info` and `init`, and `locks_shop`'s `shopper`, and
**`process_info`** on `locks_pricing`, show where the two calls are made
and when: `handle_call({reserve, Item}, ...)` sleeps 20 ms, then calls
pricing; `handle_info(refresh, ...)`, every 3 seconds from `init`, calls
stock once per item; the shoppers call stock with a 5-second timeout,
caught.

**The answer.** The first 3 seconds work, because there's no refresh
yet. Each refresh is a race: if it starts while stock is in a
reservation, pricing calls stock while stock calls pricing, and both wait
forever. With 20 shoppers, stock is almost always in a reservation, so
an early refresh deadlocks them. From then on every reservation times
out, quietly, since the shoppers catch it. Neither process is
supervised, so nothing recovers: a restart would only start the race
again.

**Fixes.**

- **Don't call back into a process from its callee.** Have stock push
  levels to pricing with a cast when they change, or keep them in an ETS
  table pricing reads, so pricing never calls stock.
- **Or don't call pricing from stock's callbacks**: look the price up
  before the reservation, or read prices from ETS.
- **Use real timeouts** instead of infinity: a deadlock then becomes a
  crash that a supervisor restarts and the logs show, instead of a hang
  (it doesn't remove the race).

---

## 12. What a Phoenix API serves, from its telemetry

```sh
examples/elixir/run.sh phoenix
```

The Phoenix demo of walkthrough 6, without saying what's wrong: this time
the question is what the node does.

> `phoenix_ex@yourhost` is a Phoenix API. Tell me what requests it's
> serving right now, how fast, and whether anything looks wrong.

Only the otp-debug tools were allowed. The session took a minute.

**`connect`**, then **`diagnose`**: all ok. Then **`telemetry`** for
15 seconds, without naming events: it listened to those the node's
handlers listen to (Phoenix's logger) and the known events of the
libraries running there (Phoenix, Bandit):

```json
{"listened_ms": 15000, "events_seen": 180,
 "by_event": [
   {"event": "bandit.request.stop", "count": 60, "total_ms": 48.3,
    "groups": [
      {"key": "GET /api/products/search", "count": 30,
       "duration_ms": {"p50": 1.01, "p95": 1.44, "max": 1.68},
       "slowest": {"ms": 1.68, "metadata": "%{conn: %{status: 404, method: \"GET\", request_path: \"/api/products/search\", ...}}"}},
      {"key": "GET /api/products/:id", "count": 30,
       "duration_ms": {"p50": 0.62, "p95": 0.88, "max": 1.07},
       "slowest": {"ms": 1.07, "metadata": "%{conn: %{status: 200, method: \"GET\", request_path: \"/api/products/2\", ...}}"}}]},
   {"event": "phoenix.router_dispatch.stop", "count": 60, "total_ms": 25.8,
    "groups": [
      {"key": "GET /api/products/:id", "count": 60,
       "duration_ms": {"p50": 0.43, "p95": 0.65, "max": 0.7},
       "slowest": {"ms": 0.7, "metadata": "%{route: \"/api/products/:id\", plug: PhoenixShopWeb.ProductController, plug_opts: :show, conn: %{status: 404, request_path: \"/api/products/search\", ...}}"}}]}],
 "exceptions": [],
 "not_seen": ["bandit.request.exception", "phoenix.endpoint.stop", "phoenix.router_dispatch.exception", ...]}
```

Two kinds of request, 30 each, all fast. But the server sees two paths,
and the router only one route: all 60 were dispatched to
`/api/products/:id`, action `show`, including the searches, which all
answered 404.

**`module_code`** for the router and the controller, then the router's
`__match_route__/3` and the controller's `show/2`; **`process_info`** on
`PhoenixShop.Shopper`, the process on the node making the requests, whose
state counts `%{{:show, 200} => 120, {:search, 404} => 120}`: every
search it ever made failed.

**The answer.** The router matches `GET /api/products/:id` before
`GET /api/products/search`, so `search` is taken as an id; `show/2`
can't parse it as an integer and answers 404 "product not found". The
search action is never called, nothing raises, nothing is logged: it
shows only as 404s, and in telemetry as a route that doesn't match its
path.

**Fix.** In the router, put `get "/products/search", ...` before
`get "/products/:id", ...`.

---

## 13. Failures that nothing logs

```sh
examples/erlang/run.sh orders
```

The orders demo of walkthrough 9 has one more service, `orders_coupons`,
which applies a coupon code every 300 ms, and logs nothing.

> Customers of `orders_erl@yourhost` say some coupon codes give them no
> discount, but nothing about coupons is in the logs. Find which codes,
> and why.

Only the otp-debug tools were allowed. The session took 47 seconds.

**`connect`**, **`diagnose`** (the importer's crash loop of walkthrough
9, nothing about coupons), **`supervision_tree`** for `orders`, and
**`process_info`** on `orders_payments` and `orders_coupons`: the coupon
service is fine, its state a counter. **`module_code`** for
`orders_coupons`, then `handle_info/2` and `discount/1`:

```erlang
_Percent = try discount(Code) catch _:_ -> 0 end,

discount(<<"SAVE", Percent/binary>>) ->
    binary_to_integer(Percent).
```

Any failure becomes a 0% discount, silently. Which codes fail?
**`trace_calls`** on `orders_coupons:discount` with `exceptions: true`,
for 5 seconds, reports only the calls that raise:

```json
{"backend": "isolated trace session", "stopped_by": "duration",
 "events": [
   "21:52:46.229104Z <0.95.0> orders_coupons:discount(<<\"SPRING-15\">>)",
   "21:52:46.229116Z <0.95.0> orders_coupons:discount/1 raised error:function_clause",
   "21:52:46.831120Z <0.95.0> orders_coupons:discount(<<\"save15\">>)",
   "21:52:46.831133Z <0.95.0> orders_coupons:discount/1 raised error:function_clause",
   "21:52:47.734289Z <0.95.0> orders_coupons:discount(<<\"SPRING-15\">>)",
   "21:52:47.734303Z <0.95.0> orders_coupons:discount/1 raised error:function_clause",
   ...]}
```

Two codes, again and again; the calls with `SAVE10`, `SAVE5` and `SAVE20`
returned and weren't reported.

**The answer.** `SPRING-15` and `save15` give no discount. `discount/1`
matches only codes written exactly `SAVE<number>`: `SPRING-15` doesn't
start with `SAVE`, and `save15` is lowercase. Both fail with
`function_clause`, and the `catch _:_ -> 0` turns that into no discount
without a word. A code like `SAVEX` would fail the same way, with
`badarg`.

**Fixes.**

- **Look codes up**, in a table of code to percent, rather than parsing
  them; at least normalize their case first.
- **Don't swallow errors silently.** Log the code and the error before
  falling back to no discount, so the next bad code shows up in
  `recent_errors` and the logs.

---

## 14. What's in an ETS table

```sh
examples/erlang/run.sh sessions
```

`sessions_erl` runs `sessions`: a gen_server that records each login in
the `sessions` ETS table, with a process logging in a random user every
2 ms.

> The memory of `sessions_erl@yourhost` keeps growing. Find out why.

Only the otp-debug tools were allowed. The session took 53 seconds.

**`connect`**, then **`diagnose`**. `atom_table` is critical:

```json
{"check": "atom_table", "status": "critical",
 "findings": {"count": 24879, "limit": 1048576, "growth_per_second": 332.9,
              "growing_throughout": true, "seconds_until_full": 3075}}
```

333 new atoms a second, steadily: the node dies in 51 minutes. The
largest table in `ets_tables` is `sessions`, with 10,072 rows. And the
`logs` check notes that the node writes its logs to the console only, so
nothing from before the session is kept.

**`snapshot`**, then **`ets_table`** on `sessions`:

```json
{"table": "sessions", "type": "set", "protection": "protected", "named_table": true,
 "owner": {"pid": "<0.87.0>", "name": "sessions", "current_function": "{gen_server,loop,5}"},
 "rows": 16573, "memory_bytes": 1196344,
 "first_rows": ["{session_6910_90341,6910,1793027576}", "{session_1660_110626,1660,1793027595}",
                "{session_3372_159717,3372,1793027582}", ...],
 "scanned": {"rows": 10000, "of": 16573, "complete": false,
             "average_row_bytes": 32, "largest_row_bytes": 32}}
```

6,500 more rows in a few seconds. Every key is an atom made from a user
id and a unique number, and the rows are all alike, 32 bytes: no row
stands out, so no `largest` list. The growth is the number of rows.

**`module_code`** for `sessions` and its `handle_call`, `traffic` and
`handle_cast`, and **`process_info`** on `<0.88.0>`, the traffic
process:

```erlang
handle_call({login, UserId}, _From, Table) ->
    Id = integer_to_list(UserId) ++ "_" ++ integer_to_list(erlang:unique_integer([positive])),
    Session = list_to_atom("session_" ++ Id),
    ets:insert(Table, {Session, UserId, erlang:system_time(second)}),
    {reply, Session, Table}.
```

**`snapshot` `diff`**, 8 seconds after the first: `atom_count_delta`
+2,699 (the tool's own 325 atoms excluded), ETS +0.23 MB.

**The answer.** Every login makes a new atom for its session id, and
atoms are never collected: the atom table fills in under an hour, and
the node crashes with `system_limit`. And no code deletes a session or
expires one, so the table grows by a row a login.

**Fixes.**

- **Don't make atoms from runtime data:** a binary or a reference as
  the session id.
- **Bound the table:** delete a session on logout, and expire old ones
  on a timer with `ets:select_delete/2`.
- **Restart once the fix is deployed:** the atoms already made stay
  until then.

---

## 15. CPU spent collecting garbage

```sh
examples/erlang/run.sh reports
```

`reports_erl` runs `reports`: two workers work out the day's total again
and again. Each pass lists every sale as a tuple, 100,000 of them, sorts
the list by price, and adds the prices up.

> `reports_erl@yourhost` uses a lot of CPU for what it does: it only adds
> up the day's sales. Find out where the CPU goes.

Only the otp-debug tools were allowed. The session took 40 seconds.

**`connect`**, then **`diagnose`**. `scheduler_time` is a warning: it
says what the busy schedulers spend their time on.

```json
{"check": "scheduler_time", "status": "warning",
 "findings": {"gc_share_of_work": 0.419, "gc_schedulers": 0.89, "window_ms": 2000,
   "by_thread_type": {
     "scheduler": {"threads": 10, "busy": 0.118,
                   "work": {"emulator": 0.913, "gc": 0.0, "other": 0.084, "aux": 0.002, "check_io": 0.001, "port": 0.0}},
     "dirty_cpu_scheduler": {"threads": 10, "busy": 0.094,
                   "work": {"gc": 0.946, "other": 0.053, "emulator": 0.001, "aux": 0.0, "check_io": 0.0, "port": 0.0}}}}}
```

The normal schedulers run Erlang code (`emulator`), and the dirty CPU
schedulers, where the VM collects large heaps, do almost nothing but
collect garbage: 42% of all the schedulers' work, nearly a whole
scheduler's time (`gc_schedulers` 0.89). `schedulers` showed two normal
schedulers half busy, the rest idle, and `top_reductions` the two
`report_worker_N` processes at 170 million reductions a second each,
sampled in `lists:rkeymerge3_1`, the merge step of `lists:keysort`.

**`profile`** on `reports` for 3 seconds:

```json
{"total": {"calls": 88390745, "time_us": 5948068, "memory_bytes": 5347373232},
 "by_time": [
   {"function": "reports:-daily_total/1-lc$^1/1-1-/4", "percent": 40.3, "calls": 44258500, "memory_bytes": 1062204000},
   {"function": "reports:daily_total/1", "percent": 32.9, "calls": 220, "memory_bytes": 3931101232},
   {"function": "anonymous fn/2 in reports:daily_total/1", "percent": 14.3, "calls": 22002333, "memory_bytes": 0}, ...]}
```

220 reports in 3 seconds, allocating 5.3 GB: 24 MB a report.
`daily_total/1`'s own share, with the sort in `lists` counted under it,
allocated 3.9 GB of that.

**`module_code`** for `reports`, `daily_total/1` and `loop/1`, and
**`process_info`** on a worker:

```erlang
loop(I) ->
    _Total = daily_total(I),
    loop(I).

daily_total(Seed) ->
    Sales = [{Item, Qty, Qty * 3} || Item <- lists:seq(1, 100000), Qty <- [Item rem 7 + Seed]],
    ByPrice = lists:keysort(3, Sales),
    lists:foldl(fun({_, _, Price}, Sum) -> Sum + Price end, 0, ByPrice).
```

**The answer.** Each report builds 100,000 tuples, sorts them into a
second list, and adds them up: a sum doesn't depend on the order, so the
sort and the lists are garbage made for nothing, and collecting it takes
almost a scheduler of its own. And the workers recompute a total that
doesn't change, dozens of times a second, throwing each result away.

**Fixes.**

- **Compute it when it's needed:** on request, or on a timer, keeping
  the result, instead of in a loop.
- **Add up in one pass:** a fold over `lists:seq/2`, or a counting loop,
  without the tuples and without the sort: each report then allocates
  almost nothing.

---

## 16. A fix deployed but never loaded

```sh
examples/erlang/run.sh deploy
```

`deploy_erl` runs `deploy_shop`: an order every second, each taking
`discounts`' 5% off. After the node starts, `run.sh` compiles the fix, 10%
off, into `deploy/ebin`, as a deploy that copies files would, and loads
nothing. It also loads `heartbeat` again, as `l(heartbeat)` in a remote
shell would, while its process loops.

> We deployed a fix to `deploy_erl@yourhost`: discounts are 10% now, not
> 5%. Orders still get 5%. Find out why.

Only the otp-debug tools were allowed. The session took 41 seconds.

**`connect`**, then **`diagnose`**. Everything is ok but `stale_code`:

```json
{"check": "stale_code", "status": "warning",
 "findings": {
   "different_on_disk": [
     {"module": "discounts", "on_disk": "modified",
      "file": ".../examples/erlang/deploy/ebin/discounts.beam"}],
   "modules_with_old_code": 1,
   "old_code": [
     {"module": "heartbeat", "processes_in_it": 1,
      "some": [{"pid": "<0.88.0>", "registered_name": "heartbeat",
                "current_function": "{heartbeat,loop,1}"}]}]}}
```

The `discounts.beam` on the code path isn't the code running. And one
process, `heartbeat`, still runs the previous version of its module.

**`module_code`** for `discounts` reads the file on disk, and says so:

```json
{"module": "discounts",
 "loaded": "differs: the version running isn't this file's (it was hot-loaded), so this may not be the code that runs",
 "beam_file": ".../examples/erlang/deploy/ebin/discounts.beam",
 "source": ".../examples/erlang/deploy/discounts.erl"}
```

The file's `handle_call/3` takes 10% off. To see what the running code
does, **`trace_calls`** on `discounts:handle_call/3`:

```
discounts:handle_call({apply,128}, ...) --> {reply,122,#{}}
discounts:handle_call({apply,129}, ...) --> {reply,123,#{}}
discounts:handle_call({apply,130}, ...) --> {reply,124,#{}}
```

128 less 5% is 122; less 10% would be 116. **`process_info`** on
`discounts` and `module_code` on `deploy_shop:orders/0` cleared the
callers: `orders` calls `discounts:apply/1` by its module name, and the
server has nothing queued and no restarts.

**The answer.** The deploy copied the new `discounts.beam` to disk and
stopped there. A node runs the code it has loaded until the module is
loaded again or the node restarts, so it still takes 5% off. Separately,
`heartbeat`'s loop calls itself locally, so it never picks up a newer
version, and the next load of `heartbeat` will kill it.

**Fixes.**

- **Load the new code now:** `l(discounts)` in a remote shell, or
  `code:purge(discounts), code:load_file(discounts)`. `gen_server` calls
  `discounts:handle_call/3` by module name, so the running server takes
  the new code on its next call, and its state needs no conversion.
- **Make the deploy load what it copies:** a release upgrade with an
  appup, a load step after the copy, or a restart; and check afterwards
  that nothing differs from disk (`code:modified_modules()`, or
  `diagnose`'s `stale_code`).
- **Write loops that pick up new code:** `heartbeat`'s should call
  itself as `?MODULE:loop(N + 1)`.

---

## 17. A link between nodes saturated

```sh
examples/erlang/run.sh dist
```

`dist_a` and `dist_b` are connected. `dist_a`'s `catalog` process sends
the whole product catalog to `mirror` on `dist_b` ten times a second;
`dist_a`'s `checkout` calls `dist_b`'s stock server for every order.

> The network link between `dist_a@yourhost` and `dist_b@yourhost` is
> saturated. Find out what's using it.

Only the otp-debug tools were allowed. The session took 35 seconds.

**`connect`** to `dist_a`, then **`run_check(distribution)`**:

```json
{"check": "distribution", "status": "ok",
 "findings": {"node": "dist_a@yourhost", "busy_limit_bytes": 1048576, "net_ticktime_s": 60,
   "connections": [
     {"node": "dist_b@yourhost", "type": "normal", "state": "up", "controller": "port #Port<0.6>",
      "sent_bytes_per_s": 17051312, "received_bytes_per_s": 1872, "pending_bytes": 0},
     {"node": "otp_debug_mcp_74465@yourhost", "type": "hidden", "this_tool": true, ...}]}}
```

17 MB a second to `dist_b`, under 2 KB back. **`diagnose`** names who
sends it: `long_schedules` caught one process suspended on that
connection again and again.

```json
{"check": "long_schedules", "status": "warning",
 "findings": {"busy_ports": [
   {"kind": "busy_dist_port", "times": 19, "port": "#Port<0.6>",
    "pid": "<0.93.0>", "name": "catalog", "initial_call": "{dist_shop,catalog,1}"}]}}
```

19 times in 2 seconds, `catalog` filled the connection's buffer past its
1 MB busy limit and was suspended until it drained.

**`process_info`** on `catalog`: unsupervised, 92 seconds old, 54 million
reductions, a 20 MB heap. **`module_code`** for `dist_shop`, its
`catalog/1`, `mirror/0` and `checkout/1`:

```erlang
Items = [{Id, <<"product ", ...>>, Id rem 100, lists:seq(1, 20)} || Id <- lists:seq(1, 40000)],
Loop = fun L(V) -> {mirror, B} ! {catalog, V, Items}, timer:sleep(100), L(V + 1) end
```

**The answer.** `catalog` builds the catalog once and then sends all of
it, about 1.9 MB, ten times a second: the 17 to 19 MB/s measured. The
catalog never changes, and `mirror` on `dist_b` throws each copy away.
All traffic between two nodes shares one connection, so `checkout`'s
calls to `dist_b` wait in line behind these messages, and a slower link
would delay the nodes' heartbeats too.

**Fixes.**

- **Send changes, not the whole thing:** the full catalog once, then a
  version number or the items that changed, with a resync when the
  receiver sees a gap.
- **Or stop sending it,** if `dist_b` doesn't use it: `mirror` ignores it.
- **Keep bulk transfers off the cluster link:** a separate socket or
  file transfer, so calls between the nodes don't queue behind them.

---

## 18. A Bandit server out of connections

```sh
examples/elixir/run.sh bandit
```

`bandit_ex` runs a Plug API on Bandit (`examples/elixir/bandit_shop`),
whose connections someone capped at 100: 4 acceptors with 25 each. Its
traffic is built in: 30 clients asking for recommendations, which wait 3
seconds on a slow upstream inside the request, and 120 browsing products
on keep-alive connections.

> Some clients of `bandit_ex@yourhost` get their connections reset, or
> wait seconds before the first byte, but the request times Bandit
> reports look fine and nothing is logged. Find out why.

Only the otp-debug tools were allowed. The session took 42 seconds.

**`connect`**, then **`diagnose`**: nothing wrong with the node itself,
schedulers near idle, no queues, no crashes.

**`bandit`** with `duration_ms: 10000`:

```json
{"status": "critical",
 "findings": [
   "critical: 8 connections refused in 10000 ms: the connection limit was reached (nothing logs this)",
   "warning: 127.0.0.1:4050: 100 of 100 connections in use",
   "warning: 127.0.0.1:4050: 4 of 4 acceptors are waiting for room for a new connection: meanwhile new clients wait unaccepted, and are refused if no room comes",
   "warning: 127.0.0.1:4050: 30 connections busy in BanditShop.Recommender.upstream_call/0"],
 "servers": [{
   "listening": "127.0.0.1:4050", "serves": "BanditShop.Router", "acceptors": 4,
   "connections": {"active": 100, "limit": 100, "per_acceptor_limit": 25, "fullest_acceptor": 25,
                   "acceptors_waiting_for_room": 4},
   "idle": 70, "reading": 0, "sending": 0, "handling": 30,
   "waiting_in": [{"connections": 30, "current_function": "Process.sleep/1",
                   "in_your_code": "BanditShop.Recommender.upstream_call/0"}],
   "timeouts_ms": {"read": 60000, "handshake": 5000, "shutdown": 15000}}],
 "window": {
   "listened_ms": 10000, "requests": 3550, "requests_per_s": 355.0, "by_status": {"2xx": 3550},
   "refused_connections": 8, "new_connections_per_s": 0.0,
   "slowest_routes": [
     {"route": "GET /recommendations -> 200", "count": 120, "p50_ms": 3000.88, "p95_ms": 3001.78},
     {"route": "GET /products/:id -> 200", "count": 3430, "p50_ms": 0.06, "p95_ms": 0.22}]}}
```

The server is full, and every acceptor is stuck waiting for a slot: new
clients wait unaccepted in the listen queue, and when an acceptor's
retries run out, Thousand Island closes the socket. Eight such resets in
10 seconds, and not one new connection served. 70 slots are idle
keep-alives, 30 are requests waiting on the recommender's upstream. The
requests that do get in are all 200, and fast but for
`/recommendations`.

**The answer.** The slow `/recommendations` upstream call holds a
connection for 3 seconds a request, and idle keep-alives hold the rest,
for up to `read_timeout`, a minute. Together they fill the 100-connection
limit, so new clients wait to be accepted (the slow first byte) or are
refused (the reset). Bandit's request times can't show it: a client's
wait to be accepted comes before Bandit starts timing its request, and a
refused connection never becomes a request. Thousand Island emits a
telemetry event when it refuses one, and logs nothing.

**Fixes.**

- **Raise the limit:** `thousand_island_options: [num_connections: ...]`
  in the Bandit (or Phoenix endpoint) config. It's per acceptor, and the
  default is 16,384: connections are cheap processes.
- **Free idle connections sooner:** a shorter `read_timeout`, or a cap on
  requests per connection in Bandit's `http_1_options`.
- **Take the slow call off the request:** a timeout with a fallback for
  the upstream, or a cached result.
- **Watch for it:** alert on `[:thousand_island, :acceptor, :spawn_error]`
  and on connections near the limit, since nothing logs them.

---

## 19. A riak_core cluster: a member down, a vnode swamped

```sh
examples/elixir/run.sh riak
```

`riak_a`, `riak_b` and `riak_c` run a shop on riak_core
(`examples/elixir/riak_shop`, on riak_core_lite): carts in `shop_vnode`,
one per partition of a 16-partition ring. `run.sh` forms the cluster,
waits for its handoffs, stops `riak_c`, and starts the traffic on
`riak_a`: 20 shoppers adding to their own carts, and a flash sale where
everyone adds to the same cart. Adding an item takes its vnode 5 ms.

> Writes to our riak_core shop cluster (`riak_a@yourhost`,
> `riak_b@yourhost`, `riak_c@yourhost`) have got slow, and some time
> out. Find out why.

Only the otp-debug tools were allowed. The session took 37 seconds.

**`connect`** to `riak_a`, then **`riak_core`**:

```json
{"status": "critical",
 "findings": [
   "critical: riak_c@yourhost is a valid member, owning 5 partitions, but this node isn't connected to it",
   "critical: riak_core_status:ringready can't reach riak_c@yourhost",
   "warning: 5 fallback vnodes run here for partitions of riak_c@yourhost: their writes wait here for hinted handoff",
   "warning: vnode :shop_vnode 91343852333181432387730302044767688728495783936 (primary) on riak_b@yourhost has 8852 messages in its mailbox, close to the overload threshold of 10000, past which its proxy refuses requests to it",
   "warning: :riak_shop isn't up on riak_c@yourhost"],
 "cluster": {"claimant": "riak_a@yourhost", "num_partitions": 16, "members": [
   {"node": "riak_a@yourhost", "status": "valid", "reachable": true, "owns": 6, "claimant": true, "this_node": true},
   {"node": "riak_b@yourhost", "status": "valid", "reachable": true, "owns": 5},
   {"node": "riak_c@yourhost", "status": "valid", "reachable": false, "owns": 5}]},
 "vnodes": {"by_module": {":shop_vnode": {"total": 11, "primary": 6, "fallback": 5}}},
 "cluster_busiest_vnodes": [
   {"node": "riak_b@yourhost", "module": ":shop_vnode", "role": "primary",
    "partition": "91343852333181432387730302044767688728495783936",
    "pid": "<riak_b@yourhost.244.0>", "queue": 8852, "proxy_queue": 0}],
 "cluster_views": {"ringready": "{:error, {:nodes_down, [:\"riak_c@yourhost\"]}}"}}
```

Two problems at once. `riak_c` is down while still a member owning 5
partitions: `riak_a` holds 5 fallback vnodes for it. And on `riak_b`,
one vnode has nearly 9,000 commands queued, nearing riak_core's overload
threshold. **`cluster`** agreed: `riak_b`'s largest mailbox stood out, and
`riak_c` was unreachable.

**`connect`** to `riak_b`, **`process_info`** on the vnode: in
`timer:sleep`, called from `shop_vnode:handle_command/3`, the schedulers
almost idle. **`module_code`** for `handle_command/3`:

```erlang
handle_command({add, Cart, Item}, _Sender, S = #{data := D}) ->
    timer:sleep(5),
    ...
```

**`trace_calls`** on `shop_vnode:handle_command`: ten calls in a row, all
`{add, flash_sale, {item,1}}`, about 6 ms apart.

**The answer.** The flash sale sends every write to one cart key, and a
key always hashes to the same partition: all of it lands on one vnode on
`riak_b`, which handles one command at a time, 5 ms each. It falls
further behind every second, callers wait behind 9,000 commands and time
out, and past 10,000 its proxy will refuse writes outright. Separately,
`riak_c` is down: its partitions are served by fallbacks, whose writes
wait for hinted handoff, with less redundancy meanwhile. It isn't what
makes the writes slow: the fallbacks have nothing queued.

**Fixes.**

- **Spread the hot key:** write the flash sale's cart as sub-keys
  (`{flash_sale, Shard}`), so they hash to different partitions, and
  merge them on read.
- **Make each write cheaper:** no blocking work inside the vnode, or do
  it in batches, or with the vnode's worker pool.
- **Bring `riak_c` back,** so hinted handoff returns its partitions; or,
  if it's gone for good, mark it down and replace it.
- **Throttle at the client** meanwhile, to keep the vnode under the
  overload threshold.

---

## 20. riak_dt sets whose actors pile up

```sh
examples/elixir/run.sh wishlist
```

`riak_a` and `riak_b` run the riak_core shop with wishlists
(`examples/elixir/riak_shop`, with riak_dt): each wishlist is a riak_dt
set (an ORSWOT) in `wishlist_vnode`, on a 16-partition ring. `run.sh`
forms the cluster, then 10 shoppers add to 20 wishlists from `riak_a`,
each request in a process of its own.

> In our riak_core shop (`riak_a@yourhost`, `riak_b@yourhost`), adding
> to a wishlist gets slower the longer the shop runs, and `riak_a`'s
> memory keeps growing. Find out why.

Only the otp-debug tools were allowed. The session took 89 seconds.

**`connect`** to `riak_a`; **`cluster`** and **`diagnose`**: nothing
stood out, no mailbox backlog, no crash loop, no binary or ETS leak.
**`riak_core`** with `crdts: true`:

```json
{"status": "warning",
 "findings": [
   "warning: 9 CRDTs have more actors than the ring has partitions (16); the most, the orswot {wishlist,6} in :wishlist_vnode 639406966332270026714112114313373821099470487552, has 7443 actors for 30 elements, in 351916 bytes. Each update by a new actor adds it to the value's clock for good, so the actor is something other than the vnode (a client, a request, a process): the value grows with every update, and every merge, read repair and handoff carries it"],
 "vnodes": {"by_module": {":shop_vnode": {"total": 8, "primary": 8},
                          ":wishlist_vnode": {"total": 8, "primary": 8}}},
 "crdts": {"vnodes_scanned": 16, "count": 9, "bytes": 3115685,
   "largest": [
     {"type": "orswot", "key": "{wishlist,6}", "vnode": ":wishlist_vnode",
      "actors": 7443, "elements": 30, "deferred_removes": 0, "bytes": 351916},
     {"type": "orswot", "key": "{wishlist,11}", "vnode": ":wishlist_vnode",
      "actors": 7415, "elements": 30, "deferred_removes": 0, "bytes": 350600},
     ...]}}
```

Sets of 30 items, each with over 7,000 actors, on a ring where a value
should have about one actor per replica. **`module_code`** for
`wishlist_vnode:handle_command/3`: the actor comes with the command.

```erlang
handle_command({add, List, Item, Actor}, _Sender, S = #{lists := L}) ->
    {ok, Set} = riak_dt_orswot:update({add, Item}, Actor,
                                      maps:get(List, L, riak_dt_orswot:new())),
    ...
```

**`module_code`** for `riak_shop:wish/2` and `wisher/0`: the actor is
`self()`, and every add runs in a new process.

```erlang
wish(List, Item) ->
    riak_core_vnode_master:sync_command(index_node(<<"wishlists">>, List),
                                        {add, List, Item, self()}, wishlist_vnode_master, 5000).
```

**`riak_core`** with `crdts: true` again, a minute later: `{wishlist,6}`
had 10,006 actors and 472 KB, and the nine sets together 4.2 MB, up from
3.1 MB.

**The answer.** Every add uses a fresh pid as the set's actor, and an
ORSWOT keeps every actor in its version vector for good: the sets hold
30 items but grow by an actor, about 47 bytes, with every request. Each
update works through that ever longer clock, so adds get slower, and
memory grows; every merge, read repair and handoff to `riak_b` carries
the whole bloated set.

**Fixes.**

- **Make the vnode the actor:** `{Partition, node()}` from the vnode's
  state, not the caller's pid, so a set has about one actor per replica.
  Drop the actor from the command.
- **Mind the shape:** riak_dt takes a `{Term, Integer}` actor for a dot,
  so don't use, say, `{client, N}` as an actor.
- **The sets already bloated** keep their actors: rebuild them, reading
  each value and writing it into a new set under the right actor.

---

## 21. A Cowboy server whose acceptors wait for room

```sh
examples/elixir/run.sh cowboy
```

`cowboy_ex` serves an Erlang API on Cowboy (`examples/elixir/cowboy_shop`,
port 8090), with Ranch's limits at 4 acceptors and `max_connections` 10.
Its own clients: 60 accountants asking for sales reports, which one
gen_server renders one at a time, 300 ms each, and 10 shoppers browsing
products, every request on a new connection. A `curl` of `/products`
took 6 seconds.

> Browsing products on `cowboy_ex@yourhost` (GET
> http://localhost:8090/products) takes several seconds, though the
> products handler just returns a constant. Find out why.

Only the otp-debug tools were allowed. The session took 39 seconds.

**`connect`**, then **`diagnose`**. One finding isn't `ok`, `call_chains`:
40 processes waiting in a call, all on `report_server`, which has 39
messages queued and is in `timer:sleep/1`. The waiters are Cowboy request
processes (`cowboy_stream_h:request_process/3`), each in
`gen_server:call(report_server, {render, Id}, infinity)`.

**`cowboy`**, for 5 seconds:

```json
{"status": "critical",
 "findings": [
   "critical: :shop_http (0.0.0.0:8090): 4 of 4 acceptors waited the whole 5001 ms for room under max_connections (10 per connection supervisor, 4 supervisors, 40 connections active): new clients wait in the listen backlog, unaccepted, until a connection closes; Ranch refuses none and logs nothing",
   "warning: :shop_http (0.0.0.0:8090): 23 requests ran through the whole 5001 ms, most in report_handler:init/2"],
 "listeners": [{
   "listener": ":shop_http", "listening": "0.0.0.0:8090", "acceptors": 4,
   "connections": {"active": 40, "limit": 40, "max_connections": 10,
                   "connection_supervisors": 4, "fullest_supervisor": 10,
                   "acceptors_waiting_for_room": 4,
                   "acceptors_waiting_through_window": 4},
   "idle": 0, "requests_in_flight": 40,
   "waiting_in": [{"requests": 40, "current_function": "gen:do_call/4",
                   "in_your_code": "report_handler:init/2"}],
   "running_through_window": {"requests": 23, "in": [...]},
   "accepted_per_s": 5.4, "closed_per_s": 5.4,
   "routes": ["*/products -> products_handler", "*/reports/:id -> report_handler"],
   "telemetry": "off: no stream_handlers set, so no per-request telemetry"}],
 "window": {"not_listened": "telemetry isn't loaded on this node, ..."}}
```

The listener is full: 40 of 40 connections, every one with a report
request in flight, waiting in `report_handler:init/2`, and all four
acceptors blocked for the whole window. Connections close and open at
5.4 a second, about one per report rendered.

**`module_code`** for `report_server:handle_call/3`:

```erlang
handle_call({render, Id}, _From, S = #{rendered := N}) ->
    timer:sleep(300),
    {reply, {ok, <<"%PDF report ", Id/binary>>}, S#{rendered := N + 1}}.
```

**The answer.** The products handler is fine; a request for it can't get
a connection. The listener allows 40 connections, `max_connections` 10
for each of 4 connection supervisors, and report requests hold them all:
each waits in `gen_server:call(..., infinity)` for `report_server`,
which renders one report at a time, 300 ms each, with 39 queued, about
12 seconds a report. A new client, `/products` included, waits in the
listen backlog until a report finishes and frees a slot, and the
accountants' next connections are ahead of it. Ranch neither refuses nor
logs it, so it looks like a slow request.

**Fixes.**

- **Render concurrently:** in the request process or a pool of
  workers, not one gen_server; keep the counter in `counters` or ETS.
- **Don't hold connections without limit:** a timeout on the call and a
  503, or reject when the queue is long, or accept report jobs
  asynchronously (202 and poll).
- **Keep slow routes from starving fast ones:** a listener of its own
  for `/reports`, or more room: `ranch:set_max_connections(shop_http, N)`
  works on the live node, though it only postpones the problem.

---

## 22. A Yaws API whose cookie sessions pile up

```sh
examples/elixir/run.sh yaws
```

`yaws_ex` serves an Erlang API on Yaws, embedded
(`examples/elixir/yaws_shop`, port 8095), with its own clients: 10
shoppers looking at their carts through a mobile app that keeps no
cookies, about 50 requests a second.

> The memory of `yaws_ex@yourhost`, a Yaws API, keeps growing, though
> its traffic is steady. Find out why.

Only the otp-debug tools were allowed. The session took 45 seconds.

**`connect`**, then **`diagnose`**: one table stands out in `ets_tables`,
`yaws_session_server`, 15.6 MB in 3,680 rows; nothing else is out of the
ordinary. **`yaws`**, for 5 seconds:

```json
{"status": "warning",
 "findings": [
   "warning: 4490 cookie sessions (19.1 MB), 50.2 new a second, and 100% of a sample were never used again after the request that started them: a new session for each request (clients that don't send the cookie back, or code that starts a session without looking for one first). Each is kept for its ttl (1800 s), and until the hourly sweep (session_long_timeout 3600000 ms) once expired"],
 "sessions": {"count": 4490, "memory_bytes": 19074760, "new_per_s": 50.2,
              "sampled": 2000, "used_once": 2000, "expired_still_kept": 0,
              "ttl_seconds": [1800]},
 "config": {"max_connections": "nolimit", "keepalive_timeout": 30000,
            "session_idle_timeout": 120000, "session_long_timeout": 3600000, ...}}
```

**`ets_table`** on `yaws_session_server` agreed: 4,500 rows, owned by
the session server. A **`snapshot`**, a minute's wait, a diff: ETS up
about 0.24 MB a second, everything else flat. **`module_code`** for the
appmod, `shop_api:out/1`:

```erlang
"cart" ->
    Cookie = yaws_api:new_cookie_session(#{cart => [],
                                           recommendations => recommendations()}),
    [{content, "application/json", <<"{\"cart\":[]}">>},
     yaws_api:set_cookie("shop_session", Cookie, [{path, "/"}])];
```

**The answer.** Every `GET /api/cart` starts a new session, without
looking for the one the request may carry, and the app's clients never
send the cookie back anyway. Each session holds a copy of the
recommendations, about 4 KB, and lives for 30 minutes; expired ones go
only at the hourly sweep. At 50 a second, the table can't level off for
30 to 90 minutes: some 90,000 to 270,000 sessions, 0.4 to 1.1 GB.

**Fixes.**

- **Reuse the request's session:** `yaws_api:find_cookie_val/2` on the
  request's cookies and `yaws_api:cookieval_to_opaque/1`, and start one
  only when there's none; for clients that keep no cookies, don't start
  one at all.
- **Keep shared data out of sessions:** the recommendations are the same
  for everyone; compute them per request, or keep one copy in ETS or
  `persistent_term`.
- **Shorter lives:** a shorter ttl in `new_cookie_session/2`, and a
  shorter `ysession_long_timeout`, so expired sessions go sooner.

---

## 23. A shackle pool with one connection held up

```sh
examples/elixir/run.sh shackle
```

`shackle_ex` prices its products through a shackle pool, `prices`
(`examples/elixir/shackle_shop`): 4 connections, a backlog of 16, to a
pricing backend in the same node, on port 8097, that answers each
connection's requests in order. 20 shoppers look prices up with a 100 ms
timeout; a report job runs an export through the same pool, again 200 ms
after each one ends.

> On `shackle_ex@yourhost`, price lookups (`price_api:lookup/1`) fail
> now and then, though the pricing backend answers a lookup in a
> millisecond. Find out why.

Only the otp-debug tools were allowed. The session took 46 seconds.

**`connect`**, then **`diagnose`**: every check `ok`. **`shackle`**, for
10 seconds:

```json
{"status": "warning",
 "findings": [
   "warning: pool :prices (price_client to 127.0.0.1:8097): 524 of 2747 calls timed out ({error, timeout}) in 10026 ms; replies took 2.08 ms at p50, 4.08 ms at p95, and 531 replies came after their call had given up",
   "warning: pool :prices (price_client to 127.0.0.1:8097): connection 3 had 8 requests in flight (of 16), while the others had at most 0: something holds that connection up (a slow request ahead of the others, as a backend answers a connection's requests in order, or a slow backend instance), and the calls behind it wait"],
 "pools": [{"pool": ":prices", "client": "price_client", "backend": "127.0.0.1:8097",
            "pool_size": 4, "pool_strategy": "random", "backlog_size": 16, "max_retries": 0,
            "connections": [{"index": 1, "up": true, "in_flight": 0},
                            {"index": 2, "up": true, "in_flight": 0},
                            {"index": 3, "up": true, "in_flight": 8},
                            {"index": 4, "up": true, "in_flight": 0}],
            "held_up": {"index": 3, "in_flight": 8, "others_at_most": 0},
            "window": {"replies": 2223, "timeout": 524, "not_found": 531,
                       "reply_ms": {"p50": 2.08, "p95": 4.08, "max": 801.97}}}],
 "callers_waiting": {"count": 8, "in": [
   {"callers": 7, "in_your_code": "shackle_shop:shopper/0"},
   {"callers": 1, "in_your_code": "shackle_shop:reports/0"}]}}
```

A fifth of the calls time out, though replies take 2 ms; the replies
come anyway, too late (`not_found`), the slowest after 802 ms. One
connection has 8 requests in flight, the others none, and among the
callers waiting, one is the report job. **`module_code`** for
`price_api:lookup/1`, `price_reports:export/0` and the client:

```erlang
lookup(Sku) -> shackle:call(prices, {get, Sku}, 100).
export()    -> shackle:call(prices, export, 5000).
```

**`trace_calls`** on `price_reports:export`: each takes 800 ms.

**The answer.** Exports and lookups share the pool, and the backend
answers a connection's requests in order. While an export runs, every
lookup that the pool's random pick sends to that connection waits behind
it, up to 800 ms, well past its 100 ms timeout. A quarter of the lookups
land there, and an export runs 80% of the time: about 20% fail, as
measured.

**Fixes.**

- **A pool of their own for exports**, so slow requests never share a
  connection with lookups:

  ```erlang
  shackle_pool:start(price_exports, price_client,
                     [{port, 8097}, {socket_options, [binary]}],
                     [{pool_size, 1}, {backlog_size, 4}]).
  ```

  and `shackle:call(price_exports, export, 5000)` in `price_reports`.
- **A backend that answers out of order:** the protocol already tags each
  request with an id, and the client matches replies by it.
- Not a longer lookup timeout: the failures would go, but lookups behind
  an export would still take up to 800 ms.

---

## 24. Telemetry handlers attached per checkout

```sh
examples/elixir/run.sh telemetry
```

`telemetry_ex` runs a shop's checkout (`examples/elixir/telemetry_shop`):
5 shoppers, each checking out ten times a second. To hear how long its
payment took, each checkout attaches a telemetry handler to
`[:shop, :payment, :stop]`. The session started after the shop had run
for a minute and a half.

> Checkout on `telemetry_ex@yourhost` (`Shop.Checkout.run/1`) gets
> slower the longer the shop runs, and its CPU use creeps up. Find out
> why.

Only the otp-debug tools were allowed. The session took 41 seconds.

**`connect`**, then **`diagnose`**: `message_queues` flagged the five
shoppers, each with over 4,000 messages queued, while sleeping between
checkouts; `top_reductions` had `:telemetry_handler_table` at the top,
and `ets_tables` its table at 4,640 rows. **`telemetry_handlers`**, for
5 seconds:

```json
{"status": "warning",
 "findings": [
   "warning: 5450 handlers with ids like {'Elixir.Shop.Checkout',#Ref<...>} (all handlers: 5205 at the start of the window, 5450 at its end): attached per process or per request, and not detached; each runs on every event it's attached to"],
 "handlers": 5450, "handlers_at_start": 5205,
 "id_patterns": [{"pattern": "{'Elixir.Shop.Checkout',#Ref<...>}",
                  "handlers": 5450, "at_start": 5205}],
 "busiest": [{"id": "{'Elixir.Shop.Checkout',#Ref<...>}",
              "events": ["shop.payment.stop"],
              "function": "Shop.Checkout.payment_done/4",
              "events_per_s": 46.0}, ...]}
```

245 more handlers in 5 seconds, about 49 a second, one per checkout, all
on the payment event. **`module_code`** for `Shop.Checkout.run/1` and
`payment_done/4`:

```elixir
def run(order) do
  :ok = :telemetry.attach({Shop.Checkout, make_ref()}, [:shop, :payment, :stop],
                          &Shop.Checkout.payment_done/4, %{checkout: self(), order: order})
  :ok = Shop.Payments.charge(order)
  receive do
    {:payment_ms, ms} -> ms
  after
    1000 -> :unknown
  end
end

def payment_done(_event, %{duration: duration}, %{order: order}, %{checkout: pid, order: order}),
  do: send(pid, {:payment_ms, System.convert_time_unit(duration, :native, :millisecond)})

def payment_done(_event, _measurements, _metadata, _config), do: :ok
```

**The answer.** Every checkout attaches a handler and never detaches it.
Handlers are global and outlive the call that attached them, and every
payment event runs them all: the work per checkout grows with the
number of checkouts so far, which is why checkout gets slower and CPU
creeps up. And an old handler whose order equals a later one's (orders
are only a shopper and a total) sends that shopper a stray
`{:payment_ms, ms}` that nothing receives, hence the mailboxes; or a
stray one is taken for the current checkout's.

**Fixes.**

- **Don't attach per call:** time the charge where it's made, with
  `:timer.tc/1`, or attach one handler when the application starts.
- If a handler per call is kept: detach it in an `after`, and tag the
  message with the call's ref, so a stale one can't be taken.

---

## 25. Mnesia transactions waiting on one record

```sh
examples/erlang/run.sh mnesia
```

`mnesia_erl` runs a shop on Mnesia (`examples/erlang/src/mnesia_shop.erl`,
RAM tables): 20 shoppers place orders, each a transaction.

> Placing an order on `mnesia_erl@yourhost`
> (`mnesia_shop:place_order/2`) takes up to a second at busy times,
> though an order's work takes about 30 ms. Find out why.

Only the otp-debug tools were allowed. The session took 41 seconds.

**`connect`**, then **`diagnose`**: every check `ok`, the CPU at 2%.
**`mnesia`**, for 5 seconds:

```json
{"status": "warning",
 "findings": [
   "warning: transactions waited for a read_write lock on {stats,orders_today} in 39 of 49 samples, 2.9 on average and 8 at most, its lock held mostly in fraud:check/2 (37): a transaction holds its locks until it ends, so what it does meanwhile, every transaction after that record waits for",
   "warning: 197.1 transactions restarted a second, against 31.6 commits: they conflict on locks, and Mnesia restarts the younger of two that would wait for each other, running its fun again"],
 "contended": [{"record": "{stats,orders_today}", "for": ["read_write"],
                "waited_for_in": "39 of 49 samples", "waiting_on_average": 2.9,
                "waiting_at_most": 8, "held_by_code": ["fraud:check/2 (37)", ...]}],
 "transactions": {"running": 20, "commits_per_s": 31.6, "restarts_per_s": 197.1,
                  "failures_per_s": 0.0},
 "tables": [{"table": "order", "storage": "ram_copies", "size": 1442, "growing_per_s": 31.6, ...},
            {"table": "product", "size": 100, ...},
            {"table": "stats", "size": 1, ...}]}
```

One record, waited for nearly all the time, its lock held in
`fraud:check/2`; and six restarts for every commit. 31.6 commits a
second is one every 30 ms: the orders go through one at a time.
**`module_code`** for `mnesia_shop:place_order/2` and `fraud:check/2`:

```erlang
place_order(Sku, Qty) ->
    mnesia:transaction(
      fun() ->
              [#stats{orders = N} = Stats] = mnesia:read(stats, orders_today, write),
              [#product{stock = Stock} = Product] = mnesia:read(product, Sku, write),
              ok = fraud:check(Sku, Qty),
              ok = mnesia:write(Product#product{stock = Stock - Qty}),
              ok = mnesia:write(Stats#stats{orders = N + 1}),
              mnesia:write(#order{id = make_ref(), sku = Sku, qty = Qty})
      end).

check(_Sku, _Qty) ->
    timer:sleep(30),
    ok.
```

**The answer.** Every order write-locks the same record, the day's stats,
first, and holds it through the 30 ms fraud check, since a transaction
holds its locks until it ends. So orders go through one at a time, about
33 a second whatever the CPUs. When several want the lock, Mnesia
restarts the younger ones, which wait and run the whole fun again: 197
restarts a second, and an order that keeps losing waits behind up to 8
others, often more than once, up to a second.

**Fixes.**

- **The fraud check out of the transaction:** before
  `mnesia:transaction/1`. It reads nothing the transaction protects, so
  nothing should be locked while it waits.
- **No global counter in every order:** `mnesia:dirty_update_counter/3`
  on the stats after the transaction, or the stats read and written last
  in it, so its lock is held for microseconds.

---

## 26. A Postgrex pool held through a payment call

```sh
examples/elixir/run.sh postgrex
```

`postgrex_ex` runs a shop on PostgreSQL through a Postgrex pool of 5,
`:shop_db` (`examples/elixir/postgrex_shop`; `run.sh` starts its own
PostgreSQL on 127.0.0.1:5544). 8 buyers check out and 20 shoppers view
products.

> Product pages on `postgrex_ex@yourhost` (`Shop.Catalog.show/1`) are
> slow now and then, and some fail with "connection not available and
> request was dropped from queue", though their query takes a
> millisecond. Find out why.

Only the otp-debug tools were allowed. The session took 35 seconds.

**`connect`**, then **`diagnose`**: every check `ok`, though 23
processes wait in `DBConnection.Holder.checkout_call`. **`postgrex`**,
for 3 seconds, with `server: true`:

```json
{"status": "critical",
 "findings": [
   "critical: pool :shop_db (postgres on 127.0.0.1:5544): 23 callers waiting for a connection, the longest 492 ms, with all 5 up checked out; they wait in Shop.Catalog.show/1, now in DBConnection.Holder.checkout_call/5 (20). Past queue_target (50 ms) for a whole queue_interval (1000 ms), DBConnection drops queued checkouts: \"connection not available and request was dropped from queue\"",
   "warning: pool :shop_db (postgres on 127.0.0.1:5544): connections were held by the same caller through the whole 3010 ms, most in Shop.Checkout.place/1, now in prim_inet:recv0/3 (2): a connection is held for a whole transaction, and nobody else can use it meanwhile",
   "warning: pool :shop_db (postgres on 127.0.0.1:5544): 1 checked-out connections are in a transaction while their callers do something else (Shop.Payments.charge/1, now in Process.sleep/1): the rows they wrote stay locked on the server meanwhile",
   "warning: on the server, backend 25500 (held by <0.212.0> in Shop.Checkout.place/1, now in prim_inet:recv0/3) waits (Lock/transactionid) for a lock held by backend 25498 (held by <0.213.0> in Shop.Checkout.place/1, now in prim_inet:recv0/3): UPDATE products SET stock = stock - $1 WHERE id = $2",
   ...],
 "pools": [{"pool": ":shop_db", "pool_size": 5,
            "connections": {"up": 5, "idle": 0, "checked_out": 5, "down": 0},
            "callers_waiting": 23, "longest_wait_ms": 492,
            "waiting_in": ["Shop.Catalog.show/1, now in DBConnection.Holder.checkout_call/5 (20)",
                           "Shop.Checkout.place/1, now in DBConnection.Holder.checkout_call/5 (3)"],
            "checked_out": [
              {"backend_pid": 25498, "in_your_code": "Shop.Checkout.place/1, now in prim_inet:recv0/3",
               "server": "idle in transaction, transaction open 0.5 s"},
              {"backend_pid": 25501, "in_your_code": "Shop.Checkout.place/1, now in prim_inet:recv0/3",
               "server": "active, transaction open 2.0 s, blocked by backend 25498"},
              {"backend_pid": 25502, "in_your_code": "Shop.Payments.charge/1, now in Process.sleep/1",
               "in_transaction": true, "server": "active, transaction open 0.0 s, blocked by backend 25501"},
              ...]}],
 "server": {"backends": 5, "idle_in_transaction": 1, "blocked": [...]}}
```

Every connection is checked out by a checkout, the product pages queue
behind them, and on the server the checkouts' updates wait for each
other's lock on the product row. **`module_code`** for
`Shop.Checkout.place/1` and `Shop.Payments.charge/1`:

```elixir
def place(%{product: product, quantity: quantity} = order) do
  Postgrex.transaction(:shop_db, fn conn ->
    Postgrex.query!(conn, "UPDATE products SET stock = stock - $1 WHERE id = $2", [quantity, product])
    :ok = Shop.Payments.charge(order)
    Postgrex.query!(conn, "INSERT INTO orders (product, quantity) VALUES ($1, $2)", [product, quantity])
  end)
end

def charge(_order) do
  Process.sleep(300)
  :ok
end
```

**The answer.** A checkout's transaction locks the product's row, then
calls the payment provider, 300 ms, before it commits: its connection,
and the row, are held all that time. Checkouts of the same product queue
for the row on the server, each holding a connection while it waits, so a
few of them take all five. The product pages' one-millisecond query
waits for a connection, and once the queue has been over `queue_target`
for a whole `queue_interval`, DBConnection drops waiting checkouts: the
error the pages see.

**Fixes.**

- **The payment call out of the transaction:** charge first, then a
  short transaction for the stock and the order (`stock >= quantity` in
  the update, so it can't oversell).
- **The pages' reads on their own pool,** or the checkouts limited to
  part of the pool, so slow checkouts can't starve them.
- A larger `pool_size` only postpones it: the transactions still queue
  on the row.

---

## 27. Profiling a slow function, and tuning it

```sh
examples/erlang/run.sh tuning
```

`tuning_erl` builds price quotes (`examples/erlang/src/quote.erl`): four
sales reps keep building quotes for 3000-line orders.

> Quotes for big orders on `tuning_erl@yourhost` take about a second each
> (`quote:build/1`, e.g. `quote:build(quote:sample_order(3000))`).
> Profile it, find what to change, and measure. Don't load new code.

Only the otp-debug tools were allowed. The session took 71 seconds.

**`connect`**, then **`diagnose`**: every check `ok`; `top_reductions`
and `long_schedules` show the four reps each holding a scheduler in
`erlang:'++'/2`, under `quote:price_lines/5`. **`profile`** on `quote`
for 3 seconds: `price_lines/5` takes 99.9% of the time, and allocates
41 GB in those 3 seconds. **`module_code`** for it:

```erlang
price_lines(Lines, Catalog, I, Text, Total) when I =< length(Lines) ->
    {Sku, Qty} = lists:nth(I, Lines),
    {Sku, Price} = lists:keyfind(Sku, 1, Catalog),
    Line = io_lib:format("~6w x~2w @ ~4w = ~7w~n", [Sku, Qty, Price, Qty * Price]),
    price_lines(Lines, Catalog, I + 1, Text ++ lists:flatten(Line), Total + Qty * Price);
price_lines(_Lines, _Catalog, _I, Text, Total) ->
    {Text, Total}.
```

**`benchmark`** of `quote:build` on orders of 750, 1500 and 3000 lines:

| Lines | Mean per call | Reductions per call |
|---|---|---|
| 750 | 44 ms | 0.83 M |
| 1500 | 175 ms | 2.5 M |
| 3000 | 665 ms | 9.0 M |

Twice the lines, four times the time: quadratic. With garbage collection
at about a quarter of the work, a **`benchmark`** of the same call under
two spawn options:

```json
{"findings": ["info: fastest: quote:build ([{min_heap_size, 4000000}]), 367720.6 µs a call on average, 1.8 times faster than quote:build ([])"],
 "variants": [
   {"function": "quote:build", "spawn_options": "[]", "us_mean": 673069.0, "reductions_per_call": 9005911, ...},
   {"function": "quote:build", "spawn_options": "[{min_heap_size, 4000000}]", "us_mean": 367720.6,
    "speedup_vs_first": 1.83, "same_result_as_first": true, ...}]}
```

Fewer collections halve it, but the work is still quadratic.

**The answer.** Each line copies all the text so far (`Text ++`), walks
the list to the line (`lists:nth`) and again for its length (the guard),
and scans the 5000-product catalog list (`lists:keyfind`). The session
proposed one pass over the lines, the prices in a map, and the text
built as a list of lines, reversed and flattened once; and, to confirm
it, loading the rewrite under another name and benchmarking both.

**Then, with the user's approval.** That rewrite is
`examples/erlang/tuning/quote_fast.erl`, compiled by `run.sh`. The rest
was run by script, with the same tools, the user accepting
`load_module`'s dialog:

```
Load new code for quote_fast on tuning_erl@yourhost?
New code: md5 b9227720461607655f3679186a0f8619, .../examples/erlang/tuning/quote_fast.beam
Running now: not loaded on the node
```

**`load_module`** loaded it, until the node restarts. **`benchmark`** of
both on `quote:sample_order(3000)`:

```json
{"findings": ["info: fastest: quote_fast:build ([]), 6725.8 µs a call on average, 101.9 times faster than quote:build ([])"],
 "variants": [
   {"function": "quote:build", "us_mean": 685608.7, "us_p95": 704866.9, "reductions_per_call": 9022917, "calls": 4},
   {"function": "quote_fast:build", "us_mean": 6725.8, "us_p95": 10926.3, "reductions_per_call": 1133377, "calls": 444,
    "same_result_as_first": true, "speedup_vs_first": 101.94}]}
```

102 times faster, with exactly the same quote. And `quote_fast` under a
larger `min_heap_size`: 6.1 ms against 6.5 ms, 7%; with the garbage gone,
the process setting no longer matters much.

---

## 28. EMQX: a client that never acknowledges, and a client id shared

```sh
examples/emqx/run.sh start
```

EMQX 5.8.6 runs in Docker as `emqx@127.0.0.1` (cookie `emqxdemo`), with
`examples/emqx/clients.py`: 19 sensors publishing readings at QoS 1, a
dashboard subscribed to them all, and two devices both connecting as
`sensor-7`. The server was started with `ERL_FLAGS="-erl_epmd_port 4370"`,
as EMQX listens for distribution on 4370 without epmd.

> Our dashboard (MQTT client `dashboard-1`) misses sensor readings, and
> device `sensor-7` keeps going offline. EMQX is `emqx@127.0.0.1`. Find
> out why.

Only the otp-debug tools were allowed. The session took 69 seconds.

**`connect`** (EMQX ships recon, which is used as it is), then
**`diagnose`**: every check `ok`; the busiest process is the dashboard's
connection. **`emqx`**, for 15 seconds:

```json
{"status": "warning",
 "findings": [
   "warning: 1 clients can't keep up; dashboard-1 has 32 of 32 messages in flight unacknowledged and 1000 of 1000 queued, and has had 9787 dropped (EMQX drops 180.1 a second for full queues now): EMQX keeps QoS 1 and 2 messages in flight until the client acknowledges them, queues the rest, and drops what doesn't fit (delivery.dropped.queue_full). A client that never acknowledges, or reads too slowly, misses messages",
   "warning: 4.8 sessions a second taken over or discarded, with 4.8 connects a second (reconnecting in the window: sensor-7): clients reconnecting with a client id already connected, which kicks the other off; two devices sharing one client id kick each other off forever"],
 "slow_consumers": [{"client_id": "dashboard-1", "in_flight": "32 of 32", "queued": "1000 of 1000",
                     "dropped": 9787, "delivered": 32, "memory_bytes": 4736184}],
 "reconnecting": {"clients": 1, "some": ["sensor-7"]},
 "window": {"messages_received_per_s": 180.1, "messages_delivered_per_s": 0.0,
            "dropped_per_s": {"queue_full": 180.1},
            "connects_per_s": 4.8, "disconnects_per_s": 4.8, "sessions_discarded_per_s": 4.8},
 "clients": {"connections": 21, "sessions": 21, "subscriptions": 1}}
```

**`recent_errors`** for 10 seconds: nothing, as EMQX logs only warnings
and up.

**The answer.** Two client bugs; the broker is healthy. `dashboard-1`
took its first 32 messages and acknowledged none: EMQX sends no more until
it does, queues the next thousand, and drops every reading after that,
180 a second, everything the sensors publish. And two clients connect as
`sensor-7`: each connection discards the other's session, and both
reconnect at once, about five times a second.

**Fixes.**

- **The dashboard:** acknowledge each message (or auto-acknowledge), with
  a handler that doesn't block; or subscribe at QoS 0 if only the latest
  readings matter. A larger `max_inflight` or `max_mqueue_len` only delays
  the drops.
- **sensor-7:** a client id of its own for every device (from its serial
  or MAC), and the duplicate found: a cloned image, a second process. An
  ACL tying the client id to the device's credentials keeps it from
  happening again, and a back-off in the reconnect loop stops a storm.

---

## 29. ejabberd: a bot that reads slowly, an archive on Mnesia, a full offline queue

```sh
examples/ejabberd/run.sh start
```

ejabberd 26.09 runs in Docker as `ejabberd@localhost` (cookie
`ejabberddemo`), with its default configuration and
`examples/ejabberd/clients.py`. Five order services each send ten
notifications a second to the logger bot `slowbot@localhost`, which
reads its socket at 1 KB a second. They also send one a second to
`support@localhost`, which nobody logs in as. The server was started
with `ERL_FLAGS="-erl_epmd_port 5210"`, because the image listens for
distribution on 5210 (its `ERL_DIST_PORT`) without epmd. The session ran
ten minutes after the start.

> Order notifications to our logger bot, slowbot@localhost, arrive late
> or not at all, and ejabberd's memory keeps growing. Messages to
> support@localhost go missing too. ejabberd is `ejabberd@localhost`.
> Find out why.

Only the otp-debug tools were allowed. The session took 47 seconds.

**`connect`**, then **`diagnose`**: no mailbox over 1000, but
`scheduler_time` warns that garbage collection takes half the
schedulers' work. A dets process, `<0.606.0>`, is the busiest, and
several c2s processes wait in `dets:req`. **`ejabberd`**, for 5 seconds:

```json
{"status": "critical",
 "findings": [
   "critical: 4 client connections are backed up; slowbot@localhost/app's c2s process has 16289 stanzas waiting, 28.5 more a second, in 22 MB: 16286 in the queue ejabberd's p1_server keeps on the heap (where it moves the mailbox, so the mailbox, 3, stays short). Its socket is closed (the client stopped reading, and ejabberd's send_timeout gave up on it), but the session is still open: the process is still working through what was queued for it, archiving each message (mod_mam) on the way. Everything sent to that session waits there, and the user gets it late or not at all",
   "warning: support@localhost (100) has as many offline messages as max_user_offline_messages allows: every new message to that user is bounced back to its sender with an error and lost, until they log in and read the queue",
   "warning: the message archive (mod_mam) is on Mnesia, in a disc_only_copies table (a dets file): archive_msg holds 45183 messages, 32 MB, 46.6 more a second, and one look at it took 106.1 ms. Every message delivered is archived by the recipient's c2s process before it goes on; 4 backed-up connections are waiting on it. Mnesia doesn't suit MAM beyond small servers (dets files are limited to 2 GB too); ejabberd's documentation recommends an SQL backend for it"],
 "archive": {"backend": ":mnesia",
             "table": {"name": "archive_msg", "storage": "disc_only_copies", "messages": 45183,
                       "bytes": 32251110, "one_look_ms": 106.1},
             "messages_archived_per_s": 46.6},
 "backed_up_clients": [{"jid": "slowbot@localhost/app", "pid": "<0.895.0>", "queued": 16286, "mailbox": 3,
                        "memory_bytes": 22450640, "socket_open": false, "waiting_growth_per_s": 28.5,
                        "memory_growth_bytes_per_s": 1655929,
                        "stack": ["dets:req/2", "dets:info/2", "mnesia:raw_table_info/2",
                                  "mod_mam_mnesia:store/10", "mod_mam:store_mam_message/8", "..."]}],
 "offline": {"messages": 100, "most": [{"user": "support@localhost", "messages": 100, "limit": 100, "full": true}]},
 "sessions": {"users_online": 6}}
```

**`process_info`** on the dets process `<0.606.0>`: 9.2 billion
reductions in ten minutes, in `dets:write_cache → read_buckets →
dets_utils:msort`, a 19 MB heap. All six sessions' c2s processes are
monitoring it.

**The answer.** The message archive runs on Mnesia in a
`disc_only_copies` table: one dets file, served by one process. Every
c2s process archives each message before it delivers it, so every
delivery waits on that process. One lookup on it took 106 ms, and it
gets slower as the table grows. slowbot receives fifty messages a
second, more than its process can archive and pass on. When the bot
stopped keeping up with its reading, `send_timeout` closed its socket.
The session stayed open, though, so ejabberd still routes everything for
slowbot to that process, which queues it. The queue holds 16,000
stanzas and 22 MB, and it grows by 28 a second and 1.6 MB a second.
Each queued message is archived and then sent to a socket that's gone.
Separately, support's offline queue is at its limit of 100, so every new
message to that account bounces.

**Fixes.**

- **The archive:** use `mod_mam` with `db_type: sql`, as ejabberd's
  documentation recommends for anything beyond a small server. Until
  then, stop archiving the bot's messages, or prune the archive with
  `ejabberdctl delete_old_mam_messages`. dets files also stop at 2 GB.
- **slowbot:** kick the dead session (`ejabberdctl kick_session slowbot
  localhost app stale`), which frees its queue. Then the bot needs to
  keep reading its socket, and stream management (XEP-0198) lets it
  resume cleanly.
- **support:** someone has to log in and read the queue. Otherwise
  raise its `max_user_offline_messages`, or let the support client fetch
  its history from MAM.

The agent changed nothing on the node, and offered to kick the session.

---

## 30. Ranch: dead connections keep new clients out

```sh
examples/elixir/run.sh ranch
```

`ranch_ex` runs a point-of-sale server on Ranch, on port 5555, with 4
acceptors × 25 connections. Its protocol, `pos_protocol`, is a line
protocol of its own. The same node simulates the stores' tills
(`tills.erl`): 40 tills that each keep one connection, 12 outlet tills
behind a NAT that drops idle connections without telling either end, and
a new till every 3 seconds. Every 5 seconds, each outlet till opens a
new connection and leaves the old one, which the server still holds. The
session ran a minute after the start.

> New tills can't connect to our point-of-sale server,
> `ranch_ex@yourhost` (port 5555): they time out, while the tills
> already connected keep working. Restarting it helps for a minute or
> so. Find out why.

Only the otp-debug tools were allowed. The session took 58 seconds.

**`connect`**, then **`diagnose`**: every check `ok`. **`ranch`**, for 10
seconds:

```json
{"status": "critical",
 "findings": [
   "critical: :pos_listener: 4 of 4 acceptors waited for room through the whole window (connection supervisors at max_connections, 25 each, 100 for the listener): new clients wait in the listen backlog (1024), unaccepted, and nothing is refused or logged",
   "critical: :pos_listener: 60 of 100 connections did nothing through the whole window (60 without a byte either way), most in prim_inet:recv0/3 from pos_protocol:loop/2: clients that went quiet, held open by a protocol waiting with no timeout. They hold 100 of the listener's 100 places, so new clients wait. A receive timeout (gen_tcp:recv's, or {active, once} with an after) closes them"],
 "listeners": [{"listener": ":pos_listener", "listening": "0.0.0.0:5555", "protocol": ":pos_protocol",
                "connections": {"active": 100, "limit": 100, "max_connections": 25, "connection_supervisors": 4,
                                "acceptors_waiting_through_window": 4},
                "accepted_per_s": 0.0, "closed_per_s": 0.0,
                "doing": [{"connections": 100, "current_function": "prim_inet:recv0/3",
                           "in_protocol_code": "pos_protocol:loop/2"}],
                "idle_through_window": {"connections": 60, "of": 100, "no_bytes_either": 60}}]}
```

**`module_code`** on `pos_protocol:loop/2`:

```erlang
loop(Socket, Transport) ->
    case Transport:recv(Socket, 0, infinity) of
```

Then the agent read `tills:outlet/2`, the simulation, and found its
abandoned sockets. The real tills sit behind the NAT and leave nothing
like this to read.

**The answer.** The listener is full: 100 of 100 connections, and all
four acceptors waited for room through the whole window. New tills wait
in the listen backlog, unaccepted, until they time out, and Ranch
neither refuses nor logs them. Sixty of the hundred connections moved
no bytes at all. Each one waits in `pos_protocol:loop/2` on a `recv`
with an `infinity` timeout, so a client that goes away without closing
keeps its place forever. After a restart the leftovers fill the free
places within about a minute.

**Fixes.**

- **The server:** give `recv` a timeout longer than a working till's
  gap between requests, and close the connection on `{error, timeout}`
  (the `{error, _}` branch already does). TCP keepalive
  (`{keepalive, true}` in `socket_opts`) also finds dead peers, but only
  after the OS's own interval, two hours by default.
- **The tills:** behind a NAT, send a heartbeat more often than the NAT
  drops idle connections.
- A larger `max_connections` only postpones the problem.

The agent changed nothing on the node.

---

## 31. A LiveView whose assigns keep growing

```sh
examples/elixir/run.sh live
```

`live_ex` runs a Phoenix LiveView orders dashboard on Bandit, on port
4050. Every new order, about 10 a second, is broadcast over PubSub. The
same node simulates 15 browser tabs that keep the dashboard open, three
of them pressing Refresh every second. The session ran 90 seconds after
the start.

> The staff's orders dashboard, a LiveView on `live_ex@yourhost`
> (http://localhost:4050/), gets sluggish the longer it's open, and the
> node's memory keeps growing. Find out why.

Only the otp-debug tools were allowed. The session took 84 seconds.

**`connect`**, then **`diagnose`**: every check `ok`. **`phoenix`**, for 10
seconds:

```json
{"status": "warning",
 "findings": [
   "warning: LiveShopWeb.OrdersLive's assign orders grew through the window in its biggest process, 11 KB a second, 101 more items, to 1584 KB (a list of 1438); the 15 LiveShopWeb.OrdersLive processes hold 82 MB in all: a LiveView keeps its assigns for as long as the page is open, so whatever is added to them, per message or event, stays, in every open page. Keep what grows bounded, or put it in a stream (stream/3), which the process doesn't keep",
   "warning: LiveShopWeb.OrdersLive refresh (handle_event) takes 402.94 ms at p95 (30 in the window): the LiveView process does nothing else meanwhile, so that page's other events and its PubSub messages wait. Move the slow work out of the callback: start_async/3 or assign_async/3"],
 "live_views": [{"view": "LiveShopWeb.OrdersLive", "processes": 15,
                 "memory_bytes": {"total": 82902232, "max": 7657256, "mean": 5526815},
                 "biggest_assigns": [{"assign": "orders", "length": 1438, "bytes": 1584683,
                                      "grew_in_window": {"length": 101, "bytes_per_s": 11183}}]}],
 "pubsub": [{"pubsub": "LiveShop.PubSub", "subscriptions": 15,
             "topics_with_most": [{"topic": "orders", "subscribers": 15}]}],
 "window": {"live_view_callbacks": [{"what": "LiveShopWeb.OrdersLive refresh (handle_event)",
                                     "count": 30, "p50_ms": 400.77, "p95_ms": 402.94}]}}
```

**`module_code`** on the view's callbacks:

```elixir
def handle_info({:order, order}, socket) do
  {:noreply, assign(socket, orders: [order | socket.assigns.orders])}
end

def handle_event("refresh", _params, socket) do
  {:noreply, assign(socket, stats: LiveShop.Stats.today())}
end
```

`LiveShop.Stats.today/0` turned out to be a 400 ms call, a stand-in for
the reporting API. A **`snapshot`** around a second, 30-second
**`phoenix`** call showed the same list 300 items longer. Process memory
barely moved in that window, because a heap grows in steps.

**The answer.** Every open dashboard adds each broadcast order to its
`orders` assign and never removes one. The page shows only the latest
ten and a count, but the whole list stays in the page's process for as
long as the tab is open, in every tab: 15 pages, 82 MB, growing about
10 orders a second each. And Refresh runs a 400 ms call inside
`handle_event`, so while it runs, that page handles neither new orders
nor clicks.

**Fixes.**

- **The orders:** keep a counter and the latest ten, or a stream that
  the process doesn't keep:

  ```elixir
  socket |> update(:order_count, &(&1 + 1)) |> stream_insert(:orders, order, at: 0, limit: 10)
  ```

  Then use `@order_count` for the count, and render `@streams.orders` in
  a `phx-update="stream"` container.
- **Refresh:** `start_async(socket, :stats, fn -> LiveShop.Stats.today() end)`,
  with a `handle_async(:stats, ...)` that assigns the result. A cache
  in front of `Stats.today/0` also saves 15 tabs from running the same
  call.
- The tabs open now keep their lists until they're reloaded after the
  deploy.

The agent changed nothing on the node.

---

## 32. A container's CPU quota, and its memory limit

```sh
examples/container/run.sh start
```

An Erlang pricing service runs in Docker as `svc@127.0.0.1` (cookie
`containerdemo`), limited to one CPU and 256 MB (`--cpus=1
--memory=256m`), but started with `+S 8:8 +sbwt very_long`, the
`vm.args` of the 8-core machine it came from. Baskets arrive in bursts,
80 every quarter of a second, for 8 workers; a price cache of about
120 MB sits in ETS, and a latency table nothing trims grows beside it.
The server was started with `ERL_FLAGS="-erl_epmd_port 9300"`. The
session started 90 seconds after the demo.

> Our pricing service runs in a container, as svc@127.0.0.1 (cookie
> containerdemo). Every few seconds it stalls for up to 100 ms, though
> its CPU use looks moderate, and it was OOM-killed twice this week.
> Find out why.

Only the otp-debug tools were allowed. The session took 93 seconds
(recorded with `scripts/blind_eval.py --cases container`).

**`connect`**, then **`diagnose`**, whose first check is `vm_config`:

```json
{"check": "vm_config", "status": "critical",
 "findings": {
   "notes": [
     "critical: the node uses 262 MB of the container's 268 MB memory limit (98%): past it the kernel's OOM killer kills the VM outright, with no crash dump and nothing in its logs",
     "warning: 8 schedulers online, but the container's CPU quota is 1.0 CPUs per 100 ms, and the kernel has throttled it in 10% of its periods since it started; in the last second, 4 of 10 (672 ms of throttled time, summed over its CPUs): the schedulers compete for that time, and once the VM has used its quota in a period the kernel stops all of it until the next, so latency jumps by up to the period. Run as many schedulers as the quota: +S 1:1 (the command line sets +S 8:8); without a +S, OTP 23 and later follow the quota themselves",
     "warning: the logger's primary level is debug: every debug message is built, formatted and handled, which costs in production; :info or :notice",
     "info: the schedulers busy-wait before sleeping (+sbwt very_long), which spends the container's CPU quota spinning: with a CPU limit, +sbwt none +sbwtdcpu none +sbwtdio none give it back to work"],
   "cpu": {"schedulers_online": 8, "cpu_quota": 1.0, "cpu_quota_period_ms": 100, "cpu_quota_from": "cgroup_v2",
           "throttled": {"throttled_share_since_start": 0.099,
                         "last_second": {"periods": 10, "throttled": 4, "throttled_ms": 672}},
           "busy_wait": {"sbwt": "very_long"}},
   "memory": {"container_limit_bytes": 268435456, "vm_total_bytes": 228995250,
              "os_resident_bytes": 262000640, "limit_from": "cgroup_v2"},
   "emulator_flags": {"+S": "8:8", "+sbwt": "very_long"}}}
```

Then **`module_code`** on `pricing`'s functions, **`ets_table`** on
`price_cache` (12,000 rows of 10 KB binaries, about 120 MB, held
outside the table) and `latency` (58,000 rows), two **`snapshot`**
diffs (ETS growing about 40 KB a second, nothing else), and
**`long_schedules`**: processes in plain Erlang code holding a scheduler
for up to 72 ms, which Erlang code doesn't do by itself: the kernel had
stopped the VM.

**The answer.** The stalls are the kernel throttling the container. Eight
schedulers work through a burst of baskets in parallel and use the
period's 100 ms of CPU in about 12 ms, and then the whole VM waits for
the next period; the service's own health check ran 40 ms late. CPU
looks moderate because the load comes in bursts, and busy-waiting
schedulers spend part of the quota spinning. The OOM kills: the price
cache alone is half the container, worker heaps add 60 MB, and the
latency table grows without bound, so the node starts near the limit
and drifts over it.

**Fixes.**

- **vm.args:** `+S 1:1`, or no `+S` at all (OTP follows the quota), and
  `+sbwt none +sbwtdcpu none +sbwtdio none`; or a CPU limit to match
  eight schedulers.
- **The latency table:** delete rows older than a window, or keep a
  histogram.
- **The cache:** cap it, or give the container room for it.
- **Logging:** drop the `logger:set_primary_config(level, debug)` at
  start.

The agent changed nothing on the node.

---

## 33. Callers waiting behind one slow request

```sh
examples/erlang/run.sh inventory
```

`inventory_erl` runs the shop's inventory, one gen_server holding every
product's stock. 20 shop processes reserve items with `gen_server:call`,
each every 50 ms; the warehouse dashboard asks the same server for a
stock report every 700 ms. Nothing on the node emits telemetry.

> Reservations on our inventory service, `inventory_erl@yourhost`,
> sometimes take a third of a second, though a reservation is a map
> update; its mailbox never looks long. Find out why.

Only the otp-debug tools were allowed. The session took 46 seconds.

**`connect`**, then **`diagnose`**: nothing over its thresholds, but
`inventory` is the busiest process by far. **`call_latency`** on
`inventory`, for 5 seconds:

```json
{"status": "warning", "module": "inventory", "busy_share": 0.327,
 "trace": "isolated trace session",
 "findings": [
   "warning: stock_report takes 330.11 ms at p95 to handle and is 99% of the server's busy time: while one runs, everything else sent to the server waits. Make it faster, or move it off this process (a Task, a pool of workers, or reading the data directly, e.g. from ETS)",
   "warning: {reserve, ...} (3-tuple) calls waited 308.1 ms at p95 in the mailbox before the server even started on them, and took 0.0 ms to handle: the time is spent behind other messages, not on the request"],
 "calls": [
   {"request": "stock_report", "calls": 5, "per_s": 1.0, "share_of_busy_time": 0.988,
    "wait_ms": {"p50": 0.01, "p95": 0.01, "max": 0.01},
    "handling_ms": {"p50": 321.9, "p95": 330.1, "max": 330.1}},
   {"request": "{reserve, ...} (3-tuple)", "calls": 1360, "share_of_busy_time": 0.001,
    "wait_ms": {"p50": 0.03, "p95": 308.1, "max": 317.1},
    "handling_ms": {"p50": 0.0, "p95": 0.0, "max": 0.02}}],
 "callers": [{"is": "in inventory:dashboard/0", "calls": 5, "waited_ms_max": 330.1},
             {"is": "in inventory:shop/1", "calls": 68, "waited_ms_max": 317.1}]}
```

**`module_code`** on `handle_call/3`, `report/1` and `value/2`:
`report/1` values every SKU with `value/2`, which builds a 4,000-element
list and folds over it.

**The answer.** A reservation takes no time to handle; it waits up to
317 ms in the mailbox for a `stock_report` the same server is building,
about a third of a second, once a second. The mailbox never looks long
because only the 20 shop processes call, each blocked on its own call:
at most 20 messages wait, each for a long time. `diagnose`'s mailbox
check couldn't see that; the time is only visible per call.

**Fixes.**

- Build the report outside the server: keep the stock in an ETS table
  (`read_concurrency`) the dashboard reads, or have `handle_call` spawn
  the report and answer with `gen_server:reply/2`, returning `{noreply,
  State}`.
- Make the report cheaper too: `value/2` gives the same result for the
  same stock every time.
- Then run `call_latency` again: a reservation's wait should be its
  handling time, under 0.03 ms.

The agent changed nothing on the node.

---

## 34. RabbitMQ: a memory alarm, a consumer with no prefetch, a queue nobody reads

```sh
examples/rabbitmq/run.sh start
```

RabbitMQ 4.1 runs in Docker as `rabbit@localhost` (cookie
`rabbitdemo`), with a memory high watermark of 300 MiB, and
`examples/rabbitmq/clients.py`: four order services publishing orders
(8 KB) to `orders` and a notification (1 KB) per order to `email`; an
order worker consuming `orders` with no prefetch limit and acking each
order it handles, about 50 a second; and nothing consuming `email` since
the email service was retired. The server was started with
`ERL_FLAGS="-erl_epmd_port 25672"`. The session started 150 seconds
after the demo.

> Our order services hang when they publish to RabbitMQ, for minutes at
> a time, though the order worker is running. RabbitMQ is
> `rabbit@localhost`. Find out why.

Only the otp-debug tools were allowed. The session took 43 seconds
(recorded with `scripts/blind_eval.py --cases rabbitmq`).

**`connect`** (RabbitMQ ships recon, which is used as it is), then
**`diagnose`**: one queue process holds about 258 MB of binaries, 65% of
the node's memory. **`rabbitmq`**, for 10 seconds:

```json
{"status": "warning", "version": "RabbitMQ 4.1.8",
 "memory": {"used_bytes": 312295424, "limit_bytes": 314572800, "share": 0.993},
 "findings": [
   "warning: the node uses 99% of its memory high watermark (314 MB): at the watermark a memory alarm blocks every publisher",
   "warning: channel 192.168.65.1:55660 -> 172.17.0.2:5672 (1) (demo) holds 20696 unacknowledged messages, with no prefetch limit, acking 49.9 a second: RabbitMQ sends a consumer without basic.qos everything as it arrives, and keeps each until it's acked, in its memory; set a prefetch (e.g. 50) so the rest wait in the queue, cheaply, or for another consumer",
   "warning: queue orders grew 267.9 messages a second with 1 consumer, which acked 49.9 a second (317.7 delivered): they take less than is published; most of it (20696) is delivered but unacknowledged",
   "warning: queue email has 29912 messages and no consumers, 317.7 more a second: they're kept, in memory or on disk, until something consumes or removes them. A queue nobody reads any more wants deleting (or a max-length or TTL policy), and its publishers stopping"],
 "published_per_s": 635.4,
 "busiest_queues": [
   {"queue": "email", "messages": 29912, "ready": 29912, "consumers": 0, "growth_per_s": 317.7},
   {"queue": "orders", "messages": 20696, "ready": 0, "unacknowledged": 20696, "consumers": 1,
    "delivered_per_s": 317.7, "acked_per_s": 49.9, "message_bytes": 169769288}],
 "channels_holding_unacked": [{"channel": "192.168.65.1:55660 -> 172.17.0.2:5672 (1)", "prefetch": 0,
                               "unacknowledged": 20696, "acked_per_s": 49.9}],
 "connections": {"total": 5, "by_state": {"running": 5}}}
```

At that moment the alarm wasn't set. On an earlier run of the demo,
the same call at the alarm showed `"alarms": [{"resource": "memory"}]`,
memory at 335 MB of the 314 MB watermark, and all five connections
`blocked` or `blocking` through the window: the alarm sets and clears
as the worker's acks free a little memory and the publishers fill it
again.

**The answer.** RabbitMQ sits at its memory high watermark, and each
time it crosses it, it raises a memory alarm and stops reading from
every publishing connection: the order services hang inside
`basic.publish`. The memory is the order worker's backlog. With no
prefetch, RabbitMQ delivers every order to it as it arrives, about 318
a second, while it acks 50, and keeps the 20,000 delivered but
unacknowledged orders, 170 MB of them, in memory. The `email` queue,
which nobody consumes, adds 30,000 more messages.

**Fixes.**

- **The worker:** `basic.qos` with a prefetch (50, say), so the backlog
  waits in the queue, where it can be paged to disk; and more workers,
  or a faster one, as it handles a sixth of what's published.
- **`email`:** delete it and stop publishing to it, or a `max-length`
  or TTL policy.
- **The publishers:** handle `connection.blocked`, so an alarm shows as
  an error, not a hang. A higher watermark only delays it.

The agent changed nothing on the node.

---

## 35. Sockets: Nagle's delay, an active socket flooding its owner, a blocked export

```sh
examples/sockets/run.sh start
```

An Erlang quotes service runs in Docker as `quotes@127.0.0.1` (cookie
`socketsdemo`), on Linux, where Nagle's delay shows on loopback. Its
quote frontend writes each request to the pricing backend in two
pieces, with gen_tcp's default `nodelay` false; its metrics collector
takes its agent's lines with `{active, true}` and a millisecond's work
each; its nightly export streams to a loader that reads a kilobyte a
second. The server was started with `ERL_FLAGS="-erl_epmd_port 9400"`.

> Quotes from our quotes service, quotes@127.0.0.1 (in a container,
> cookie socketsdemo), take 40 ms each, though the pricing backend
> answers in microseconds; the node's memory keeps growing, and the
> nightly price export never finishes. Find out why.

Only the otp-debug tools were allowed. The session took 63 seconds
(recorded with `scripts/blind_eval.py --cases sockets`).

**`connect`**, then **`diagnose`**, then **`socket_tuning`**, for 5
seconds:

```json
{"status": "critical",
 "findings": [
   "critical: quotes:collect/1 has 131045 messages waiting (9693 more than at the start) and 1 socket in {active, true}, which sends it every packet as it arrives, with nothing to slow the peer down: use {active, once} or {active, N} and ask for more as it handles them, so TCP holds the rest back",
   "warning: 1 TCP socket owned by quotes:export/2 had more queued to send than their high_watermark (8192 bytes) through the window, up to 107968 bytes (127.0.0.1:7003, sending 0.0 bytes a second): every process sending to such a socket waits until it drains. A peer that reads slowly holds it up, and with send_timeout infinity (1 of them) for ever: set send_timeout and send_timeout_close; a bulk sender wants a higher high_watermark and sndbuf",
   "warning: 4 TCP sockets owned by quotes:quote/3 make small writes (6 bytes on average, 169.2 a second) with Nagle's algorithm on (nodelay false), 2.0 writes for every read: each message written in pieces. Nagle holds a write back until the previous one is acknowledged, and the peer delays its acknowledgement, up to 40 ms on Linux, so every such message waits that long. {nodelay, true}, or the message in one write (an iolist)",
   "info: 4 TCP sockets owned by quotes:pricing/1 make small writes (4 bytes on average, 84.8 a second) with Nagle's algorithm on (nodelay false), one per read: Nagle costs only when a write follows another before it's acknowledged, which a request/response exchange doesn't do; {nodelay, true} anyway if any message is written in pieces"],
 "groups": [
   {"owner": "quotes:collect/1", "sockets": 1, "bytes_per_s": {"in": 70544.7, "out": 0.0},
    "options": {"active": true, "packet": "line", "nodelay": false}, "owner_mailbox_max": 131045},
   {"owner": "quotes:quote/3", "sockets": 4, "sends_per_s": 169.2,
    "options": {"active": false, "packet": "line", "nodelay": false}},
   {"owner": "quotes:load/1", "sockets": 1, "bytes_per_s": {"in": 1022.0, "out": 0.0}},
   "..."]}
```

Then **`module_code`** on `quote/3`, `collect/1`, `load/1` and
`export/2`, **`process_info`** on the collector (26.8 MB, its mailbox
growing), and **`ets_table`** on `quote_latency`: the first quote on
each connection took 132 to 284 µs, every later one about 40,700 µs.

**The answer.** Three socket bugs, one per symptom. `quote/3` writes
`QUOTE ` and then the sku: with Nagle on, the second write waits for
the first's acknowledgement, which the backend delays by 40 ms, so
every quote but a connection's first takes 40 ms. The collector's
`{active, true}` socket turns every line into a message, about 70 KB a
second, faster than it stores them, so its mailbox and the node's
memory grow; the `quote_latency` table, never trimmed, grows too. And
the export is limited to the loader's kilobyte a second; with
`send_timeout` infinity the exporter waits in `gen_tcp:send` for ever.

**Fixes.**

- **Quotes:** one write per request (`["QUOTE ", Sku, "\n"]`), and
  `{nodelay, true}` on both ends.
- **The collector:** `{active, once}` or `{active, N}`, re-armed as it
  goes, so TCP slows the agent; and a cap on `quote_latency`.
- **The export:** a loader that reads as fast as it can, and
  `{send_timeout, 30000}` with `{send_timeout_close, true}` on the
  exporter, so a stalled peer is an error, not a hang.

The agent changed nothing on the node.

---

## Cleaning up

```sh
examples/elixir/run.sh stop
examples/erlang/run.sh stop
```

stops every Elixir and Erlang demo node, and `examples/emqx/run.sh stop`,
`examples/ejabberd/run.sh stop`, `examples/rabbitmq/run.sh stop`,
`examples/container/run.sh stop` and `examples/sockets/run.sh stop`
remove the Docker ones. The other languages' demos
(`examples/erlang`, `examples/gleam`, `examples/lfe`) have the same
bugs and more, each with its own `run.sh`; see the
[demo targets](../README.md#demo-targets) table.
