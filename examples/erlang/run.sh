#!/bin/sh
# Erlang demo targets for otp_debug_mcp: plain Erlang/OTP, no Elixir.
#
#     examples/erlang/run.sh shop        # shop_erl: a mailbox that never drains
#     examples/erlang/run.sh payments    # payments_erl: a crash loop
#     examples/erlang/run.sh sessions    # sessions_erl: atom and ETS leaks
#     examples/erlang/run.sh cluster     # erl_a, erl_b, erl_c: only erl_b has the shop bug
#     examples/erlang/run.sh stop        # stop them all
#
# Each node runs in the background, named with -sname on this host, with
# the cookie in ~/.erlang.cookie (the tool's default too). Then ask an
# agent, e.g. "shop_erl@yourhost is slow and growing; find out why."
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=$(hostname -s)

build() {
  mkdir -p "$here/ebin"
  erlc -o "$here/ebin" "$here"/src/*.erl
  cp "$here/src/payments.app" "$here/ebin/"
}

# start NAME [EXPR]: a detached node that evaluates EXPR once it's up.
start() {
  erl -sname "$1" -pa "$here/ebin" -noshell -detached ${2:+-eval "$2"}
  echo "started $1@$host"
}

case "${1:-}" in
  shop) build; start shop_erl "price_cache:start()" ;;
  payments) build; start payments_erl "{ok, _} = application:ensure_all_started(payments)" ;;
  sessions) build; start sessions_erl "sessions:start()" ;;
  cluster)
    build
    start erl_a
    start erl_c
    sleep 2
    start erl_b "price_cache:start(), pong = net_adm:ping('erl_a@$host'), pong = net_adm:ping('erl_c@$host')"
    ;;
  stop)
    erl -sname "stopper_$$" -noshell -eval "
      [rpc:call(list_to_atom(N ++ \"@$host\"), init, stop, [], 2000)
       || N <- [\"shop_erl\", \"payments_erl\", \"sessions_erl\", \"erl_a\", \"erl_b\", \"erl_c\"]],
      halt()."
    ;;
  *)
    echo "usage: $0 shop|payments|sessions|cluster|stop" >&2
    exit 1
    ;;
esac
