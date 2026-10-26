#!/bin/sh
# Erlang demo targets for otp_debug_mcp: plain Erlang/OTP, no Elixir.
#
#     examples/erlang/run.sh shop        # shop_erl: a mailbox that never drains
#     examples/erlang/run.sh payments    # payments_erl: a crash loop
#     examples/erlang/run.sh sessions    # sessions_erl: atom and ETS leaks
#     examples/erlang/run.sh cluster     # erl_a, erl_b, erl_c: only erl_b has the shop bug
#     examples/erlang/run.sh native      # native_erl: NIFs that block a scheduler and leak memory
#     examples/erlang/run.sh ports       # ports_erl: leaked sockets, a slow consumer, external programs
#     examples/erlang/run.sh orders      # orders_erl: errors that only its logs show
#     examples/erlang/run.sh locks       # locks_erl: two gen_servers that deadlock
#     examples/erlang/run.sh crash       # crash_erl: runs out of memory within a minute, leaving a crash dump
#     examples/erlang/run.sh reports     # reports_erl: CPU spent mostly collecting garbage
#     examples/erlang/run.sh deploy      # deploy_erl: a fix deployed but never loaded, a process in old code
#     examples/erlang/run.sh dist        # dist_a, dist_b: one node shipping 2 MB to the other ten times a second
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
  erlc +debug_info -o "$here/ebin" "$here"/src/*.erl
  cp "$here/src/payments.app" "$here/src/orders.app" "$here/ebin/"
}

# The native_shop application and its NIF library, built with the system's
# C compiler (CC to choose another) against this Erlang's erl_nif.h.
build_native() {
  dir="$here/native_shop"
  mkdir -p "$dir/ebin" "$dir/priv"
  erlc +debug_info -o "$dir/ebin" "$dir"/src/*.erl
  cp "$dir/src/native_shop.app.src" "$dir/ebin/native_shop.app"
  include=$(erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
  case $(uname -s) in
    Darwin) flags="-shared -undefined dynamic_lookup" ;;
    *) flags="-shared -fPIC" ;;
  esac
  ${CC:-cc} -O2 $flags -I"$include" -o "$dir/priv/native_nif.so" "$dir/c_src/native_nif.c"
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
  ports) build; start ports_erl "ok = ports_shop:start()" ;;
  locks) build; start locks_erl "ok = locks_shop:start()" ;;
  orders)
    build
    mkdir -p "$here/log"
    rm -f "$here/log/orders_erl.log"
    erl -sname orders_erl -pa "$here/ebin" -noshell -detached \
      -orders log_file "\"$here/log/orders_erl.log\"" \
      -eval "{ok, _} = application:ensure_all_started(orders)"
    echo "started orders_erl@$host, logging to $here/log/orders_erl.log"
    ;;
  crash)
    # The VM may use only a 300 MB super carrier, so it runs out of memory
    # in under a minute, wherever it runs.
    build
    mkdir -p "$here/dumps"
    rm -f "$here/dumps/crash_erl.dump"
    ERL_CRASH_DUMP="$here/dumps/crash_erl.dump" \
      erl +MMscs 300 +MMsco true +Musac false -sname crash_erl -pa "$here/ebin" -noshell -detached \
      -eval "ok = events_shop:start()"
    echo "started crash_erl@$host; it dies within a minute, writing $here/dumps/crash_erl.dump"
    ;;
  native)
    build_native
    erl -sname native_erl -pa "$here/native_shop/ebin" -noshell -detached \
      -eval "{ok, _} = application:ensure_all_started(native_shop)"
    echo "started native_erl@$host"
    ;;
  reports) build; start reports_erl "ok = reports:start()" ;;
  deploy)
    # discounts lives apart, in deploy/, so another demo's build can't
    # overwrite its deployed version.
    build
    mkdir -p "$here/deploy/ebin"
    erlc +debug_info -o "$here/deploy/ebin" "$here/deploy/discounts.erl"
    erl -sname deploy_erl -pa "$here/ebin" -pa "$here/deploy/ebin" -noshell -detached \
      -eval "ok = deploy_shop:start()"
    echo "started deploy_erl@$host"
    sleep 2
    # The deploy: the fixed discounts compiled into its ebin, but never loaded.
    erlc +debug_info -DNEW_RATE -o "$here/deploy/ebin" "$here/deploy/discounts.erl"
    # What l(heartbeat) in a remote shell does: load it again while it runs.
    erl -sname "loader_$$" -noshell -eval "
      {module, heartbeat} = rpc:call('deploy_erl@$host', code, load_file, [heartbeat]), halt()."
    echo "deployed the discounts fix to deploy/ebin without loading it, and reloaded heartbeat"
    ;;
  dist)
    build
    start dist_b "ok = dist_shop:start_b()"
    sleep 2
    start dist_a "ok = dist_shop:start_a('dist_b@$host')"
    ;;
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
       || N <- [\"shop_erl\", \"payments_erl\", \"sessions_erl\", \"native_erl\", \"ports_erl\",
                \"orders_erl\", \"crash_erl\", \"locks_erl\", \"reports_erl\", \"deploy_erl\",
                \"dist_a\", \"dist_b\", \"erl_a\", \"erl_b\", \"erl_c\"]],
      halt()."
    ;;
  *)
    echo "usage: $0 shop|payments|sessions|cluster|native|ports|orders|locks|crash|reports|deploy|dist|stop" >&2
    exit 1
    ;;
esac
