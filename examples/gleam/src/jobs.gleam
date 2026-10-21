//// A job runner that leaks processes. Every job spawns a worker that waits
//// for a result nobody ever sends, with no timeout, so the workers never
//// exit. About 200 jobs a second: the process count climbs until the node
//// hits its process limit.

import gleam/erlang/process.{type Subject}

pub fn main() -> Nil {
  process.spawn(fn() { submit(0) })
  process.sleep_forever()
}

fn submit(job: Int) -> Nil {
  process.spawn_unlinked(fn() { run_job(job) })
  process.sleep(5)
  submit(job + 1)
}

fn run_job(job: Int) -> Int {
  let result: Subject(Int) = process.new_subject()
  // The bug: nothing ever sends to `result`, and there's no timeout.
  process.receive_forever(result) + job
}
