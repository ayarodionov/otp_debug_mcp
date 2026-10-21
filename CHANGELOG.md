# Changelog

## Unreleased

- `cluster`: every node of the target's cluster at once. `compare` puts key
  metrics side by side, flags the nodes that stand out from the others, and
  finds partitions (members that don't see each other); `diagnose` runs
  the full diagnose on every node; `snapshot_take` and `snapshot_diff` show
  which node grows. Members are discovered through each node's own view,
  so a node partitioned from the current target is still found.
- `connect` says when the node is in a cluster.
- `process_info` names the parent of a process no supervisor started, and
  says nothing restarts it; its age explanation says what the estimate is
  based on.
- Better advice: `message_queues` says to trace the sending side to find
  who floods a mailbox, and `top_reductions` that a busy process matters
  even when the schedulers aren't saturated.
- `atom_table` measures atom growth over a second (not counting the tool's
  own atoms) and how long until the table is full: critical if within a
  day, a warning for any growth. `diagnose` used to call a node leaking
  hundreds of atoms a second healthy.
- Terms from plain Erlang nodes are shown in Erlang syntax; Elixir nodes
  keep Elixir syntax.
- Trace timestamps are in UTC, marked `Z`, like snapshot times.
- `memory_breakdown` explains `other_system`, and `allocator_fragmentation`
  marks `ll_alloc`'s slack as normal.
- `examples/erlang`: demo targets in plain Erlang/OTP.

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
