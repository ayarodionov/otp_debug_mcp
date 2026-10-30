#!/bin/sh
# A sockets demo for otp_debug_mcp: an Erlang quotes service in Docker
# (Linux, where Nagle's algorithm and delayed acknowledgements show on
# loopback), with sockets set up the way code often leaves them.
#
#     examples/sockets/run.sh start
#     examples/sockets/run.sh stop
#
# It runs as quotes@127.0.0.1, cookie socketsdemo, listening for
# distribution on port 9400 without epmd: register a server for it with
# ERL_FLAGS="-erl_epmd_port 9400" (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=erlang:27-slim

case "${1:-}" in
  start)
    docker rm -f sockets_demo >/dev/null 2>&1 || true
    docker run -d --name sockets_demo --memory=1g -p 9400:9400 \
      -v "$here/src:/app/src:ro" "$image" sh -c '
        mkdir -p /app/ebin && erlc -o /app/ebin /app/src/*.erl &&
        exec erl -noinput -name quotes@127.0.0.1 -setcookie socketsdemo \
          -erl_epmd_port 9400 -pa /app/ebin -eval "ok = quotes:start()"' >/dev/null
    sleep 8
    echo "quotes service running as quotes@127.0.0.1 (cookie socketsdemo), in a container"
    ;;
  stop)
    docker rm -f sockets_demo >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
