# Walkthroughs

Four debugging sessions against the demo nodes in `examples/`, start to
finish, for following along on your own machine. Each one gives the
command that starts the demo, the prompt, every tool call the agent made
with the part of its result that mattered, and the conclusion. The
results are real, recorded from Claude Code with the `otp-debug` skill
installed (OTP 28, Elixir demos), trimmed to the fields that drove each
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
5. [Cleaning up](#cleaning-up)

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

## Cleaning up

```sh
examples/elixir/run.sh stop
```

stops every Elixir demo node. The other languages' demos
(`examples/erlang`, `examples/gleam`, `examples/lfe`) have the same
bugs and more, each with its own `run.sh`; see the
[demo targets](../README.md#demo-targets) table.
