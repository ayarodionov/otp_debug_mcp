#!/bin/sh
# Make a throwaway CA, one certificate for every node, and an ssl_dist
# options file, for testing Erlang distribution over TLS:
#
#     scripts/tls_dist_certs.sh /tmp/tls
#     ERL_FLAGS="-proto_dist inet_tls -ssl_dist_optfile /tmp/tls/ssl_dist.conf" ...
#
# Every node presents the same certificate and requires the peer's, signed
# by the CA. Hostname checks are off, since the certificate doesn't name
# the hosts; see docs/production.md for real deployments.
set -eu
dir=${1:?usage: tls_dist_certs.sh DIR}
mkdir -p "$dir"
cd "$dir"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=otp-debug-test-ca \
  -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=otp-debug-test-node \
  -keyout node.key -out node.csr 2>/dev/null
openssl x509 -req -days 30 -in node.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out node.pem 2>/dev/null

cat > ssl_dist.conf <<EOF
[{server, [{certfile, "$PWD/node.pem"}, {keyfile, "$PWD/node.key"},
           {cacertfile, "$PWD/ca.pem"},
           {verify, verify_peer}, {fail_if_no_peer_cert, true}]},
 {client, [{certfile, "$PWD/node.pem"}, {keyfile, "$PWD/node.key"},
           {cacertfile, "$PWD/ca.pem"},
           {verify, verify_peer}, {server_name_indication, disable}]}].
EOF
echo "$PWD/ssl_dist.conf"
