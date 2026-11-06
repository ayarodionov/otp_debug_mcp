# FOSDEM 2027 talk proposal: short (20 minutes)

The 20-minute version of [fosdem-2027-proposal.md](fosdem-2027-proposal.md),
for the BEAM devroom, "Erlang, Elixir, Gleam and Friends", on Saturday
30 January 2027. The call (https://beam-fosdem.dev/call-for-talks/)
closes on 3 December 2026; submit at
https://pretalx.fosdem.org/fosdem-2027/cfp, track "Erlang, Elixir,
Gleam and Friends".

## Title

Debugging a live BEAM node with an AI agent: what it needed to know

## Abstract

otp_debug_mcp is an open source MCP server, written in Elixir, that lets
an AI agent such as Claude Code investigate a running Erlang, Elixir or
Gleam node. It attaches as a hidden node, loads nothing there but recon,
and gives the agent procedures instead of a remote console: health
checks that rank and explain their findings, tracing with hard limits,
and read-only views into RabbitMQ, Phoenix LiveView, ejabberd and more.

The agent's mistakes taught me what a careful human checks without
thinking. A mailbox can look empty while ejabberd's p1_server holds
16,000 messages on the heap. A request takes 40 ms on Linux and 60 µs on
a Mac because of Nagle's algorithm. Eight schedulers in a one-CPU
container make the kernel stop the whole VM. In 20 minutes: one live
session from symptom to cause, three of these lessons, and how blind
sessions, where the agent gets only the symptom, became the project's
regression suite.

## Submission notes

- **Slot:** short, 20 minutes including Q&A. That's the length the talk
  is written for; a long slot isn't needed. In a lightning slot
  (5 minutes) it would be the live session only.
- **Audience and prior knowledge:** people who run Erlang, Elixir or
  Gleam systems. Knowing what a process and a mailbox are is enough. No
  AI background is needed: the talk is about the runtime, and the agent
  is the reason to make it explicit.
- **Outline (20 minutes):**
  1. The idea: a hidden node and read-only procedures, not a shell
     (2 min).
  2. A live session: a symptom in plain words, the agent's tool calls,
     the cause (5 min).
  3. Three things the runtime hides: a queue that isn't the mailbox,
     Nagle with delayed ACKs, CPU quotas against scheduler counts
     (6 min).
  4. Blind sessions as tests, and what they caught (3 min).
  5. Questions (4 min).
- **The project:** https://github.com/ayarodionov/otp_debug_mcp (MIT
  licensed); recorded sessions in docs/walkthroughs.md, demos in
  examples/.

Before submitting: check the numbers, which date from November 2026,
and have a recording of the live session ready, in case the room's
network doesn't let the agent reach the model's API.

## Slide outline

Twelve slides, about a minute and a half each, and 4 minutes left for
questions.

1. **Title.** Debugging a live BEAM node with an AI agent: what it
   needed to know. Name, repository link.
2. **The problem.** "inventory_erl is slow; find out why." A shell lets
   an agent guess; a remote console lets it break things.
3. **The design.** Claude Code → MCP → otp_debug_mcp → a hidden node →
   the target. Nothing installed there but recon. Tools return ranked
   findings with an interpretation and a next step.
4. **Live: the symptom.** `examples/erlang/run.sh inventory`.
   "Reservations sometimes take a third of a second, though a
   reservation is a map update; its mailbox never looks long."
5. **Live: the tool calls.** `diagnose` finds nothing over threshold.
   `call_latency`: reservations wait 308 ms in the mailbox (p95) and
   take 0.0 ms to handle; `stock_report` is 99% of the server's time.
6. **Live: the answer.** Its conclusion and fix, in 46 seconds and
   9 tool calls. (Recorded fallback ready.)
7. **The queue isn't the mailbox.** ejabberd's c2s process:
   `message_queue_len` 3, `$internal_queue_len` 16,286. The tool's first
   version looked at the mailbox, and found nothing.
8. **40 ms on Linux, 60 µs on a Mac.** A request in two writes, Nagle
   and delayed ACKs; a four-packet timeline. Fix: one write, or
   `{nodelay, true}`.
9. **The kernel stops the VM.** `+S 8:8` with a one-CPU quota: the
   quota is gone in 12 ms of each 100 ms period. Health check 81 ms late
   against 7.7 ms with `+S 1:1`.
10. **Blind sessions as tests.** The agent gets only the symptom and the
    tools; its conclusion must name the cause. One case per demo,
    `scripts/blind_eval.py`, about $0.35 a session.
11. **What they caught.** The mailbox that wasn't the queue, LiveView
    memory that looked flat, RabbitMQ acks misread: each passed its unit
    tests and failed in front of an agent.
12. **Try it, and questions.** Releases, Docker image, `claude mcp add`;
    run it on a real system and tell me what it got wrong.
