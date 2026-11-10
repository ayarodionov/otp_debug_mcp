#!/bin/sh
# Gleam demo targets for otp_debug_mcp.
#
#     examples/gleam/run.sh shop        # shop_gleam: a mailbox that never drains
#     examples/gleam/run.sh payments    # payments_gleam: a crash loop
#     examples/gleam/run.sh jobs        # jobs_gleam: a process leak
#     examples/gleam/run.sh stop        # stop them all
#
# Builds with `gleam build` (set GLEAM to use a gleam binary not on the
# PATH), then starts each node in the background with erl, named with
# -sname on this host and the cookie in ~/.erlang.cookie (the tool's
# default too). Then ask an agent, e.g. "jobs_gleam@yourhost keeps
# growing; find out why."
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=$(hostname -s)

# wait_gone NAME...: wait until no node of these names is registered with
# epmd. init:stop returns before a node has exited, and a demo started
# again under the same name meanwhile fails to start.
wait_gone() {
  for _ in $(seq 1 30); do
    up=$(epmd -names 2>/dev/null | awk '$1 == "name" { print $2 }')
    left=""
    for n in "$@"; do
      if echo "$up" | grep -qx "$n"; then left="$left $n"; fi
    done
    [ -z "$left" ] && return 0
    sleep 1
  done
  echo "still running after 30 s:$left" >&2
  return 1
}

build() {
  (cd "$here" && "${GLEAM:-gleam}" build)
}

# start NAME MODULE: a detached node running MODULE's main/0.
start() {
  erl -sname "$1" -noshell -detached \
    $(for dir in "$here"/build/dev/erlang/*/ebin; do echo "-pa $dir"; done) \
    -eval "spawn(fun() -> $2:main() end)"
  echo "started $1@$host"
}

case "${1:-}" in
  shop) build; start shop_gleam shop ;;
  payments) build; start payments_gleam payments ;;
  jobs) build; start jobs_gleam jobs ;;
  stop)
    nodes="shop_gleam payments_gleam jobs_gleam"
    erl -sname "stopper_$$" -noshell -eval "
      [rpc:call(list_to_atom(N ++ \"@$host\"), init, stop, [], 2000)
       || N <- string:lexemes(\"$nodes\", \" \")],
      halt()."
    wait_gone $nodes
    ;;
  *)
    echo "usage: $0 shop|payments|jobs|stop" >&2
    exit 1
    ;;
esac
