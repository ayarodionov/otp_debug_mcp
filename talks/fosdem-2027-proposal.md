# FOSDEM 2027 talk proposal

For the BEAM devroom, "Erlang, Elixir, Gleam and Friends", on Saturday
30 January 2027 in Brussels. The call for talks
(https://beam-fosdem.dev/call-for-talks/) closes on 3 December 2026.
Submit at https://pretalx.fosdem.org/fosdem-2027/cfp: log in, choose
"Submit a proposal", and pick the track "Erlang, Elixir, Gleam and
Friends". The form needs a title, an abstract and submission notes.

## Title

What an AI agent needs to know to debug a live BEAM node

Alternative: otp_debug_mcp: letting an AI agent debug live Erlang and
Elixir systems, safely

## Abstract

Ask an AI agent to find out why a production node is slow, give it a
shell and `:observer`, and it will guess. Give it a remote console, and
it can take the node down. otp_debug_mcp is an open source MCP server,
written in Elixir, that does something in between. It attaches to a
running node as a hidden node, loads nothing there but recon, and gives
the agent procedures rather than primitives: health checks that rank
their findings and explain them, tracing with hard limits on volume, and
read-only views into the systems people run without having written
them, such as RabbitMQ, EMQX, ejabberd, Phoenix LiveView, Mnesia and
riak_core.

This talk is about what building that taught me about the BEAM, more
than about AI. To an agent, "the mailbox is fine" is a wrong answer when
ejabberd's p1_server keeps the real backlog in `$internal_queue_len`. A
LiveView leak can be invisible in a short window, because heaps grow in
steps. A request takes 40 ms on Linux and 60 µs on a Mac because of
Nagle and delayed acknowledgements. Eight schedulers in a one-CPU
container make the kernel stop the whole VM. Each lesson became a tool,
and a demo with a real bug.

Every one of the 35 demos is also a test. An agent gets only the
symptom, as a user would describe it, and must find the cause. These
blind sessions now run as a regression suite, and they have found
mistakes in the tools that no unit test caught. I'll show some live,
and show where the agent still gets it wrong.

## Submission notes

- **Preferred slot:** long (40 minutes, Q&A included). A short
  (20 minutes) slot is fine too: I'd then drop to two live demos and
  leave out the testing part.
- **Audience and prior knowledge:** people who run Erlang, Elixir or
  Gleam systems, or will. It helps to know what a process, a mailbox and
  a supervisor are. No AI or machine-learning background is needed. Most
  of the talk is about runtime internals and how to diagnose problems,
  and the agent is the reason to make them explicit.
- **Outline (40 minutes):**
  1. Why raw remote access is the wrong interface for an agent, and what
     a hidden node with read-only procedures looks like instead (5 min).
  2. A live session: a symptom in plain words, the agent's tool calls,
     its conclusion (8 min).
  3. Five things the runtime hides from a naive look: internal queues,
     heap growth in steps, Nagle with delayed ACKs, CPU quotas against
     scheduler counts, and RabbitMQ consumers without a prefetch limit
     (12 min).
  4. Safety: rate-limited tracing in isolated trace sessions (OTP 27 and
     later), approval of every step, what goes to the AI provider
     (5 min).
  5. Testing an agent's tools with blind sessions, and what they caught
     (5 min).
  6. Q&A (5 min).
- **The project:** https://github.com/ayarodionov/otp_debug_mcp (MIT
  licensed). The recorded sessions are in docs/walkthroughs.md, and the
  demos are in examples/.

Before submitting: check the numbers (demos, walkthroughs, tools), which
date from November 2026, and plan a recorded fallback for the live
demos, in case the room's network doesn't let the agent reach the
model's API.

## Slide outline

About 22 slides for the 40-minute slot. A 20-minute version keeps slides
1–4, 6–8, 10, 12, 14, 16 and 22.

**1. Opening**

1. **Title.** What an AI agent needs to know to debug a live BEAM node.
   Name, link to the repository.
2. **The question.** "shop@prod-3 is slow and growing; find out why."
   What a person does: connect, look, form a hypothesis, check it.
3. **Two bad interfaces.** A shell and observer (the agent guesses from
   screenshots and logs); a remote console (`erlang:halt()` is one typo
   away). Neither says what's normal.
4. **What otp_debug_mcp does.** A hidden node; nothing loaded but recon;
   tools that return ranked findings with an interpretation and a next
   step; tracing with caps on events and time. A diagram: Claude Code →
   MCP over stdio → the server → Erlang distribution → the target.

**2. A live session**

5. **The setup.** `examples/erlang/run.sh inventory`. The prompt:
   "Reservations sometimes take a third of a second, though a
   reservation is a map update; its mailbox never looks long."
6. **Live (or recorded).** `connect`, `diagnose` (nothing over
   threshold), `call_latency`: reservations wait 308 ms (p95) in the
   mailbox, handled in 0.0 ms; `stock_report` is 99% of the server's busy
   time.
7. **The conclusion.** Its own words, and `module_code` on the
   function that takes the time. 46 seconds, 9 tool calls.

**3. What the runtime hides**

8. **The mailbox isn't the queue.** ejabberd's c2s processes:
   `message_queue_len` 3, `$internal_queue_len` 16,286. p1_server moves
   the mailbox onto the heap. The tool's first version looked at the
   mailbox and found nothing.
9. **Memory grows in steps.** A LiveView's `orders` assign gained 101
   items in 10 seconds while process memory looked flat. The fix: read
   the growing data itself (the assigns) at both ends of the window.
10. **40 ms on Linux, 60 µs on a Mac.** A request written in two pieces,
    Nagle's algorithm and delayed ACKs. A timeline diagram of the four
    packets. The signal: writes per read ≥ 2 with `nodelay` false.
11. **The kernel stops the VM.** `+S 8:8` in a one-CPU container: the
    quota is spent in 12 ms of a 100 ms period, then nothing runs.
    Health check 81 ms late against 7.7 ms with `+S 1:1`. cgroup
    `cpu.stat` gives throttled periods.
12. **Unacknowledged is in memory.** RabbitMQ with no prefetch: 20,000
    delivered-but-unacked orders, a memory alarm, every publisher
    blocked. The agent first read the growth as "acks nothing"; adding
    the ack rate fixed that.
13. **The pattern.** Each lesson is "measure the thing itself, not a
    proxy". Each became a tool, a test and a demo.

**4. Safety**

14. **Tracing that can't melt a node.** Caps on events and time, an
    early stop when messages pile up; on OTP 27+, isolated trace
    sessions that leave other tracing alone; callbacks traced by arity,
    so a GenServer's state is never copied.
15. **Asking first.** `OTP_DEBUG_MCP_CONFIRM=all|changes`; `remote_eval`
    off by default; `load_module` always asks.
16. **What leaves the machine.** Tool output goes to the AI provider:
    process state, traced arguments, ETS rows. Mind secrets.

**5. Testing an agent's tools**

17. **Blind sessions.** The demo starts, the agent gets the symptom and
    only the otp-debug tools, in an empty directory; the conclusion must
    name the cause. `scripts/blind_eval.py`, one case per walkthrough.
18. **What they caught.** The ejabberd mailbox, the flat LiveView
    memory, the RabbitMQ ack misreading: each passed its unit tests and
    failed in front of an agent.
19. **What it costs.** About 45–90 seconds and $0.35 a session; a few
    dollars for the whole suite; not in CI.
20. **Where the agent still gets it wrong.** It reads demo simulators as
    production code; it can over-claim from one sample; it can't see
    beyond the node (the network, the OS) without other tools.

**6. Closing**

21. **Try it.** Release tarballs, the Docker image, `claude mcp add`;
    the demos in `examples/`; walkthroughs in `docs/walkthroughs.md`.
22. **Questions.** The repository link; an ask: run it on a real system
    and report what it got wrong.
