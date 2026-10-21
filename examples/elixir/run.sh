#!/bin/sh
# Elixir demo targets for otp_debug_mcp.
#
#     examples/elixir/run.sh shop        # shop_ex: a mailbox that never drains
#     examples/elixir/run.sh payments    # payments_ex: a crash loop
#     examples/elixir/run.sh cluster     # ex_a, ex_b, ex_c: only ex_b has the shop bug
#     examples/elixir/run.sh release     # demo_shop: a Mix release, with its own cookie
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
  release)
    (cd "$here/demo_shop" && MIX_ENV=prod mix release --overwrite --quiet)
    "$release/bin/demo_shop" daemon
    sleep 3
    echo "started demo_shop@$host, cookie: $(cat "$release/releases/COOKIE")"
    ;;
  stop)
    elixir --sname "stopper_$$" -e "
      for n <- ~w(shop_ex payments_ex ex_a ex_b ex_c),
          do: :rpc.call(:\"#{n}@$host\", :init, :stop, [], 2000)"
    if [ -x "$release/bin/demo_shop" ]; then "$release/bin/demo_shop" stop 2>/dev/null || true; fi
    ;;
  *)
    echo "usage: $0 shop|payments|cluster|release|stop" >&2
    exit 1
    ;;
esac
