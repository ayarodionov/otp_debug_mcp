#!/bin/sh
# A container demo for otp_debug_mcp: an Erlang pricing service in Docker,
# limited to one CPU and 256 MB, started with the vm.args it had on the
# machine it used to run on (8 schedulers, busy-waiting schedulers).
#
#     examples/container/run.sh start
#     examples/container/run.sh stop
#
# It runs as svc@127.0.0.1, cookie containerdemo, listening for
# distribution on port 9300 without epmd: register a server for it with
# ERL_FLAGS="-erl_epmd_port 9300" (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=erlang:27-slim

case "${1:-}" in
  start)
    docker rm -f pricing_demo >/dev/null 2>&1 || true
    docker run -d --name pricing_demo --cpus=1 --memory=256m -p 9300:9300 \
      -e VMARGS="${VMARGS:-+S 8:8 +sbwt very_long}" -v "$here/src:/app/src:ro" "$image" sh -c '
        mkdir -p /app/ebin && erlc -o /app/ebin /app/src/*.erl &&
        exec erl $VMARGS -noinput -name svc@127.0.0.1 -setcookie containerdemo \
          -erl_epmd_port 9300 -pa /app/ebin -eval "ok = pricing:start()"' >/dev/null
    sleep 8
    echo "pricing service running as svc@127.0.0.1 (cookie containerdemo), in a container"
    ;;
  stop)
    docker rm -f pricing_demo >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
