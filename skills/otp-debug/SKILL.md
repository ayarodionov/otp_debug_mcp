---
name: otp-debug
description: Debug a running Erlang/Elixir/OTP node with the otp-debug MCP server. Use when the user asks to investigate a live BEAM system - memory growth, slowness, stuck processes, crashes, message queue buildup - or mentions connecting to a running node.
---

# Debugging a live OTP node

You have the `otp-debug` MCP tools. Follow this playbook; do not improvise
raw introspection when a purpose-built tool exists.

## Workflow

0. **A node that already died?** No connection is needed:
   `crash_dump(path)` on its `erl_crash.dump` says why (the slogan's
   meaning, the biggest processes and mailboxes with their stacks, what
   was in the longest mailbox). Ask the user to copy the dump to this
   machine if it's on another one, or in a container or pod. A dump has
   no logs: if the node is back up, `recent_errors` there shows what led
   to it.
1. **Connect first.** `connect(node, cookie?)`. If the user didn't give a node
   name, ask for it (and check `epmd -names` on the target host for candidates).
   If connection fails, relay the hint in the error — it's usually the cookie
   or shortname/longname mismatch.
2. **Always start with `diagnose`.** Findings come ranked worst-first with
   interpretations. Report the top findings to the user before drilling in.
   If `connect` reports a `cluster`, run `cluster` (compare) first instead:
   the node that stands out from the others is usually where the problem
   is. `connect` to it, then `diagnose` there.
3. **Drill into offenders**, don't re-scan:
   - Big message queue → `process_info` on that pid (with `include_state` for
     gen_servers); its `current_function` shows what it's stuck on. Then
     `trace_calls` on the module it's blocked calling.
   - `process_info` also gives the process's age, estimated from pid order
     (`younger_than_seconds` is a hard bound), and its supervisor's restart
     history. A young process under a supervisor with recent restarts is a
     restarted child, and `exited_during_check` means it just died again:
     look at `supervisor_restarts` for why.
   - OS memory (RSS) far above `memory_breakdown`'s total →
     `run_check(allocator_fragmentation)`: memory held in partly empty
     allocator carriers, and which allocator holds it.
   - Memory suspicion → `run_check(binary_leak)`, `run_check(ets_tables)`,
     then `snapshot(take)` → wait 30-60s of real load → `snapshot(diff)`.
     Only a growing delta proves a leak.
   - Intermittent failures or crash reports → `run_check(supervisor_restarts)`:
     its `restarting_children` carry the exit reason and stack trace (file
     and line) when a child dies during the sample; then `trace_calls` on
     the crashing function to see its arguments.
   - Errors the numbers don't show (users see failures, the node looks
     healthy) → `recent_errors`: crashes grouped by who and why, with the
     stack and the arguments of a `function_clause`, logged errors and
     warnings with where they were logged, and the errors in the node's log
     files from before it listened (an error at boot is there). For rare
     errors, `watch_minutes` keeps listening in the background; call it
     again later, and with `stop: true` when done.
   - CPU suspicion → `run_check(schedulers)` first; OS CPU% lies about the
     BEAM (busy-wait). Only if schedulers are pegged, use `top_reductions`,
     then `profile` on the module the top process is running, to see which
     functions use the time. Narrow it to a function or a process if the
     module is busy. `profile` counts only time spent running: a function
     that's slow because it waits (receive, sleep, calls to other
     processes) shows little time, and `trace_calls` timestamps show it.
   - A function you can't find in the source, or a stack frame in a
     library's file (`gen_server.ex:887`, a router, a schema) →
     `module_code`: which functions a macro generated (`use GenServer`,
     routers, DSLs), the code that actually runs after macro expansion,
     and which function a `file:line` is in. Then trace or profile those
     functions by name like any other. On a stripped release the code is
     BEAM assembly, but where each function came from is still there.
4. **Confirm trends before concluding.** One snapshot is a guess; a diff is
   evidence. Prefer two diffs 60s apart for leak claims.

## Safety rules (production nodes)

- Keep `trace_calls` limits small: ≤20 events, ≤10s, one module at a time.
  Never trace `gen_server` / `gen` / commonly-hot stdlib modules themselves.
- If `trace_calls` is refused because other tracing is active (this only
  happens on pre-OTP 27 nodes), someone may be debugging this node right now. Show the user what the refusal found
  and ask before retrying with `force: true`; forcing ends their tracing.
  Never set `force` on your own.
- Keep `profile` to one module and a few seconds on production nodes:
  counting slows every profiled call. Use `all_modules` only when the user
  agrees, and as with `trace_calls`, never set `force` on your own: show the
  user what the refusal found and ask first.
- `trace_port` shows real traffic (truncated): keep it short on production
  nodes, and as with `trace_calls`, never set `force` on your own.
- `process_info` with `include_state` sends a sys message to the process;
  skip it for processes already showing huge message queues.
- Do not use `remote_eval` unless the purpose-built tools can't answer AND
  the user has enabled it; never eval anything that mutates state without
  the user explicitly approving that exact expression.
- Use `load_module` only when the user asks to try a fix on the node.
  Compile it first, with the target's OTP major version or an older one,
  and pass the `.beam`. The server shows the user an approval dialog. Tell
  them it's coming, and that the change lasts until the node restarts. If
  they decline, don't call it again unless they ask. After a load, check
  the fix with `diagnose`, `run_check` or `trace_calls`. Remind them that
  the real fix still needs deploying, and that `revert` undoes the load.
- `binary_leak` force-GCs processes — cheap, but mention it when running
  against production.

## Interpreting common patterns

- Queue growing on one process, many callers blocked in `gen_server:call` →
  single-process bottleneck; look for serialization through one gen_server
  (registry, single db connection, ets owner doing writes).
- `memory.binary` high and `binary_leak` finds big releases → refc binary
  leak; fix is `binary:copy/1` on retained sub-binaries or hibernation.
- `atom_table` with `growth_per_second` > 0, or `atom_count` growing in a
  diff → dynamic atom creation from input (both exclude the atoms this
  tool itself sends); `seconds_until_full` is when the node dies. Grep for
  `String.to_atom`, `list_to_atom`, `binary_to_term` without `:safe`.
- All schedulers ~1.0 → genuine CPU saturation. One scheduler pegged, rest
  idle, or latency spikes for every process now and then → native code
  holding a scheduler: `long_schedules` names the process (anything over
  10 ms there is a NIF or BIF), `module_code` marks its modules' NIFs,
  `trace_calls`/`profile` time them. A dirty CPU run queue that stays above
  zero → more dirty NIF work than the dirty schedulers can do.
- Port count climbing, sends blocking, or OS processes piling up → ports:
  `ports` (in `diagnose`) gives types, the owners holding most, write
  queues (`owner_blocked`: stuck sending to a slow peer) and external
  programs; a snapshot diff's `port_delta_by_type`/`port_delta_by_owner`
  name the leaking code; `port_info` for one port's socket options and
  stats; `trace_port` with `opened: true` shows who opens ports and whether
  they close. Sockets of the `socket` backend aren't ports: `ports` counts
  them, the other port tools don't see them.
- OS memory growing while `erlang:memory()` is flat → native memory:
  `native_memory`, then snapshot diffs (`native_memory_delta_mb` growing
  with `memory_delta` flat is a NIF or driver leak), then `native_code` for
  the libraries. A NIF crash takes the node down: no tool helps afterwards;
  suggest core dumps and OTP's debug/ASan emulators for the NIF's tests.
- `supervisor_restarts` with recent restarts → a crash loop. Below
  `max_restarts` it never fails over and shows up only as intermittent
  errors; `at_limit` means one more crash takes the supervisor and its
  siblings down. Restart churn also puts the supervisor at the top of
  `top_reductions`; that's not a CPU problem.
- Process count climbing in diffs → process leak: spawned tasks/monitors
  never terminating; check `supervision_tree` for unexpectedly huge
  simple_one_for_one/DynamicSupervisor child counts.
- `supervision_tree` shows each supervisor's restart history: the subtree
  with recent restarts is where a crash loop lives, and its strategy says
  what restarts with the crashing child (one_for_all: all its siblings).
