#!/usr/bin/env python3
"""The demo's MQTT clients, for EMQX on 127.0.0.1:1883 (MQTT 3.1.1, no
library needed):

- 20 sensors publishing readings at QoS 1, 10 a second each, to
  sensors/<n>/temperature;
- a dashboard subscribed to sensors/# at QoS 1, which reads what EMQX
  sends but never acknowledges it (a client library set to manual
  acknowledgement, and the code never acking);
- two devices configured with the same client ID, sensor-7, each
  reconnecting as soon as it's disconnected.
"""
import socket
import struct
import sys
import threading
import time

HOST, PORT = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 1883


def remaining_length(n):
    out = b""
    while True:
        byte, n = n % 128, n // 128
        out += bytes([byte | (0x80 if n else 0)])
        if not n:
            return out


def string(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b


def connect(client_id, clean=True):
    sock = socket.create_connection((HOST, PORT))
    body = string("MQTT") + bytes([4, 0x02 if clean else 0x00]) + struct.pack("!H", 60) + string(client_id)
    sock.sendall(b"\x10" + remaining_length(len(body)) + body)
    sock.recv(4)  # CONNACK
    return sock


def publish(sock, topic, payload, packet_id):
    body = string(topic) + struct.pack("!H", packet_id) + payload
    sock.sendall(b"\x32" + remaining_length(len(body)) + body)


def drain(sock):
    try:
        while sock.recv(65536):
            pass
    except OSError:
        pass


def sensor(n):
    while True:
        try:
            sock = connect(f"sensor-{n}")
            threading.Thread(target=drain, args=(sock,), daemon=True).start()
            packet_id = 1
            while True:
                publish(sock, f"sensors/{n}/temperature", f'{{"t": {20 + n % 7}}}'.encode(), packet_id)
                packet_id = packet_id % 65535 + 1
                time.sleep(0.1)
        except OSError:
            time.sleep(1)


def dashboard():
    while True:
        try:
            sock = connect("dashboard-1", clean=False)
            body = struct.pack("!H", 1) + string("sensors/#") + bytes([1])
            sock.sendall(b"\x82" + remaining_length(len(body)) + body)
            # Reads, never sends PUBACK.
            drain(sock)
        except OSError:
            pass
        time.sleep(1)


def twin():
    while True:
        try:
            sock = connect("sensor-7")
            drain(sock)  # returns when EMQX hands the client ID to the other one
        except OSError:
            pass
        time.sleep(0.2)


threads = [threading.Thread(target=sensor, args=(n,), daemon=True) for n in range(1, 21) if n != 7]
threads += [threading.Thread(target=dashboard, daemon=True)]
threads += [threading.Thread(target=twin, daemon=True) for _ in range(2)]
for t in threads:
    t.start()
print("clients running; Ctrl-C to stop", flush=True)
while True:
    time.sleep(3600)
