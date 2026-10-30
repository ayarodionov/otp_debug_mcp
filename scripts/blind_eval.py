"""Run the walkthroughs' debugging sessions blind, as a regression suite.

Usage: blind_eval.py [--cases NAME,...] [--skip NEEDS,...] [--build]
                     [--server BINARY] [--out DIR] [--timeout SECONDS]
                     [--model MODEL] [--list]

For each case in test/blind/cases.json: start its demo, wait for it to
get into trouble, run a headless `claude -p` session that is given only
the symptom (the walkthrough's prompt) and may use only the otp-debug
tools, stop the demo, and check that the session's conclusion names the
cause: every group in the case's `expect` must have one of its patterns
(regular expressions, case-insensitive) in the final answer.

Each session runs in an empty directory, with its own MCP config for the
server (`--server`, default the release in _build/prod), so it can't
read the repository or the demo's source but through the tools.
Transcripts (stream-json), each session's answer and a report.json and
report.md go to --out (default blind-results/<time>). Exits 1 if any
case fails.

It needs the Claude Code CLI, logged in; each session costs what any
session does (the report sums it). Cases marked with `needs` (docker,
postgres) are skipped with --skip docker,postgres.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CASES = os.path.join(REPO, "test", "blind", "cases.json")
SUFFIX = " Use the otp-debug tools; the node is live. End with the cause and the fix."
DENY = "Bash Read Edit Write Glob Grep WebFetch WebSearch Agent NotebookEdit"


def load_cases():
    with open(CASES) as f:
        return json.load(f)


def sh(command, timeout=600):
    """Run a demo's start or stop command from the repository's root."""
    return subprocess.run(command, shell=True, cwd=REPO, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def session(case, server, out_dir, timeout, model):
    host = socket.gethostname().split(".")[0]
    prompt = case["prompt"].replace("{host}", host).replace("{repo}", REPO) + SUFFIX
    config = {"mcpServers": {"otp-debug": {"command": server, "args": ["start"],
                                           "env": case.get("env", {})}}}
    work = tempfile.mkdtemp(prefix="otpdbg_blind_")
    config_path = os.path.join(out_dir, f"{case['name']}.mcp.json")
    with open(config_path, "w") as f:
        json.dump(config, f)
    transcript = os.path.join(out_dir, f"{case['name']}.jsonl")
    command = ["claude", "-p", prompt, "--mcp-config", config_path, "--strict-mcp-config",
               "--allowedTools", "mcp__otp-debug", "--disallowedTools", DENY,
               "--output-format", "stream-json", "--verbose"]
    if model:
        command += ["--model", model]
    started = time.time()
    try:
        with open(transcript, "w") as t, open(os.devnull) as null:
            subprocess.run(command, cwd=work, stdin=null, stdout=t,
                           stderr=subprocess.DEVNULL, timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return transcript, time.time() - started, timed_out


def read_transcript(path):
    """The final answer, the tools called, and the result's numbers."""
    answer, tools, result = "", [], {}
    with open(path) as f:
        for line in f:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("type") == "assistant":
                for c in m["message"].get("content", []):
                    if c.get("type") == "tool_use":
                        tools.append(c["name"].replace("mcp__otp-debug__", ""))
            elif m.get("type") == "result":
                result = m
                answer = m.get("result") or ""
    return answer, tools, result


def check(answer, expect):
    missing = []
    for group in expect:
        if not any(re.search(p, answer, re.IGNORECASE) for p in group):
            missing.append(group)
    return missing


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases", help="comma-separated case names (default: all)")
    ap.add_argument("--skip", default="", help="skip cases that need these (e.g. docker,postgres)")
    ap.add_argument("--build", action="store_true", help="build the release first")
    ap.add_argument("--server", default=os.path.join(REPO, "_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp"))
    ap.add_argument("--out", help="where transcripts and the report go")
    ap.add_argument("--timeout", type=int, default=900, help="seconds a session may take")
    ap.add_argument("--model", help="the model the sessions use")
    ap.add_argument("--list", action="store_true", help="list the cases and exit")
    args = ap.parse_args()

    cases = load_cases()
    if args.list:
        for c in cases:
            needs = f" (needs {', '.join(c['needs'])})" if c.get("needs") else ""
            print(f"{c['name']:20} walkthrough {c['walkthrough']}{needs}")
        return 0
    if args.cases:
        wanted = args.cases.split(",")
        unknown = set(wanted) - {c["name"] for c in cases}
        if unknown:
            sys.exit(f"unknown cases: {', '.join(sorted(unknown))}")
        cases = [c for c in cases if c["name"] in wanted]
    skip = set(filter(None, args.skip.split(",")))

    if args.build:
        env = dict(os.environ, MIX_ENV="prod")
        subprocess.run(["mix", "release", "--overwrite", "--quiet"], cwd=REPO, env=env, check=True)
    if not os.path.exists(args.server):
        sys.exit(f"no server at {args.server}: build the release (--build) or pass --server")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.abspath(args.out or os.path.join(REPO, "blind-results", stamp))
    os.makedirs(out_dir, exist_ok=True)

    results = []
    for case in cases:
        if skip & set(case.get("needs", [])):
            results.append({"name": case["name"], "walkthrough": case["walkthrough"], "status": "skipped",
                            "why": f"needs {', '.join(case['needs'])}"})
            print(f"{case['name']:20} skipped")
            continue
        print(f"{case['name']:20} starting the demo...", end="", flush=True)
        sh(case["stop"])
        started = sh(case["start"])
        if started.returncode != 0:
            results.append({"name": case["name"], "walkthrough": case["walkthrough"], "status": "error",
                            "why": "the demo didn't start: " + started.stdout[-500:]})
            print(" the demo didn't start")
            continue
        try:
            time.sleep(case.get("wait_s", 15))
            print(" the session...", end="", flush=True)
            transcript, seconds, timed_out = session(case, args.server, out_dir, args.timeout, args.model)
        finally:
            sh(case["stop"])
        answer, tools, result = read_transcript(transcript)
        with open(os.path.join(out_dir, f"{case['name']}.answer.md"), "w") as f:
            f.write(answer)
        missing = check(answer, case["expect"])
        status = "timeout" if timed_out else ("pass" if answer and not missing else "fail")
        results.append({
            "name": case["name"], "walkthrough": case["walkthrough"], "status": status,
            "missing": missing, "seconds": round(seconds), "turns": result.get("num_turns"),
            "cost_usd": result.get("total_cost_usd"), "tools": tools,
        })
        print(f" {status} ({round(seconds)} s, {len(tools)} tool calls)")

    with open(os.path.join(out_dir, "report.json"), "w") as f:
        json.dump(results, f, indent=2)
    write_markdown(results, os.path.join(out_dir, "report.md"))
    failed = [r for r in results if r["status"] in ("fail", "timeout", "error")]
    cost = sum(r.get("cost_usd") or 0 for r in results)
    print(f"\n{len(results) - len(failed)} of {len(results)} passed or skipped; "
          f"sessions cost ${cost:.2f}; report in {out_dir}")
    return 1 if failed else 0


def write_markdown(results, path):
    lines = ["| Case | Walkthrough | Result | Time | Tool calls | Missing |", "|---|---|---|---|---|---|"]
    for r in results:
        missing = "; ".join(" or ".join(g) for g in r.get("missing") or []) or r.get("why", "")
        tools = len(r.get("tools") or [])
        seconds = f"{r['seconds']} s" if "seconds" in r else ""
        lines.append(f"| {r['name']} | {r['walkthrough']} | {r['status']} | {seconds} | {tools or ''} | {missing} |")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
