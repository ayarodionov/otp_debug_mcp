"""Drive the otp_debug_mcp release over stdio JSON-RPC and check the protocol."""
import json
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGALRM, lambda *_: sys.exit("WATCHDOG: no progress in 90s"))
signal.alarm(90)
binary, target = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([binary, "start"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def recv(expect_id):
    while True:
        line = proc.stdout.readline()
        if not line:
            sys.exit(f"stdout closed early; stderr:\n{proc.stderr.read()}")
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            sys.exit(f"NON-JSON ON STDOUT (protocol corruption): {line!r}")
        if msg.get("id") == expect_id:
            return msg


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {},
    "clientInfo": {"name": "smoke", "version": "0"}}})
init = recv(1)
print("initialize ->", init["result"]["serverInfo"])
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
tools = [t["name"] for t in recv(2)["result"]["tools"]]
print("tools ->", tools)


def call(i, name, args):
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call",
          "params": {"name": name, "arguments": args}})
    r = recv(i)["result"]
    return r.get("isError", False), r["content"][0]["text"]


err, text = call(3, "connect", {"node": target})
print("connect ->", "ERROR" if err else "ok", text[:200])

err, text = call(4, "diagnose", {})
if err:
    print("diagnose -> ERROR", text[:500])
else:
    results = json.loads(text)
    for r in results:
        print(f"  {r['check']}: {r['status']}")
    mq = next(r for r in results if r["check"] == "message_queues")
    if mq["findings"]:
        printed_pid = mq["findings"][0]["pid"]
        err, text = call(40, "process_info", {"pid": printed_pid, "include_state": True})
        state = "" if err else json.loads(text)["state"]
        print(f"process_info({printed_pid}) ->", "ERROR " + text if err else "ok; state: " + state[:90])

if len(sys.argv) > 3:
    err, text = call(5, "trace_calls", {"module": sys.argv[3], "max_events": 3})
    events = [] if err else json.loads(text)["events"]
    print("trace_calls ->", "ERROR " + text if err else f"{len(events)} events")
    for e in events:
        print("   ", e.strip()[:110])
    call(6, "snapshot", {"action": "take"})
    time.sleep(2)
    err, text = call(7, "snapshot", {"action": "diff"})
    print("snapshot diff -> total_message_queue_delta =",
          json.loads(text)["total_message_queue_delta"])

proc.stdin.close()
t0 = time.time()
try:
    proc.wait(timeout=15)
    print(f"exit after stdin close -> code {proc.returncode} in {time.time() - t0:.1f}s")
except subprocess.TimeoutExpired:
    proc.kill()
    print("exit after stdin close -> HUNG, killed")
