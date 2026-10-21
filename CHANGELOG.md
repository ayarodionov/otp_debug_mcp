# Changelog

## Unreleased

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
