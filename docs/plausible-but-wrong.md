# Plausible but wrong, on a live node

Each chapter of [Learning Erlang from Claude](https://github.com/ayarodionov/Learning-Erlang-from-Claude)
and [Learning Elixir from Claude](https://github.com/ayarodionov/Learning-Elixir-From-Claude)
has a "Plausible but wrong" section: code that compiles and passes a
happy-path test, and fails under crashes, timing or load. The books teach
spotting it in review. This page shows what happens when it got past
review and runs: six of those examples, each on a node of its own, given
to an agent with only the symptom.

How it was run:

- **The nodes.** Each node runs the book's code, with a few lines around
  it to give it traffic.
- **The agent.** It was a headless `claude -p` session per node, with only
  the otp-debug tools: no shell, no file access and no source tree. It
  found the code with `module_code`, from the running .beam files.
- **The prompts.** Each prompt was the symptom as an operator would report
  it, followed by "Use the otp-debug tools; the node is live. End with the
  cause and the fix."

The nodes are in [examples/books](../examples/books): `examples/books/run.sh
all` starts them, and its README lists the symptom to give for each.

All six found the cause and the book's fix, in 42–75 seconds and for
$0.28–0.67 each. One run found a bug in this tool, fixed since (see
[Two servers calling each other](#two-servers-calling-each-other)).

| Book example | Symptom given | What found it |
| --- | --- | --- |
| [Two servers calling each other](#two-servers-calling-each-other) (Erlang 5.4.6) | the totals page sometimes hangs 5 s, then fails | `recent_errors`, `call_chains` |
| [Keeping a small slice of a huge binary](#keeping-a-small-slice-of-a-huge-binary) (Erlang 3.4.3) | memory grows to hundreds of MB | `diagnose` (binary_leak) |
| [A receive loop with no catch-all](#a-receive-loop-with-no-catch-all) (Erlang 2.4.1) | the counter answers more and more slowly | `diagnose`, `process_info`, `snapshot` |
| [Permanent per-connection workers](#permanent-per-connection-workers) (Erlang 1.4.5) | all 50 connections drop at once, though one client sends bad data | `diagnose`, `recent_errors` |
| [Parsing by catching exceptions](#parsing-by-catching-exceptions) (Elixir 2.4.1) | many ports counted invalid, nothing logged | `trace_calls` with `exceptions: true` |
| [A handler that raises once and disappears](#a-handler-that-raises-once-and-disappears) (Elixir 13.4.4) | db.query metrics went flat | `telemetry`, `trace_calls` |

## Two servers calling each other

Erlang book, chapter 5, section 4.6:

```erlang
%% in a:handle_call(get_total, ...)
Total = gen_server:call(b, sum),
%% in b:handle_call(sum, ...)
Rate = gen_server:call(a, rate),
```

On the node, `tally:get_total` calls `rates:sum`, and `rates:refresh`
calls `tally:rate`. Each request works alone. When the two overlap, each
server waits for the other until the 5-second timeout, then both crash
and are restarted.

*Symptom:* "the totals page sometimes hangs for about 5 seconds and then
fails."

`recent_errors` caught both halves of the cycle crashing in the same
millisecond, and showed how one timeout passed on to the other:

```
tally  {timeout,{gen_server,call,[rates,sum]}}                                   tally.erl:26, handling get_total
rates  {{timeout,{gen_server,call,[rates,sum]}},{gen_server,call,[tally,rate]}}  rates.erl:13, handling refresh
```

`module_code` on both `handle_call/3` functions showed the calls and their
lines. Since these runs, `recent_errors` puts the two together itself, as
a deadlock:

```
deadlocks: [{times: 2, calls: [
  {who: rates, was_calling: tally, request: "rate"},
  {who: tally, was_calling: rates, request: "sum"}]}]
```
 The fix it gave: make one direction a cast, or reply later from
another process with `gen_server:reply/2`, so neither calls the other from
inside a callback. It also noted that a longer timeout only makes the hang
longer.

While the deadlock lasts, `diagnose` reports it directly through its
`call_chains` check (status critical):

```
deadlocks: [[
  {name: rates, waits_on: "a call to tally (<0.10683.0>)", call: "gen_server:call/2", request: "rate", timeout: 5000},
  {name: tally, waits_on: "a call to rates (<0.10682.0>)", call: "gen_server:call/2", request: "sum",  timeout: 5000}
]]
```

**This example found a bug in otp_debug_mcp 0.6.0.** In 0.6.0,
`call_chains` read the request only from `gen_server:call/3` frames, and
failed on these calls, which take the default timeout. `diagnose`
returned "Internal error". The session fell back to individual checks and
still found the cause, but the check that exists for this bug failed on its
most common form. It's fixed in 0.7.0.

## Keeping a small slice of a huge binary

Erlang book, chapter 3, section 4.3:

```erlang
handle_info({http_body, Body}, State) ->   %% Body is 10 MB
    <<_:32/binary, Header:512/binary, _/binary>> = Body,
    {noreply, State#{last_header => Header}}.
```

On the node, 1 MB bodies arrive every 50 ms, and the server keeps the
header for each of 200 sessions.

*Symptom:* "memory keeps growing to hundreds of MB, though it stores
little."

The first `diagnose` answered it. The `binary_leak` check names the
process, and `held_binaries` samples what its state holds:

```
largest_holders: [{registered_name: headers, binary_bytes: 210873120, share_of_binary_memory: 0.92,
  held_binaries: {sampled: 200, bytes_kept: 102400, bytes_pinned: 209824000,
                  looks_like: "slices pinning larger binaries: binary:copy/1 the slices before keeping them"}}]
```

That is 100 KB of headers pinning 210 MB of bodies. The session read
`handle_info/2` with `module_code`, checked with `snapshot` that memory was
pinned rather than still climbing (the session keys are reused), and gave
the book's fix: `binary:copy(Header)` before storing it.

## A receive loop with no catch-all

Erlang book, chapter 2, section 4.1:

```erlang
loop(State) ->
    receive
        {add, X}   -> loop(State + X);
        {get, From} -> From ! State, loop(State)
    end.
```

On the node, the checkout sends `{add, 10}`, and refunds, added later, send
`{sub, 10}`, which the loop doesn't match.

*Symptom:* "the counter answers more and more slowly, and the node's
memory keeps growing."

`diagnose` flagged `counter`: 2,139 messages, then 2,776 a few seconds
later, at 410k reductions/s on an otherwise idle node. `process_info`
showed it waiting in `counter:loop/1` with no supervisor. `module_code`
showed the two clauses, and the `{sub, 10}` sent by `refunds/0`. A
`snapshot` diff measured the queue growing by 50 messages a second, the
rate `refunds/0` sends at. The session explained the slowdown as the book
does: every receive rescans the unmatched messages. It also found a
second bug, that refunds are never subtracted. Its fix handles `{sub, X}`
and logs and drops anything else.

## Permanent per-connection workers

Erlang book, chapter 1, section 4.5:

```erlang
init([]) ->
    {ok, {#{strategy => simple_one_for_one},
          [#{id => conn, start => {conn, start_link, []}}]}}.
```

On the node, 50 connections run under that supervisor with its defaults,
and every 20 seconds one client sends `<<"12,5">>` twice, a second apart.

*Symptom:* "all 50 client connections are dropped at once every so
often, though at most one client sends bad data."

`diagnose` showed `conn_sup` itself being restarted by its parent.
`recent_errors` caught the sequence:

```
conn        badarg in erlang:binary_to_integer/1, conn.erl:20, called_with [<<"12,5">>], last message {line,<<"12,5">>}
conn_sup    reached_max_restart_intensity, offender {conn,start_link,[19]}, restart_type permanent
gateway_sup child_terminated conn_sup: shutdown
```

Reading `init/1` with `module_code`, the session explained the cause. With
no intensity or period, the supervisor uses the defaults: one restart in
five seconds, for all children together. Its fix was the book's (`restart
=> temporary`, or limits sized for 50 children), together with handling
the bad line in `handle_cast`.

## Parsing by catching exceptions

Elixir book, chapter 2, section 4.1:

```elixir
def parse_port(s) do
  try do
    {:ok, String.to_integer(s)}
  rescue
    ArgumentError -> {:error, :invalid}
  end
end
```

On the node, a GenServer parses an upstream port every 10 ms. Half the
inputs are untidy (`""`, `"http"`, `"80 "`, `"65536x"`).

*Symptom:* "the Gateway counts many upstream ports as invalid, but logs
nothing."

Nothing crashes and nothing is logged, so `diagnose` and the logs show a
healthy node. After reading `parse_port/1` with `module_code`, the session
traced only the calls that raise:

```
trace_calls module: erlang, function: binary_to_integer, exceptions: true

<0.101.0> erlang:binary_to_integer(<<"65536x">>)
<0.101.0> erlang:binary_to_integer/1 raised error:badarg
<0.101.0> erlang:binary_to_integer(<<"80 ">>)
<0.101.0> erlang:binary_to_integer/1 raised error:badarg
<0.101.0> erlang:binary_to_integer(<<"http">>)
...
```

That gave it each input that fails and how. Its fix was the book's:
`Integer.parse/1`, checking that nothing is left over. It added trimming,
a range check, and logging the reason for each rejection.

The session had to choose which function to trace, from the code. Since
these runs, the process is enough: `trace_calls` with `process:
"Gateway"`, `exceptions: true` and no module reports every function that
raises in it, and where it was called:

```
<0.101.0> erlang:binary_to_integer(<<"80 ">>) from 'Elixir.Gateway':parse_port/1 (examples/books/elixir/gateway.ex:10)
<0.101.0> erlang:binary_to_integer/1 raised error:badarg
```

## A handler that raises once and disappears

Elixir book, chapter 13, section 4.4:

```elixir
def handle_event([:repo, :query], %{total_time: t}, %{source: source}, _) do
  Metrics.observe("db.query", t, table: String.to_existing_atom(source))
end
```

On the node, queries run ten times a second. About 30 seconds after
start, one raw SQL query has no `:source`.

*Symptom:* "our db.query metrics went flat after the node had run for a
while, but the node still runs queries."

`telemetry` with `list: true` found no handlers on the node. Listening to
`repo.query` for 3 seconds caught 30 events, so the queries still happen.
A `trace_calls` on `Metrics` caught no calls to `handle_event/4`. With
`module_code`, the session found the one clause that requires `:source`,
and the query at iteration 300 that has none. It explained that telemetry
detaches a handler that raises, and that the node's only record of it was
one line on the console. Its fix was a clause that doesn't require
`:source`, consistent metadata from the caller, and logs kept somewhere.

`recent_errors` couldn't help here: the detach was logged once, 30
seconds before the session, and only to the console. A node with log files
keeps it, and `recent_errors` reads those. Since this run, a `list: true`
that finds no handler says what that usually means (0.7.0).

## What this shows

These bugs leave the node running: nothing alarms, and nothing crashes
except the code involved. Review is where the books catch them. On a live
node, the evidence is the mailbox, the binaries a process pins, crash
reports read in order, an exception raised and then rescued, and a
handler table with nothing left in it. otp_debug_mcp gives an agent
that evidence, and the agent can then read the running code to explain it.
