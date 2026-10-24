#!/bin/sh
# Erlang demo targets for otp_debug_mcp: plain Erlang/OTP, no Elixir.
#
#     examples/erlang/run.sh shop        # shop_erl: a mailbox that never drains
#     examples/erlang/run.sh payments    # payments_erl: a crash loop
#     examples/erlang/run.sh sessions    # sessions_erl: atom and ETS leaks
#     examples/erlang/run.sh cluster     # erl_a, erl_b, erl_c: only erl_b has the shop bug
#     examples/erlang/run.sh native      # native_erl: NIFs that block a scheduler and leak memory
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
  cp "$here/src/payments.app" "$here/ebin/"
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
  native)
    build_native
    erl -sname native_erl -pa "$here/native_shop/ebin" -noshell -detached \
      -eval "{ok, _} = application:ensure_all_started(native_shop)"
    echo "started native_erl@$host"
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
       || N <- [\"shop_erl\", \"payments_erl\", \"sessions_erl\", \"native_erl\", \"erl_a\", \"erl_b\", \"erl_c\"]],
      halt()."
    ;;
  *)
    echo "usage: $0 shop|payments|sessions|cluster|native|stop" >&2
    exit 1
    ;;
esac
