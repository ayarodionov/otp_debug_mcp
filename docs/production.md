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
- [Targets in Docker containers](#targets-in-docker-containers)
- [Targets in Kubernetes](#targets-in-kubernetes)
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
- **Nothing inbound to the tool.** It only makes outgoing connections, so
  the release starts its node with `-dist_listen false`: it opens no port
  and registers nothing with epmd. Its own cookie is also random on every
  start; only the targets' cookies are ever used.

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

and run the server with `ERL_FLAGS="-erl_epmd_port 9100"`.
`-erl_epmd_port` makes it dial port 9100 directly instead of asking epmd,
so `connect` to `app@127.0.0.1` reaches the target through the tunnel.
This was tested between two Macs on a local network: with the target
configured as above, it was unreachable from the network, and the smoke
test passed through the tunnel, with the cookie in `OTP_DEBUG_MCP_COOKIE`.
The CI tests against an OTP 26 node in Docker dial the same way, through a
published port that works like the tunnel.

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
  "ERL_FLAGS": "-proto_dist inet_tls -ssl_dist_optfile /path/tool_ssl_dist.conf"
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
every node, and an options file, for trying this out; copy the directory
to the target's machine and fix the paths in its options file. CI runs
the whole test suite over TLS distribution with them, and
`test/otp_debug_mcp/tls_dist_test.exs` checks that the target sees the
connection as TLS. Between two Macs, the smoke test passed with both ends
on TLS, the target reported the connection as TLS, and a plain-TCP tool
and a tool whose certificate came from another CA were both refused. `connect`'s error mentions a TLS mismatch as one of the
likely causes when it fails.

## Targets in Docker containers

A node in a container is on the container's network, not your machine's.
Its default name uses the container's hostname, such as
`myapp@3f2a9c1b7d4e` for a Mix release, and that name only resolves
inside Docker. There are two ways to reach it:

- **[Run the server next to the container](#run-the-server-next-to-the-container)**:
  no changes to the app, no ports published, no restart. Use this when
  Docker runs on the machine where Claude Code runs.
- **[Publish the node's port](#publish-the-nodes-port)**: the server runs
  on your machine as usual, and the container publishes one port. The
  node's name and port must be set when the container starts.

Both were tested on Docker Desktop for Mac, against a plain Erlang node and
a Mix release, each in its own container.

### Run the server next to the container

Run the server's Docker image in a throwaway container that joins the
app container's network (`--network container:myapp`). It shares the
app's hostname and DNS, so it reaches the node by its default name, and
other nodes on the app's Docker network by theirs. The server only makes
outgoing connections, so nothing needs publishing.

The image is `ghcr.io/ayarodionov/otp_debug_mcp`, published with each
release for amd64 and arm64: the Linux release on Ubuntu 22.04, built from
the repository's `Dockerfile`. Get it with:

```sh
docker pull ghcr.io/ayarodionov/otp_debug_mcp:0.11.0
```

`latest` follows the newest release. To build it yourself instead, run
`docker build -t otp-debug-mcp .` in a checkout, and use `otp-debug-mcp`
as the image name below.

Find the node's name and cookie:

- **Name:** `name@hostname`. `docker exec myapp hostname` prints the
  hostname. For a Mix release, `name` is the release's name, or
  `RELEASE_NODE` if it's set. For a rebar3 release, it's in `vm.args`
  (`-sname`).
- **Cookie:** `RELEASE_COOKIE` in the container's environment
  (`docker exec myapp printenv RELEASE_COOKIE`), the release's
  `releases/COOKIE` file, or `-setcookie` in `vm.args`.

Then, in the app's project directory, register a server that runs in a
container beside `myapp` (your container's name), with the node's cookie:

```sh
claude mcp add otp-debug --scope local \
  -e OTP_DEBUG_MCP_COOKIE=the-cookie \
  -- docker run -i --rm --network container:myapp -e OTP_DEBUG_MCP_COOKIE \
  ghcr.io/ayarodionov/otp_debug_mcp:0.11.0
```

- `-i` connects the server's stdin and stdout to Claude Code. Don't add
  `-t`: a terminal would mix the server's logs into the protocol stream.
- `-e OTP_DEBUG_MCP_COOKIE`, with no value, passes the cookie from the
  registration into the container.
- `--rm` deletes the container when the server stops. A version in the
  image name means an upgrade happens only when you change it.
- `--scope local` registers it for this project only. There it takes the
  place of a user-scope `otp-debug`: Claude Code uses the most specific
  scope's entry, and `claude mcp list` warns that both exist.

Claude Code reads the skill on your machine, not in the container, so
install it as in the README's [Setup](../README.md#register-it-with-claude-code),
or copy it out of the image:

```sh
id=$(docker create ghcr.io/ayarodionov/otp_debug_mcp:0.11.0)
mkdir -p ~/.claude/skills && docker cp "$id:/opt/otp_debug_mcp/skills/otp-debug" ~/.claude/skills/
docker rm "$id"
```

Restart Claude Code, or use `/mcp` → `otp-debug` → **Reconnect**, then:

> Connect to myapp@3f2a9c1b7d4e and run diagnose.

If `myapp` restarts, the server's container loses its network along with
it: use **Reconnect** again. The node keeps its name, because a restarted
container keeps its hostname. A container that's removed and created
again gets a new hostname, so the node gets a new name too.

`load_module` reads the `.beam` file inside the server's container. To
load a fix, mount its directory into it, e.g. add
`-v "$PWD/_build:/work/_build:ro"` to the `docker run` arguments, and give
the path as the container sees it, under `/work/_build`.

Claude Code can do the set-up, asking before each command:

```sh
claude "Set up otp_debug_mcp to debug the BEAM node in the Docker \
container myapp, following 'Run the server next to the container' in \
https://github.com/ayarodionov/otp_debug_mcp/blob/main/docs/production.md: \
pull the server's image, find the node's name and cookie with docker \
exec, register the server for this project as the doc shows, and \
install the skill if it isn't installed. Check that each step worked, \
and tell me the node name to connect to."
```

Claude needs the cookie to register the server. In testing, it passed
the cookie from `docker exec` to `claude mcp add` through the shell,
without printing it, but nothing guarantees that. Register by hand if the
cookie must stay out of the conversation.

### Publish the node's port

When the server can't run beside the app, publish the node's distribution
port and have the server dial it directly, as through the SSH tunnel in
[Targets listening on one interface](#targets-listening-on-one-interface).
The container must start the node with:

- **A name the server can reach it by:** `myapp@127.0.0.1` when Docker
  runs on your machine.
- **A fixed distribution port.**

For a Mix release, environment variables are enough:

```sh
docker run -d --name myapp -p 127.0.0.1:9100:9100 \
  -e RELEASE_DISTRIBUTION=name \
  -e RELEASE_NODE=myapp@127.0.0.1 \
  -e RELEASE_COOKIE=the-cookie \
  -e ERL_AFLAGS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100" \
  myapp-image
```

For a rebar3 release, set the same in `vm.args`:

```
-name myapp@127.0.0.1
-setcookie the-cookie
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
```

Then register the server to dial port 9100, and connect to
`myapp@127.0.0.1`:

```sh
claude mcp add otp-debug --scope local \
  -e OTP_DEBUG_MCP_COOKIE=the-cookie \
  -e ERL_FLAGS="-erl_epmd_port 9100" \
  -- ~/.local/otp_debug_mcp/bin/otp_debug_mcp start
```

- **Publish on loopback only.** `127.0.0.1:` in `-p` publishes the port
  on your machine's loopback only. Anyone who can reach that port and
  has the cookie controls the node.
- **Don't publish epmd's port 4369.** It isn't needed, and it fails with
  "address already in use" if anything on your machine runs Erlang,
  which starts an `epmd` of its own.
- **One node per server.** With `-erl_epmd_port`, the server dials port
  9100 for every node, so this server reaches this one node only.
- **Docker on another host:** keep the port on that host's loopback, and
  tunnel to it with `ssh -N -L 9100:127.0.0.1:9100 docker-host`. The
  node's name stays `myapp@127.0.0.1`.

## Targets in Kubernetes

Nodes in pods are usually named by pod IP (`myapp@10.1.2.3`) or by their
DNS name in a headless service
(`myapp@myapp-0.myapp.prod.svc.cluster.local`), which are reachable only
inside the cluster. There are two ways in:

- **[Run the server as a pod](#run-the-server-as-a-pod)**: no changes to
  the app. Claude Code starts a pod in the app's namespace for each
  session, which reaches the nodes by their own names, and the `cluster`
  tool sees every node.
- **[Forward the node's port](#forward-the-nodes-port)**: the server runs
  on your machine, and `kubectl port-forward` carries one node's
  distribution port. The node has to be named `myapp@127.0.0.1`.

Both were tested on a local kind cluster (Kubernetes 1.37) against a Mix
release in a StatefulSet of two pods, named by pod IP and by DNS name.

### Run the server as a pod

`bin/otp-debug-k8s` in the release starts the server with `kubectl run`
in the app's namespace, from the release's Docker image, and attaches to
it. The pod reads the cookie from the app's own Secret, so neither you
nor the agent sees it, and it's deleted when the session ends. Register
it in the app's project directory:

```sh
claude mcp add otp-debug --scope local \
  -e OTP_DEBUG_K8S_NAMESPACE=prod \
  -e OTP_DEBUG_K8S_SECRET=myapp-cookie \
  -- ~/.local/otp_debug_mcp/bin/otp-debug-k8s
```

- `OTP_DEBUG_K8S_NAMESPACE` is the app's namespace, and
  `OTP_DEBUG_K8S_SECRET` the Secret the app reads its cookie from, under
  the key `cookie`. Set `OTP_DEBUG_K8S_SECRET_KEY` for another key.
- It uses `kubectl`'s current context. Set `OTP_DEBUG_K8S_CONTEXT` to
  name another.
- The image is `ghcr.io/ayarodionov/otp_debug_mcp` at the release's own
  version. Set `OTP_DEBUG_K8S_IMAGE` for another, such as a copy in your
  own registry. It needs version 0.5.0 or later: earlier servers can't
  start distribution in a pod, whose hostname has no domain.
- For a build from source, the script is in
  `_build/prod/rel/otp_debug_mcp/bin/` in the checkout.

Find the node names with `kubectl get pods -n prod -o wide` (the pod IP)
or the app's `RELEASE_NODE` (`kubectl exec -n prod myapp-0 -- printenv
RELEASE_NODE`). Then restart Claude Code, or use `/mcp` → `otp-debug` →
**Reconnect**, and:

> Connect to myapp@10.1.2.3 and compare the nodes of its cluster.

What it needs in the namespace:

- **Permissions** to `create`, `get`, `list`, `watch` and `delete`
  pods, and `create` `pods/attach`. Reading Secrets isn't one of them:
  Kubernetes gives the cookie to the pod itself. As a Role:

  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: otp-debug
    namespace: prod
  rules:
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["create", "get", "list", "watch", "delete"]
    - apiGroups: [""]
      resources: ["pods/attach"]
      verbs: ["create"]
  ```

- **Network access** from the debug pod, labelled
  `app.kubernetes.io/name=otp-debug`, to the app's pods on epmd's port
  4369 and their distribution ports, if network policies restrict
  traffic in the namespace. (kind doesn't enforce network policies, so
  that part is untested.)
- **The image**, pulled from ghcr.io, unless the cluster can't reach it;
  then set `OTP_DEBUG_K8S_IMAGE` to a copy it can.

The script deletes its pod however the session ends: when Claude Code
closes it, when it stops the script, or on Ctrl-C. If one is ever left
behind, `kubectl delete pods -n prod -l app.kubernetes.io/name=otp-debug`
removes it.

### Forward the node's port

As with [Docker](#publish-the-nodes-port), name the node by
`127.0.0.1` with a fixed distribution port. For a Mix release:

```yaml
env:
  - name: RELEASE_DISTRIBUTION
    value: name
  - name: RELEASE_NODE
    value: myapp@127.0.0.1
  - name: ERL_AFLAGS
    value: -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
```

Then forward the port, and run the server with
`ERL_FLAGS="-erl_epmd_port 9100"` as for Docker:

```sh
kubectl port-forward -n prod pod/myapp-0 9100:9100
```

A node named by `127.0.0.1` can't join a cluster of pods, which
connect to each other by IP or DNS name, so this suits single-node apps
or a pod set up for debugging. And it reaches one node per forwarded
port.

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
        "ERL_FLAGS": "-erl_epmd_port 9100"
      }
    }
  }
}
```

or with `claude mcp add -e ERL_FLAGS="-erl_epmd_port 9100" -e OTP_DEBUG_MCP_COOKIE=... otp-debug -- /path/to/bin/otp_debug_mcp start`.
