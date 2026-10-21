#!/bin/sh
# A three-node demo cluster, shop_a, shop_b and shop_c on this host, where
# only shop_b has a bug: the cache flood from buggy_target.exs. The others
# are idle. They use ~/.erlang.cookie, like iex --sname.
#
#     scripts/cluster_demo.sh start
#     scripts/cluster_demo.sh stop
#
# Then ask an agent, pointing it at a healthy node: "shop_a@yourhost is
# part of a cluster that's getting slow; find out which node is the
# problem and why."
set -eu
cd "$(dirname "$0")"
host=$(hostname -s)

case "${1:-}" in
  start)
    for n in shop_a shop_c; do
      nohup elixir --sname "$n" --no-halt -e 'Process.sleep(:infinity)' >/dev/null 2>&1 &
    done
    sleep 3
    nohup elixir --sname shop_b --no-halt -r buggy_target.exs \
      -e "true = Node.connect(:\"shop_a@$host\"); true = Node.connect(:\"shop_c@$host\")" \
      >/dev/null 2>&1 &
    sleep 4
    echo "started shop_a@$host, shop_b@$host (buggy), shop_c@$host"
    ;;
  stop)
    pkill -f "sname shop_[abc]" || true
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
