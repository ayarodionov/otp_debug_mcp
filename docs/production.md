# Connecting to production nodes

otp_debug_mcp attaches to a node over Erlang distribution, as a hidden
node. On a laptop that just works. Production nodes usually sit behind
firewalls, listen on one interface, or use TLS for distribution. This page
covers each of those, and keeping the cookie out of the agent's hands.

Read [Before pointing it at production](scenarios.md#before-pointing-it-at-production)
first: the cookie gives full control of the node, and tool output goes to
the AI provider.

- [What a connection needs](#what-a-connection-needs)
- [Keeping the cookie out of the conversation](#keeping-the-cookie-out-of-the-conversation)
- [Targets listening on one interface](#targets-listening-on-one-interface)
- [TLS distribution](#tls-distribution)
- [Passing VM flags to the server](#passing-vm-flags-to-the-server)

## What a connection needs

- **epmd** on the target host, port 4369/tcp, which tells the tool which
  port the node listens on.
- **The node's distribution port**, which is random unless you fix it. Fix
  it so a firewall rule can allow it, in the target's `vm.args`:

  ```
  -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
  ```

- **The cookie.**
- **Nothing inbound to the tool.** It only makes outgoing connections, so it
  doesn't need to listen. Run it with `-dist_listen false` (see
  [Passing VM flags](#passing-vm-flags-to-the-server)) and it opens no port.

## Keeping the cookie out of the conversation

`connect` takes a `cookie` argument, but then the cookie passes through
the model and sits in the transcript. Instead, give it to the server
itself, in its MCP configuration, and call `connect` with just the node
name:

```json
"env": { "OTP_DEBUG_MCP_COOKIE": "..." }
```

Without either, the server falls back to `~/.erlang.cookie`.

## Targets listening on one interface

A target can bind its distribution listener to a single interface, often
loopback, so nothing outside the host can reach it:

```
-kernel inet_dist_use_interface {127,0,0,1}
```

The tool then has to connect from that host. Either run Claude Code
there, or tunnel one port over SSH. The tunnel works best without epmd:
fix the target's distribution port, name the node by its loopback address,
and tell the tool which port to dial, so the only thing to forward is that
port.

On the target (`vm.args`):

```
-name app@127.0.0.1
-kernel inet_dist_use_interface {127,0,0,1}
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
```

On your machine:

```sh
ssh -N -L 9100:127.0.0.1:9100 prod-host
```

and run the server with `ERL_FLAGS="-erl_epmd_port 9100 -dist_listen false"`.
`-erl_epmd_port` makes it dial port 9100 directly instead of asking epmd,
so `connect` to `app@127.0.0.1` reaches the target through the tunnel.
This was tested without the SSH hop, against a target configured as
above, with the cookie in `OTP_DEBUG_MCP_COOKIE`. The CI tests against an
OTP 26 node in Docker dial the same way, through a published port that
works like the tunnel.

## TLS distribution

With TLS distribution, every node, the tool included, uses
`-proto_dist inet_tls` and an options file naming its certificates. A node
without it can't connect to one with it, or the other way round.

On the target (`vm.args`; for a Mix release, `rel/vm.args.eex`):

```
-proto_dist inet_tls
-ssl_dist_optfile /etc/app/ssl_dist.conf
```

For the tool, an options file of its own. It only connects out, so only
the `client` section is used:

```erlang
[{client, [{certfile, "/path/tool.pem"},
           {keyfile, "/path/tool.key"},
           {cacertfile, "/path/ca.pem"},
           {verify, verify_peer}]}].
```

and the flags, in the server's MCP configuration:

```json
"env": {
  "ERL_FLAGS": "-proto_dist inet_tls -ssl_dist_optfile /path/tool_ssl_dist.conf -dist_listen false"
}
```

Things to get right:

- **Client certificates.** Targets usually require one
  (`{fail_if_no_peer_cert, true}` in their `server` section). The tool's
  certificate must be signed by a CA in the target's `cacertfile`.
- **Hostname checks.** With `verify_peer`, the tool checks that the
  target's certificate names the host in the node name (`app@host`), so the
  certificate needs that host in its subject alternative names. Adding
  `{server_name_indication, disable}` to the `client` section turns the
  check off, which accepts any certificate the CA signed; that's what the
  test certificates do, since they don't name hosts.
- **Cookie.** TLS doesn't replace it; both are checked.

`scripts/tls_dist_certs.sh DIR` makes a throwaway CA, one certificate for
every node, and an options file, for trying this locally. CI runs the
whole test suite over TLS distribution with them, and
`test/otp_debug_mcp/tls_dist_test.exs` checks that the target sees the
connection as TLS. `connect`'s error mentions a TLS mismatch as one of the
likely causes when it fails.

## Passing VM flags to the server

The server is a release that starts its own VM, so flags go in the
`ERL_FLAGS` environment variable of the MCP server entry, next to the
cookie:

```json
{
  "mcpServers": {
    "otp-debug": {
      "command": "/path/to/otp_debug_mcp/bin/otp_debug_mcp",
      "args": ["start"],
      "env": {
        "OTP_DEBUG_MCP_COOKIE": "...",
        "ERL_FLAGS": "-dist_listen false"
      }
    }
  }
}
```

or with `claude mcp add -e ERL_FLAGS="-dist_listen false" -e OTP_DEBUG_MCP_COOKIE=... otp-debug -- /path/to/bin/otp_debug_mcp start`.
