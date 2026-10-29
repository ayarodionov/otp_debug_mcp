#!/bin/sh
# EMQX demo for otp_debug_mcp: EMQX 5 in Docker, and MQTT clients that
# misbehave (clients.py).
#
#     examples/emqx/run.sh start    # EMQX, and its clients
#     examples/emqx/run.sh stop     # both gone
#
# EMQX runs as emqx@127.0.0.1, cookie emqxdemo. It listens for
# distribution on port 4370 without epmd, so the server must dial that
# port directly: register one for it with ERL_FLAGS="-erl_epmd_port 4370"
# (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=emqx/emqx:5.8.6

case "${1:-}" in
  start)
    docker rm -f emqx_demo >/dev/null 2>&1 || true
    docker run -d --name emqx_demo \
      -e EMQX_NODE__NAME=emqx@127.0.0.1 -e EMQX_NODE__COOKIE=emqxdemo \
      -p 1883:1883 -p 4370:4370 -p 18083:18083 "$image" >/dev/null
    for _ in $(seq 1 60); do
      docker logs emqx_demo 2>&1 | grep -q "is running now" && break
      sleep 2
    done
    nohup python3 "$here/clients.py" >"$here/clients.log" 2>&1 &
    echo $! >"$here/clients.pid"
    echo "EMQX running as emqx@127.0.0.1 (cookie emqxdemo), with its clients"
    ;;
  stop)
    if [ -f "$here/clients.pid" ]; then kill "$(cat "$here/clients.pid")" 2>/dev/null || true; rm -f "$here/clients.pid"; fi
    docker rm -f emqx_demo >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
