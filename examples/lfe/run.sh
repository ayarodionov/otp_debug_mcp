#!/bin/sh
# LFE (Lisp Flavoured Erlang) demo targets for otp_debug_mcp.
#
#     examples/lfe/run.sh shop        # shop_lfe: a mailbox that never drains
#     examples/lfe/run.sh payments    # payments_lfe: a crash loop
#     examples/lfe/run.sh logs        # logs_lfe: a binary memory leak
#     examples/lfe/run.sh stop        # stop them all
#
# Compiles src/ with lfec (on the PATH, or set LFE to an LFE checkout or
# install whose bin/ has it), then starts each node in the background with
# erl: compiled LFE needs nothing from LFE at runtime. Nodes are named with
# -sname on this host, with the cookie in ~/.erlang.cookie (the tool's
# default too). Then ask an agent, e.g. "logs_lfe@yourhost keeps using
# more memory; find out why."
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
  if [ -n "${LFE:-}" ]; then PATH="$LFE/bin:$PATH"; export PATH; fi
  mkdir -p "$here/ebin"
  lfec -o "$here/ebin" "$here"/src/*.lfe
  cp "$here/src/payments.app" "$here/ebin/"
}

# start NAME EXPR: a detached node that evaluates EXPR once it's up.
start() {
  erl -sname "$1" -pa "$here/ebin" -noshell -detached -eval "$2"
  echo "started $1@$host"
}

case "${1:-}" in
  shop) build; start shop_lfe "'price-cache':start()" ;;
  payments) build; start payments_lfe "{ok, _} = application:ensure_all_started(payments)" ;;
  logs) build; start logs_lfe "'log-index':start()" ;;
  stop)
    nodes="shop_lfe payments_lfe logs_lfe"
    erl -sname "stopper_$$" -noshell -eval "
      [rpc:call(list_to_atom(N ++ \"@$host\"), init, stop, [], 2000)
       || N <- string:lexemes(\"$nodes\", \" \")],
      halt()."
    wait_gone $nodes
    ;;
  *)
    echo "usage: $0 shop|payments|logs|stop" >&2
    exit 1
    ;;
esac
