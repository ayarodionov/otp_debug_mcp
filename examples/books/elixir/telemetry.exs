# Starts the book_telemetry node's queries, with Repo and Metrics loaded
# from ebin and the telemetry library from Hex (fetched the first time).
Mix.install([{:telemetry, "~> 1.0"}])
:ok = Repo.start()
