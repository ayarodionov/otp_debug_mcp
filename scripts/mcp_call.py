"""Run a scripted sequence of steps against the otp_debug_mcp server over stdio.

Usage: mcp_call.py BINARY STEPS_JSON

STEPS_JSON is a list of steps:
  ["tool_name", {arguments}]   call an MCP tool, print the (truncated) result
  ["sleep", seconds]           pause
  ["shell", "command"]         run a shell command (e.g. restart the target)

Exits non-zero if the server ever writes a non-JSON line to stdout.
Set OTP_DEBUG_MCP_ALLOW_EVAL=true in the environment to enable remote_eval.
Tool results are truncated to MCP_CALL_MAX_OUTPUT characters (default 1500).
"""
import json
import os
import signal
import subprocess
import sys
import time

MAX_OUTPUT = int(os.environ.get("MCP_CALL_MAX_OUTPUT", "1500"))

signal.signal(signal.SIGALRM, lambda *_: sys.exit("WATCHDOG: no progress in 120s"))

binary, steps = sys.argv[1], json.loads(sys.argv[2])
proc = subprocess.Popen([binary, "start"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
next_id = 0


def request(method, params=None):
    global next_id
    next_id += 1
    msg = {"jsonrpc": "2.0", "id": next_id, "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    signal.alarm(120)
    while True:
        line = proc.stdout.readline()
        if not line:
            sys.exit("server closed stdout unexpectedly")
        try:
            reply = json.loads(line)
        except json.JSONDecodeError:
            sys.exit(f"NON-JSON ON STDOUT (protocol corruption): {line!r}")
        if reply.get("id") == next_id:
            signal.alarm(0)
            return reply


request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "mcp_call", "version": "0"}})
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
proc.stdin.flush()

for name, arg in steps:
    if name == "sleep":
        time.sleep(arg)
        continue
    if name == "shell":
        subprocess.run(arg, shell=True)
        continue
    result = request("tools/call", {"name": name, "arguments": arg})
    if "error" in result:
        print(f"## {name} -> PROTOCOL ERROR {result['error']}")
        continue
    body = result["result"]
    text = body["content"][0]["text"] if body.get("content") else ""
    tag = "ERROR" if body.get("isError") else "ok"
    print(f"## {name} {json.dumps(arg)} -> {tag}\n{text[:MAX_OUTPUT]}\n")

proc.stdin.close()
proc.wait(timeout=15)
