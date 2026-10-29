#!/usr/bin/env python3
"""The demo's XMPP clients, for ejabberd on 127.0.0.1:5222 (STARTTLS,
SASL PLAIN; no library needed):

- five order services, sender1..sender5@localhost, each sending ten
  order notifications a second to the logger bot, slowbot@localhost,
  and one a second to the support desk, support@localhost;
- slowbot, online, which reads its socket at 1 KB a second (its handler
  writes each stanza to a slow disk before reading the next);
- support, which nobody has logged in as since the account was made.
"""
import base64
import socket
import ssl
import sys
import threading
import time

HOST, PORT = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 5222
DOMAIN, PASSWORD = "localhost", "secret"
TLS = ssl.create_default_context()
TLS.check_hostname = False
TLS.verify_mode = ssl.CERT_NONE


class Stream:
    def __init__(self, user, rcvbuf=None):
        sock = socket.socket()
        if rcvbuf:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        sock.connect((HOST, PORT))
        self.sock, self.buf = sock, b""
        self.open()
        self.until(b"</stream:features>")
        self.send("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        self.until(b"<proceed")
        self.sock, self.buf = TLS.wrap_socket(sock, server_hostname=DOMAIN), b""
        self.open()
        self.until(b"</stream:features>")
        plain = base64.b64encode(f"\0{user}\0{PASSWORD}".encode()).decode()
        self.send(f"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>{plain}</auth>")
        self.until(b"<success")
        self.open()
        self.until(b"</stream:features>")
        self.send("<iq type='set' id='bind'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                  "<resource>app</resource></bind></iq>")
        self.until(b"</iq>")
        self.send("<presence/>")

    def open(self):
        self.send(f"<?xml version='1.0'?><stream:stream to='{DOMAIN}' xmlns='jabber:client' "
                  "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>")

    def send(self, s):
        self.sock.sendall(s.encode())

    def until(self, marker):
        while marker not in self.buf:
            data = self.sock.recv(65536)
            if not data:
                raise OSError("closed")
            self.buf += data
        self.buf = self.buf[self.buf.index(marker) + len(marker):]

    def drain(self):
        try:
            while self.sock.recv(65536):
                pass
        except OSError:
            pass


def message(to, n, who):
    return (f"<message to='{to}@{DOMAIN}' type='chat' id='{who}-{n}'><body>order {who}-{n} "
            f"confirmed: 3 items, total 42.00 EUR, ships from warehouse 7</body></message>")


def sender(i):
    who = f"sender{i}"
    while True:
        try:
            s = Stream(who)
            threading.Thread(target=s.drain, daemon=True).start()
            n = 0
            while True:
                s.send(message("slowbot", n, who))
                if n % 10 == 0:
                    s.send(message("support", n, who))
                n += 1
                time.sleep(0.1)
        except OSError:
            time.sleep(1)


def slowbot():
    while True:
        try:
            s = Stream("slowbot", rcvbuf=4096)
            while True:
                if not s.sock.recv(1024):
                    break
                time.sleep(1)
        except OSError:
            time.sleep(1)


if __name__ == "__main__":
    threading.Thread(target=slowbot, daemon=True).start()
    for i in range(1, 6):
        threading.Thread(target=sender, args=(i,), daemon=True).start()
    while True:
        time.sleep(60)
