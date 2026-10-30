#!/usr/bin/env python3
"""The demo's AMQP 0-9-1 clients, for RabbitMQ on 127.0.0.1:5672 (no
library needed), as user demo:

- four order services publishing orders (8 KB each) to the "orders"
  queue, about 80 a second each, and an email notification (1 KB) per order
  to the "email" queue, at the same rate;
- the order worker, consuming "orders" with no prefetch limit (the
  client library's default), handling 60 orders a second and acking
  each: RabbitMQ sends it everything as it comes, and what it hasn't
  handled yet waits, unacknowledged, in RabbitMQ's memory;
- the email service, which used to consume "email", was retired last
  month; nobody removed the queue, or stopped publishing to it.
"""
import collections
import socket
import struct
import sys
import threading
import time

HOST, PORT = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 5672
USER, PASSWORD = "demo", "demo"


def shortstr(s):
    b = s.encode()
    return bytes([len(b)]) + b


def longstr(b):
    return struct.pack("!I", len(b)) + b


class Amqp:
    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT))
        self.buf = b""
        self.lock = threading.Lock()
        self.sock.sendall(b"AMQP\x00\x00\x09\x01")
        self.expect(0, 10, 10)  # connection.start
        self.method(0, 10, 11, longstr(b"") + shortstr("PLAIN") +
                    longstr(f"\0{USER}\0{PASSWORD}".encode()) + shortstr("en_US"))
        self.expect(0, 10, 30)  # connection.tune
        self.method(0, 10, 31, struct.pack("!HIH", 16, 131072, 0))  # 16 channels, no heartbeats
        self.method(0, 10, 40, shortstr("/") + shortstr("") + b"\x00")
        self.expect(0, 10, 41)
        self.method(1, 20, 10, shortstr(""))
        self.expect(1, 20, 11)

    def frame(self, kind, channel, payload):
        with self.lock:
            self.sock.sendall(struct.pack("!BHI", kind, channel, len(payload)) + payload + b"\xce")

    def method(self, channel, cls, meth, args):
        self.frame(1, channel, struct.pack("!HH", cls, meth) + args)

    def read_frame(self):
        while len(self.buf) < 7:
            self.recv()
        kind, channel, size = struct.unpack("!BHI", self.buf[:7])
        while len(self.buf) < 8 + size:
            self.recv()
        payload = self.buf[7:7 + size]
        self.buf = self.buf[8 + size:]
        return kind, channel, payload

    def recv(self):
        data = self.sock.recv(65536)
        if not data:
            raise OSError("closed")
        self.buf += data

    def expect(self, channel, cls, meth):
        while True:
            kind, ch, payload = self.read_frame()
            if kind == 1 and struct.unpack("!HH", payload[:4]) == (cls, meth):
                return payload[4:]

    def declare(self, queue):
        self.method(1, 50, 10, struct.pack("!H", 0) + shortstr(queue) + b"\x02" + longstr(b""))
        self.expect(1, 50, 11)

    def publish(self, queue, body):
        self.method(1, 60, 40, struct.pack("!H", 0) + shortstr("") + shortstr(queue) + b"\x00")
        self.frame(2, 1, struct.pack("!HHQH", 60, 0, len(body), 0))
        self.frame(3, 1, body)

    def consume(self, queue):
        self.method(1, 60, 20, struct.pack("!H", 0) + shortstr(queue) + shortstr("") + b"\x00" + longstr(b""))
        self.expect(1, 60, 21)

    def ack(self, tag):
        self.method(1, 60, 80, struct.pack("!QB", tag, 0))


def service():
    while True:
        try:
            c = Amqp()
            c.declare("orders")
            c.declare("email")
            n = 0
            while True:
                c.publish("orders", b"order %d " % n + b"x" * 8192)
                c.publish("email", b"your order %d is confirmed " % n + b"x" * 1000)
                n += 1
                time.sleep(0.02)
        except OSError:
            time.sleep(1)


def worker():
    while True:
        try:
            c = Amqp()
            c.declare("orders")
            c.consume("orders")
            tags = collections.deque()

            # The client library reads every delivery as it arrives, and
            # keeps it until the handler gets to it.
            def read():
                while True:
                    kind, _, payload = c.read_frame()
                    if kind == 1 and payload[:4] == struct.pack("!HH", 60, 60):
                        tag_at = 5 + payload[4]
                        tags.append(struct.unpack("!Q", payload[tag_at:tag_at + 8])[0])

            threading.Thread(target=read, daemon=True).start()
            while True:
                if tags:
                    time.sleep(1 / 60)  # handling an order
                    c.ack(tags.popleft())
                else:
                    time.sleep(0.01)
        except OSError:
            time.sleep(1)


if __name__ == "__main__":
    threading.Thread(target=worker, daemon=True).start()
    for _ in range(4):
        threading.Thread(target=service, daemon=True).start()
    while True:
        time.sleep(60)
