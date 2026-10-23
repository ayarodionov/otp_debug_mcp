# Using it from other MCP clients

otp_debug_mcp is a standard MCP server over stdio, so any client that
runs local MCP servers can use it. This page covers Cursor, GitHub Copilot
and Claude Desktop; the README covers Claude Code.

Each client needs two things:

1. **The server**, registered by its full path:
   `~/.local/otp_debug_mcp/bin/otp_debug_mcp` for a downloaded release, or
   `_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp` in your checkout if you
   built it from source. JSON configs don't expand `~`, so write
   `/Users/you/...` or `/home/you/...`. The release bundles its own Erlang
   runtime, so it needs nothing on the `PATH`, which matters for apps
   started from the Dock or a desktop launcher.
2. **The playbook** in `skills/otp-debug/SKILL.md`: connect, `diagnose`
   first, drill in, confirm trends with snapshots, and the safety rules.
   It's at `~/.local/otp_debug_mcp/skills/otp-debug/SKILL.md` in a
   downloaded release, or `skills/otp-debug/SKILL.md` in your checkout.
   Claude Code reads it as a skill; the other clients need it in their own
   instruction format, which the commands below produce. They set `skill`
   for a downloaded release; for a source build, point it at your
   checkout's copy instead.

The examples below use the downloaded release's paths. For a build from
source, put the full path of your checkout's
`_build/prod/rel/otp_debug_mcp/bin/otp_debug_mcp` in each `command`, and
set `skill` to its `skills/otp-debug/SKILL.md`.

These setups follow each client's documented configuration; the tool has
been tested end to end from Claude Code only.

- [Cursor](#cursor)
- [GitHub Copilot](#github-copilot)
- [Claude Desktop](#claude-desktop)
- [In every client](#in-every-client)

## Cursor

**The server**, in `~/.cursor/mcp.json` for every project, or
`.cursor/mcp.json` for one:

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/Users/you/.local/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": { "OTP_DEBUG_MCP_COOKIE": "your-cookie" }
    }
  }
}
```

Leave out `env` if your targets use `~/.erlang.cookie`. Cursor Settings →
MCP should then list `otp-debug` with its tools.

**The playbook**, as a rule Cursor attaches when a request is about
debugging a node. In your project:

```sh
skill=~/.local/otp_debug_mcp/skills/otp-debug/SKILL.md
mkdir -p .cursor/rules
{ printf -- '---\ndescription: Debug a live Erlang, Elixir or Gleam node with the otp-debug MCP tools\nalwaysApply: false\n---\n'
  awk 'f >= 2; /^---$/ { f++ }' "$skill"; } > .cursor/rules/otp-debug.mdc
```

**Use it** in the chat, in Agent mode:

> Connect to myapp@127.0.0.1 and find out why memory keeps growing.

## GitHub Copilot

### In VS Code

**The server**, in `.vscode/mcp.json` (or with **MCP: Add Server** from the
command palette). VS Code can ask for the cookie and keep it out of the
file:

```json
{
  "inputs": [
    {
      "type": "promptString",
      "id": "otp-cookie",
      "description": "Erlang cookie of the target nodes",
      "password": true
    }
  ],
  "servers": {
    "otp-debug": {
      "type": "stdio",
      "command": "/Users/you/.local/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": { "OTP_DEBUG_MCP_COOKIE": "${input:otp-cookie}" }
    }
  }
}
```

**The playbook**, as Copilot instructions. In your project:

```sh
skill=~/.local/otp_debug_mcp/skills/otp-debug/SKILL.md
mkdir -p .github/instructions
{ printf -- '---\napplyTo: "**"\n---\n'
  awk 'f >= 2; /^---$/ { f++ }' "$skill"; } > .github/instructions/otp-debug.instructions.md
```

**Use it** in Copilot Chat, in Agent mode, with the `otp-debug` tools
enabled in the tools picker.

### Copilot CLI

Add the server with `/mcp add`: the same command, the argument `start`,
and `OTP_DEBUG_MCP_COOKIE` in its environment if you need it.

### Not the Copilot coding agent

The coding agent on github.com runs in GitHub's cloud, so it can't reach
nodes on your machine or network. Use agent mode in your editor or the
CLI, which run the server locally.

## Claude Desktop

**The server**, in `claude_desktop_config.json` (on macOS in
`~/Library/Application Support/Claude/`; Settings → Developer → Edit
Config opens it):

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/Users/you/.local/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": { "OTP_DEBUG_MCP_COOKIE": "your-cookie" }
    }
  }
}
```

Restart Claude Desktop after editing it. **The playbook**: add the body
of `SKILL.md` to a project's instructions, or upload the `otp-debug`
directory as a skill if your plan has skills.

## In every client

- **Approvals.** Clients ask before each tool call unless you allow a
  tool. Allowing the read-only ones (`diagnose`, `run_check`,
  `process_info`, `supervision_tree`, `snapshot`, `cluster`) saves clicks;
  keep `trace_calls` and `profile` on ask for production nodes.
- **`load_module` asks you to approve each load** in a dialog, using MCP
  2026-07-28 form elicitation. A client that can't do that gets a
  refusal, and nothing is loaded. Claude Code can; check your client's
  release notes for MCP 2026-07-28 and elicitation support.
- **`remote_eval` stays off** (the default) unless it's a development node:
  it's enabled only by `OTP_DEBUG_MCP_ALLOW_EVAL=true` in the server's
  environment.
- **Long calls.** `trace_calls` can run up to 60 seconds and `diagnose`
  a few. If a client gives up on long tool calls, ask for shorter traces
  (`duration_ms`).
- **Production.** [production.md](production.md) applies as it is: the
  cookie in `OTP_DEBUG_MCP_COOKIE`, TLS distribution and tunnels through
  `ERL_FLAGS` in the same `env` block. And tool output goes to whichever AI
  provider the client uses.
