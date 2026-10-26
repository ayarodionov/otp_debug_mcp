import Config

# Someone capped the connections, to protect the server: 4 acceptors with
# 25 connections each, 100 in all, where Thousand Island's default is
# 16,384 per acceptor.
config :bandit_shop,
  port: 4050,
  thousand_island_options: [num_acceptors: 4, num_connections: 25]
