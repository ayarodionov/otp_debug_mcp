import Config

# Three nodes on one host: riak_a, riak_b and riak_c, told apart by
# SHOP_NODE (a, b or c), each with its own ring files and handoff port.
id = System.get_env("SHOP_NODE", "a")

config :riak_core,
  ring_state_dir: ~c"data/#{id}/ring",
  platform_data_dir: ~c"data/#{id}",
  handoff_port: 8100 + :binary.first(id) - ?a + 1,
  ring_creation_size: 16,
  # Hand partitions off within seconds of a join, not a minute.
  vnode_management_timer: 1_000,
  vnode_inactivity_timeout: 1_000
