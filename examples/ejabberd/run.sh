#!/bin/sh
# ejabberd demo for otp_debug_mcp: ejabberd in Docker, and XMPP clients
# (clients.py): order services messaging a logger bot that reads slowly,
# and a support desk nobody logs in to.
#
#     examples/ejabberd/run.sh start    # ejabberd, its users, its clients
#     examples/ejabberd/run.sh stop     # all gone
#
# ejabberd runs as ejabberd@localhost, cookie ejabberddemo. It listens
# for distribution on port 5210 without epmd, so the server must dial
# that port directly: register one for it with
# ERL_FLAGS="-erl_epmd_port 5210" (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=ghcr.io/processone/ejabberd:26.09

case "${1:-}" in
  start)
    docker rm -f ejabberd_demo >/dev/null 2>&1 || true
    docker run -d --name ejabberd_demo \
      -e ERLANG_NODE_ARG=ejabberd@localhost -e ERLANG_COOKIE=ejabberddemo -e ERL_DIST_PORT=5210 \
      -p 5222:5222 -p 5210:5210 -p 5280:5280 "$image" >/dev/null
    for _ in $(seq 1 60); do
      docker exec ejabberd_demo ejabberdctl status >/dev/null 2>&1 && break
      sleep 2
    done
    for user in slowbot support sender1 sender2 sender3 sender4 sender5; do
      docker exec ejabberd_demo ejabberdctl register "$user" localhost secret >/dev/null
    done
    nohup python3 "$here/clients.py" >"$here/clients.log" 2>&1 &
    echo $! >"$here/clients.pid"
    echo "ejabberd running as ejabberd@localhost (cookie ejabberddemo), with its clients"
    ;;
  stop)
    if [ -f "$here/clients.pid" ]; then kill "$(cat "$here/clients.pid")" 2>/dev/null || true; rm -f "$here/clients.pid"; fi
    docker rm -f ejabberd_demo >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
