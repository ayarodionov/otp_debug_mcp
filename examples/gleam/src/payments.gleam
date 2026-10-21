//// A supervisor with a gateway that connects to the payment provider a
//// second after it starts, parsing the port from its URL. The URL is
//// malformed, so the gateway crashes every time and the supervisor restarts
//// it, about once a second: up to 15 restarts in 10 seconds are allowed, so
//// the loop never makes the supervisor give up.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string

pub type GatewayMessage {
  Connect
}

pub type Gateway {
  Gateway(url: String, port: Int)
}

pub fn main() -> Nil {
  let assert Ok(_) = start()
  process.sleep_forever()
}

pub fn start() -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 15, period: 10)
  |> supervisor.add(supervision.worker(start_ledger))
  |> supervisor.add(supervision.worker(start_gateway))
  |> supervisor.start
}

// A healthy sibling of the gateway.
fn start_ledger() -> actor.StartResult(Subject(Nil)) {
  actor.new(0)
  |> actor.on_message(fn(entries, _message) { actor.continue(entries) })
  |> actor.start
}

fn start_gateway() -> actor.StartResult(Subject(GatewayMessage)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, 1000, Connect)
    actor.initialised(Gateway(url: "https://pay.example.com:443x/v2", port: 0))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_gateway)
  |> actor.start
}

fn handle_gateway(
  gateway: Gateway,
  message: GatewayMessage,
) -> actor.Next(Gateway, GatewayMessage) {
  case message {
    Connect -> {
      // The bug: "443x" isn't a port, so this assertion panics.
      let assert Ok(port) = parse_port(gateway.url)
      actor.continue(Gateway(..gateway, port:))
    }
  }
}

// "https://pay.example.com:443x/v2" -> the part between the last ":" and "/".
fn parse_port(url: String) -> Result(Int, Nil) {
  use after_colon <- result.try(list.last(string.split(url, ":")))
  use #(port, _path) <- result.try(string.split_once(after_colon, "/"))
  int.parse(port)
}
