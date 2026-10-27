#!/bin/sh
# Elixir demo targets for otp_debug_mcp.
#
#     examples/elixir/run.sh shop        # shop_ex: a mailbox that never drains
#     examples/elixir/run.sh payments    # payments_ex: a crash loop
#     examples/elixir/run.sh cluster     # ex_a, ex_b, ex_c: only ex_b has the shop bug
#     examples/elixir/run.sh release     # demo_shop: a Mix release, with its own cookie
#     examples/elixir/run.sh billing     # billing_ex: every charge recorded twice, by a macro
#     examples/elixir/run.sh phoenix     # phoenix_ex: a Phoenix API whose search always 404s
#     examples/elixir/run.sh bandit      # bandit_ex: a Bandit API refusing connections, silently
#     examples/elixir/run.sh riak        # riak_a, riak_b, riak_c: a riak_core cluster, one member down, one vnode swamped
#     examples/elixir/run.sh wishlist    # riak_a, riak_b: riak_core wishlists, riak_dt sets that keep growing
#     examples/elixir/run.sh stop        # stop them all
#
# Each node runs in the background, named with --sname on this host. All
# but the release use the cookie in ~/.erlang.cookie (the tool's default
# too); the release has its own, printed when it starts. Then ask an agent,
# e.g. "shop_ex@yourhost is slow and growing; find out why."
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=$(hostname -s)
release="$here/demo_shop/_build/prod/rel/demo_shop"

# start NAME ARGS...: a background elixir node, once it's registered.
start() {
  name=$1
  shift
  nohup elixir --sname "$name" --no-halt "$@" >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    epmd -names 2>/dev/null | grep -q "^name $name " && break
    sleep 1
  done
  echo "started $name@$host"
}

case "${1:-}" in
  shop) start shop_ex "$here/src/shop.exs" ;;
  payments) start payments_ex "$here/src/payments.exs" ;;
  cluster)
    start ex_a -e "Process.sleep(:infinity)"
    start ex_c -e "Process.sleep(:infinity)"
    start ex_b -r "$here/src/shop.exs" \
      -e "true = Node.connect(:\"ex_a@$host\"); true = Node.connect(:\"ex_c@$host\")"
    ;;
  billing)
    # Compiled to .beam files, so module_code can read them.
    mkdir -p "$here/ebin"
    elixirc --ignore-module-conflict -o "$here/ebin" "$here/src/billing.ex" >/dev/null
    start billing_ex -pa "$here/ebin" -e "{:ok, _} = Billing.start()"
    ;;
  phoenix)
    # A Mix project: fetches its deps from Hex the first time. Built in dev,
    # so its .beam files keep their debug info for module_code.
    (cd "$here/phoenix_shop" && mix deps.get --quiet && mix compile --quiet &&
      start phoenix_ex -S mix phx.server)
    ;;
  bandit)
    # A Mix project: fetches Bandit from Hex the first time.
    (cd "$here/bandit_shop" && mix deps.get --quiet && mix compile --quiet &&
      start bandit_ex -S mix run --no-halt)
    ;;
  riak)
    # A Mix project on riak_core_lite, fetched from Hex the first time.
    # Three nodes form a cluster; then riak_c goes down, and the traffic,
    # a flash sale among it, starts on riak_a.
    (cd "$here/riak_shop" && mix deps.get --quiet && mix compile --quiet && rm -rf data &&
      for n in a b c; do
        export SHOP_NODE=$n
        start "riak_$n" -S mix run
      done)
    ERL_CRASH_DUMP_BYTES=0 erl -sname "riak_admin_$$" -noshell -eval "
      ok = rpc:call('riak_a@$host', riak_shop, demo, ['riak_b@$host', 'riak_c@$host'], 120000),
      halt()."
    echo "the cluster formed, riak_c is down, and the traffic runs on riak_a"
    ;;
  wishlist)
    # The same Mix project, two nodes: riak_b joins riak_a, then shoppers
    # add to wishlists, kept as riak_dt sets, from riak_a.
    (cd "$here/riak_shop" && mix deps.get --quiet && mix compile --quiet && rm -rf data &&
      for n in a b; do
        export SHOP_NODE=$n
        start "riak_$n" -S mix run
      done)
    ERL_CRASH_DUMP_BYTES=0 erl -sname "riak_admin_$$" -noshell -eval "
      ok = rpc:call('riak_a@$host', riak_shop, wishlist_demo, ['riak_b@$host'], 120000),
      halt()."
    echo "the cluster formed, and the wishlist traffic runs on riak_a"
    ;;
  release)
    (cd "$here/demo_shop" && MIX_ENV=prod mix release --overwrite --quiet)
    "$release/bin/demo_shop" daemon
    sleep 3
    echo "started demo_shop@$host, cookie: $(cat "$release/releases/COOKIE")"
    ;;
  stop)
    elixir --sname "stopper_$$" -e "
      for n <- ~w(shop_ex payments_ex billing_ex phoenix_ex bandit_ex riak_a riak_b riak_c ex_a ex_b ex_c),
          do: :rpc.call(:\"#{n}@$host\", :init, :stop, [], 2000)"
    if [ -x "$release/bin/demo_shop" ]; then "$release/bin/demo_shop" stop 2>/dev/null || true; fi
    ;;
  *)
    echo "usage: $0 shop|payments|cluster|release|billing|phoenix|bandit|riak|wishlist|stop" >&2
    exit 1
    ;;
esac
