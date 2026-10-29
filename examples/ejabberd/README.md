# ejabberd demo

ejabberd, the XMPP server, in Docker, with clients that run into three
problems at once, for the `ejabberd` tool:

- **A bot that reads slowly.** Five order services, `sender1` to
  `sender5@localhost`, each send ten order notifications a second to the
  logger bot `slowbot@localhost`, which reads its socket at 1 KB a
  second. ejabberd's c2s process for the bot queues what it can't send,
  on its heap, until the send times out and the socket's closed; the
  session stays, still working through its queue.
- **The archive on Mnesia.** ejabberd's default configuration archives
  every message (mod_mam) in Mnesia, in a disc_only_copies table: a
  dets file that every recipient's c2s process waits on before passing a
  message on.
- **A support desk nobody reads.** The services also send one message a
  second to `support@localhost`, which nobody logs in as: its offline
  queue fills to `max_user_offline_messages` (100), and the rest bounce.

```sh
examples/ejabberd/run.sh start    # docker run ghcr.io/processone/ejabberd:26.09, users, clients.py
examples/ejabberd/run.sh stop
```

It needs Docker and Python 3 (no XMPP library: `clients.py` speaks
enough XMPP itself, STARTTLS and SASL PLAIN included). The first start
pulls the image. The backlog takes a few minutes to build, until the
socket's buffers are full.

## Connecting

ejabberd runs as `ejabberd@localhost` with the cookie `ejabberddemo`. It
listens for distribution on port 5210 and doesn't use epmd, so the
server dials that port directly: register one for it, next to your
usual one, with

```sh
claude mcp add otp-debug-ejabberd --scope user \
  -e ERL_FLAGS="-erl_epmd_port 5210" -e OTP_DEBUG_MCP_COOKIE=ejabberddemo \
  -- "$server" start
```

(`-erl_epmd_port` makes the server dial that port for every node, so it
reaches only nodes on it: see [docs/production.md](../../docs/production.md).)
Then ask, for example:

> Order notifications to our logger bot, slowbot@localhost, arrive late
> or not at all, and ejabberd's memory keeps growing. Messages to
> support@localhost go missing too. ejabberd is `ejabberd@localhost`.
> Find out why.

Walkthrough 29 in [docs/walkthroughs.md](../../docs/walkthroughs.md).
