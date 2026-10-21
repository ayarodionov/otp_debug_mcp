//// A price cache that can't keep up. Each update takes 5 ms, so it handles
//// about 200 a second, while a producer sends 25,000 a second: the cache's
//// mailbox grows without bound, and anything that calls it waits behind it.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type Message {
  Update(sku: Int, price: Int)
}

pub fn main() -> Nil {
  let assert Ok(cache) = start()
  process.spawn(fn() { produce(cache.data, 0) })
  process.sleep_forever()
}

pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(dict.new())
  |> actor.named(process.new_name("price_cache"))
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  prices: Dict(Int, Int),
  message: Message,
) -> actor.Next(Dict(Int, Int), Message) {
  case message {
    Update(sku:, price:) -> {
      // The bug: slow work for every message, with nothing slowing the sender.
      process.sleep(5)
      actor.continue(dict.insert(prices, sku, price))
    }
  }
}

// Fire-and-forget sends, about 25,000 a second (a pause every 100).
fn produce(cache: Subject(Message), n: Int) -> Nil {
  actor.send(cache, Update(sku: n % 1000, price: n))
  case n % 100 {
    0 -> process.sleep(4)
    _ -> Nil
  }
  produce(cache, n + 1)
}
