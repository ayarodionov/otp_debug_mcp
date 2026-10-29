# The server in a container: a published Linux release on Ubuntu 22.04,
# which has the glibc and OpenSSL 3 it needs. Run it with docker run -i
# (never -t) as the MCP server command, on the network of the containers
# to debug; see "Targets in Docker containers" in docs/production.md.
#
#     docker build -t otp-debug-mcp .
#     docker build --build-arg VSN=0.4.0 -t otp-debug-mcp .
#
# CI publishes it as ghcr.io/ayarodionov/otp_debug_mcp for each release.
FROM ubuntu:22.04
ARG VSN=0.12.0
ARG TARGETARCH
LABEL org.opencontainers.image.source="https://github.com/ayarodionov/otp_debug_mcp" \
      org.opencontainers.image.description="MCP server for debugging live Erlang/Elixir/OTP nodes" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="$VSN"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && arch=$([ "$TARGETARCH" = arm64 ] && echo linux-arm64 || echo linux-x86_64) \
 && base=https://github.com/ayarodionov/otp_debug_mcp/releases/download/v$VSN \
 && cd /tmp \
 && curl -fLO "$base/otp_debug_mcp-$VSN-$arch.tar.gz" \
 && curl -fLO "$base/otp_debug_mcp-$VSN-$arch.tar.gz.sha256" \
 && sha256sum -c "otp_debug_mcp-$VSN-$arch.tar.gz.sha256" \
 && tar -xzf "otp_debug_mcp-$VSN-$arch.tar.gz" -C /opt \
 && rm -f /tmp/otp_debug_mcp-* \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
# Ubuntu's image has no UTF-8 locale; without one the VM warns about
# latin1 file name encoding.
ENV LANG=C.UTF-8
ENTRYPOINT ["/opt/otp_debug_mcp/bin/otp_debug_mcp"]
CMD ["start"]
