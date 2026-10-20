# Changelog

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
