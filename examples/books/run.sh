#!/bin/sh
# "Plausible but wrong" examples from Learning Erlang from Claude and
# Learning Elixir from Claude, each running on a node of its own. See
# docs/plausible-but-wrong.md for what an agent found on each.
#
#     examples/books/run.sh lock        # book_lock: two gen_servers calling each other (Erlang 5.4.6)
#     examples/books/run.sh slice       # book_slice: small slices pinning huge binaries (Erlang 3.4.3)
#     examples/books/run.sh loop        # book_loop: a receive loop with no catch-all (Erlang 2.4.1)
#     examples/books/run.sh conn        # book_conn: permanent per-connection workers (Erlang 1.4.5)
#     examples/books/run.sh parse       # book_parse: parsing by catching exceptions (Elixir 2.4.1)
#     examples/books/run.sh telemetry   # book_telemetry: a handler that raises once and disappears (Elixir 13.4.4)
#     examples/books/run.sh all         # all six
#     examples/books/run.sh stop        # stop them all
#
# Each node runs in the background, named with -sname on this host, with
# the cookie in ~/.erlang.cookie (the tool's default too). Then give an
# agent only the symptom, e.g. "the totals page served by
# book_lock@yourhost sometimes hangs for about 5 seconds and then fails;
# find out why."
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
ebin="$here/ebin"

build() {
  mkdir -p "$ebin"
  erlc +debug_info -o "$ebin" "$here"/erlang/*.erl
  elixirc --ignore-module-conflict -o "$ebin" "$here"/elixir/*.ex >/dev/null 2>&1
}

# erlang NAME MODULE: a detached Erlang node that runs MODULE:start().
erlang() {
  erl -sname "$1" -pa "$ebin" -noshell -detached -eval "ok = $2:start()"
  echo "started $1@$host"
}

# elixir NAME ARGS...: a background Elixir node, once it's registered.
elixir_node() {
  name=$1
  shift
  nohup elixir --sname "$name" --no-halt -pa "$ebin" "$@" >/dev/null 2>&1 &
  for _ in $(seq 1 60); do
    epmd -names 2>/dev/null | grep -q "^name $name " && break
    sleep 1
  done
  echo "started $name@$host"
}

start() {
  case "$1" in
    lock) erlang book_lock tally ;;
    slice) erlang book_slice headers ;;
    loop) erlang book_loop counter ;;
    conn) erlang book_conn conn ;;
    parse) elixir_node book_parse -e "{:ok, _} = Gateway.start()" ;;
    telemetry) elixir_node book_telemetry "$here/elixir/telemetry.exs" ;;
  esac
}

case "${1:-}" in
  lock | slice | loop | conn | parse | telemetry) build; start "$1" ;;
  all) build; for d in lock slice loop conn parse telemetry; do start $d; done ;;
  stop)
    nodes="book_lock book_slice book_loop book_conn book_parse book_telemetry"
    erl -sname "stopper_$$" -noshell -eval "
      [rpc:call(list_to_atom(N ++ \"@$host\"), init, stop, [], 2000)
       || N <- string:lexemes(\"$nodes\", \" \")],
      halt()."
    wait_gone $nodes
    ;;
  *)
    echo "usage: $0 lock|slice|loop|conn|parse|telemetry|all|stop" >&2
    exit 1
    ;;
esac
