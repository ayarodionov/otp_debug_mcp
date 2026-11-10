"""Record a real Claude Code session that debugs a node, as the README's GIF.

Usage: record_demo.py [--prompt TEXT] [--out PATH] [--server BINARY]
                      [--gif] [--keep-raw FILE] [--timeout SECONDS]
       record_demo.py --reencode FILE [--out PATH] [--gif]

It starts interactive `claude` in a pseudo-terminal, from the repository's
root (a folder Claude Code already trusts), with only the otp-debug tools,
types the prompt as a person would, waits until the answer is complete,
and writes what the terminal showed to PATH.cast, an asciicast v2 file
(`asciinema play`). With --gif it also runs `agg` to make PATH.gif.

The node is yours to start and stop. For docs/demo/shop.gif:

    MIX_ENV=prod mix release --overwrite
    elixir --name shop@127.0.0.1 --no-halt examples/elixir/src/shop.exs &
    sleep 40        # let the mailbox grow
    python3 scripts/record_demo.py --gif
    elixir --name stopper@127.0.0.1 \\
      -e ':rpc.call(:"shop@127.0.0.1", :init, :stop, [])'

It needs the Claude Code CLI, logged in, and for --gif agg
(`brew install agg`); the session costs what any session does.

What is changed in the recording, and nothing else:

- Notices about the account the session ran under are blanked: the plan's
  name, offers tied to it, usage and limit messages. They are matched as
  Claude Code 2.1 draws them, so the script ends by listing any such words
  still in the recording, and exits 1 if there are some: look at them, and
  extend ACCOUNT below.
- A few characters agg's font lacks become look-alikes (GLYPHS).

--keep-raw FILE saves the terminal's output before any of that, to try
changes to the above with --reencode FILE instead of another session. It
holds the account notices: don't commit it.
"""
import argparse
import codecs
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROMPT = "shop@127.0.0.1 keeps getting slower and using more memory. Find out why, briefly."
DENY = "Bash Read Edit Write Glob Grep WebFetch WebSearch Agent NotebookEdit"
COLS, ROWS = 100, 34

ESC = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# Words of the account's notices, wherever they are drawn.
ACCOUNT = re.compile(r"clau\.de|in your plan|is here for your|draws down usage|"
                     r"limit reset|usage credits|Claude (?:Pro|Max|Team|Enterprise)", re.I)
# The plan's name, after the model's on the banner.
PLAN = re.compile(r" · Claude (?:Pro|Max|Team|Enterprise)[^\r\x1b]*")
# The announcements under the banner: everything between the folder's line
# and the effort hint above the input box.
ANNOUNCE = re.compile(r"(\x1b\[38;5;241m~[^\r\x1b]*\r)(.*?)"
                      r"(?=\r\x1b\[\d+C\x1b\[\d+B(?:\x1b\[38;5;241m)?◐)", re.S)
# The same text when redrawn later, a line at a time: a line is text with
# jumps to a column in it.
LINE = re.compile(r"(?:[^\x1b\r\n]|\x1b\[\d+G)+")
# The usage notices share a slot with the effort hint, and are drawn over
# it changing only the characters that differ. The long one is dropped,
# which leaves the hint as it was; the short one becomes spaces over its
# whole width, which clears the hint as the notice did.
USAGE_LONG = re.compile(r"You're now using usage credits.*?(?=\x1b\[39m)")
USAGE_SHORT = re.compile(r"Now using usage(?:\x1b\[\d+G| )credits")
# Characters agg's font lacks, as their nearest look-alikes.
GLYPHS = str.maketrans({" ": " ", "⏺": "●", "⎿": "└", "⏵": "▸"})


def blank(text):
    """`text` with its characters as spaces, its escape sequences and line ends kept."""
    parts, at = [], 0
    for esc in ESC.finditer(text):
        parts.append(re.sub(r"[^\r\n]", " ", text[at:esc.start()]) + esc.group(0))
        at = esc.end()
    return "".join(parts) + re.sub(r"[^\r\n]", " ", text[at:])


def redact(text):
    text = USAGE_LONG.sub("", text)
    text = USAGE_SHORT.sub(" " * len("Now using usage credits"), text)
    text = PLAN.sub(lambda m: blank(m.group(0)), text)
    text = ANNOUNCE.sub(lambda m: m.group(1) + blank(m.group(2)), text)
    text = LINE.sub(lambda m: blank(m.group(0)) if ACCOUNT.search(ESC.sub(" ", m.group(0)))
                    else m.group(0), text)
    return text.translate(GLYPHS)


def encode(path, capture):
    """Write the capture as an asciicast; returns the account words left in it."""
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    shown = []
    with open(path, "w") as f:
        f.write(json.dumps({"version": 2, "width": COLS, "height": ROWS,
                            "timestamp": int(capture["start"]),
                            "env": {"TERM": "xterm-256color"}}) + "\n")
        for t, data in capture["events"]:
            text = redact(decoder.decode(bytes.fromhex(data)))
            if t <= capture["end_at"] and text:
                f.write(json.dumps([round(t, 3), "o", text], ensure_ascii=False) + "\n")
                shown.append(text)
    plain = ESC.sub(" ", "".join(shown))
    return sorted({m.group(0) for m in ACCOUNT.finditer(plain)})


def record(prompt, server, timeout):
    """Run the session; returns the capture and whether the answer completed."""
    config = {"mcpServers": {"otp-debug": {"command": server, "args": ["start"]}}}
    command = ["claude", "--mcp-config", json.dumps(config), "--strict-mcp-config",
               "--allowedTools", "mcp__otp-debug", "--disallowedTools", DENY]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(REPO)
        # Run from inside a Claude Code session, it isn't that session's child.
        for name in [n for n in os.environ if n.startswith("CLAUDE")]:
            del os.environ[name]
        os.environ.update(TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS))
        os.execvp(command[0], command)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    start = time.time()
    events = []

    def pump(seconds):
        """Record output for `seconds`; returns when the last of it came, or None."""
        last, end = None, time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], min(0.05, max(0, end - time.time())))
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    sys.exit("claude exited: " + ESC.sub(" ", b"".join(
                        bytes.fromhex(d) for _, d in events).decode("utf-8", "replace"))[-400:])
                events.append((time.time() - start, data.hex()))
                last = time.time()
        return last

    def quiet(idle, limit):
        """Record until nothing was written for `idle` seconds, or `limit` passed."""
        began = last = time.time()
        while time.time() - began < limit:
            last = pump(0.5) or last
            if time.time() - last >= idle:
                return True
        return False

    quiet(3, 40)
    seen = b"".join(bytes.fromhex(d) for _, d in events)
    if b"trust this folder" in seen:
        os.write(fd, b"\x1b")
        sys.exit("Claude Code asks whether to trust this folder: run `claude` here once first")
    for ch in prompt:
        os.write(fd, ch.encode())
        pump(0.035)
    pump(0.8)
    os.write(fd, b"\r")
    pump(15)
    # The spinner writes all the time it works: silence is the answer's end.
    done = quiet(12, timeout)
    pump(2)
    end_at = time.time() - start
    for _ in range(2):
        try:
            os.write(fd, b"\x03")
        except OSError:
            break
        time.sleep(0.5)
    return {"start": start, "end_at": end_at, "events": events}, done


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prompt", default=PROMPT, help="what to type (one line of the terminal)")
    ap.add_argument("--out", default=os.path.join(REPO, "docs/demo/shop"),
                    help="the recording's path, without .cast")
    ap.add_argument("--server",
                    default=os.path.join(REPO, "_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp"))
    ap.add_argument("--gif", action="store_true", help="also make a GIF, with agg")
    ap.add_argument("--keep-raw", metavar="FILE", help="save the unredacted capture too")
    ap.add_argument("--reencode", metavar="FILE", help="encode a capture kept with --keep-raw")
    ap.add_argument("--timeout", type=int, default=400, help="seconds the answer may take")
    args = ap.parse_args()

    if args.reencode:
        with open(args.reencode) as f:
            capture = json.load(f)
    else:
        if not os.path.exists(args.server):
            sys.exit(f"no server at {args.server}: build the release or pass --server")
        if len(args.prompt) > COLS - 4:
            sys.exit(f"the prompt must fit on one line of the terminal ({COLS - 4} characters)")
        capture, done = record(args.prompt, args.server, args.timeout)
        if args.keep_raw:
            with open(args.keep_raw, "w") as f:
                json.dump(capture, f)
        if not done:
            print(f"the answer didn't finish in {args.timeout} s", file=sys.stderr)

    left = encode(args.out + ".cast", capture)
    print(f"{args.out}.cast: {capture['end_at']:.0f} s")
    if args.gif:
        subprocess.run(["agg", "-q", "--idle-time-limit", "2", "--last-frame-duration", "12",
                        "--font-size", "14", "--theme", "github-dark",
                        args.out + ".cast", args.out + ".gif"], check=True)
        print(f"{args.out}.gif: {os.path.getsize(args.out + '.gif') // 1024} KB")
    if left:
        print("account words still in the recording: " + ", ".join(left), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
