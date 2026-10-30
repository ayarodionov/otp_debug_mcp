#!/bin/sh
# RabbitMQ demo for otp_debug_mcp: RabbitMQ 4 in Docker, and AMQP clients
# (clients.py): order services, a slow order worker with no prefetch
# limit, and a queue nobody consumes any more.
#
#     examples/rabbitmq/run.sh start    # RabbitMQ, and its clients
#     examples/rabbitmq/run.sh stop     # both gone
#
# RabbitMQ runs as rabbit@localhost, cookie rabbitdemo. It listens for
# distribution on port 25672 without needing epmd, so the server dials
# that port directly: register one for it with
# ERL_FLAGS="-erl_epmd_port 25672" (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=rabbitmq:4.1

case "${1:-}" in
  start)
    docker rm -f rabbitmq_demo >/dev/null 2>&1 || true
    docker run -d --name rabbitmq_demo -e RABBITMQ_NODENAME=rabbit@localhost \
      -e RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-setcookie rabbitdemo" \
      -e RABBITMQ_DEFAULT_USER=demo -e RABBITMQ_DEFAULT_PASS=demo \
      -v "$here/rabbitmq.conf:/etc/rabbitmq/conf.d/90-demo.conf:ro" \
      -p 5672:5672 -p 25672:25672 "$image" >/dev/null
    for _ in $(seq 1 60); do
      docker logs rabbitmq_demo 2>&1 | grep -q "Server startup complete" && break
      sleep 2
    done
    nohup python3 "$here/clients.py" >"$here/clients.log" 2>&1 &
    echo $! >"$here/clients.pid"
    echo "RabbitMQ running as rabbit@localhost (cookie rabbitdemo), with its clients"
    ;;
  stop)
    if [ -f "$here/clients.pid" ]; then kill "$(cat "$here/clients.pid")" 2>/dev/null || true; rm -f "$here/clients.pid"; fi
    docker rm -f rabbitmq_demo >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
