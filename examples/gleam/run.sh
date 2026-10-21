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
    erl -sname "stopper_$$" -noshell -eval "
      [rpc:call(list_to_atom(N ++ \"@$host\"), init, stop, [], 2000)
       || N <- [\"shop_gleam\", \"payments_gleam\", \"jobs_gleam\"]],
      halt()."
    ;;
  *)
    echo "usage: $0 shop|payments|jobs|stop" >&2
    exit 1
    ;;
esac
