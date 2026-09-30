# Relay and push gateway image. Runs on Debian 13's python3-* packages, the same versions CI tests
# (job relay-distro), with the code from this repository and no pip installs.
#
#   docker build -f relay/Dockerfile -t hermes-call-relay .
#   docker run ... hermes-call-relay                          push gateway (default)
#   docker run ... -e HEALTH_PORT=8743 hermes-call-relay -m hermescall_relay.cli --config /etc/hermescall-relay/relay.toml serve
#
# Configuration and keys come in as files (gateway: /etc/hermescall-push/gateway.toml and
# apns_key; relay: /etc/hermescall-relay/relay.toml and its keys; see docs/push-gateway.md and
# relay/deploy/docker-compose.yml); nothing is read from environment variables except HEALTH_PORT.
#
# The base image is pinned by digest. The apt packages are not pinned to exact versions on
# purpose: Debian's mirrors keep only the current version of a package, so a pin would break the
# build at the next security update instead of picking it up. Rebuilds (CI, weekly) take the
# fixed packages; the digest pin and the image scan decide what is new.
FROM debian:13-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-aiohttp python3-httpx python3-h2 \
      python3-cryptography libsodium23 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin hermescall \
 && install -d -m 0700 -o 10001 -g 10001 /var/lib/hermescall-relay /var/lib/hermescall-push

COPY common/hermescall_common /opt/hermes-call/common/hermescall_common
COPY relay/hermescall_relay /opt/hermes-call/relay/hermescall_relay

ENV PYTHONPATH=/opt/hermes-call/common:/opt/hermes-call/relay \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HEALTH_PORT=8744

USER 10001:10001
# Relay database and blobs, and the gateway's replay cache / token bindings.
VOLUME ["/var/lib/hermescall-relay", "/var/lib/hermescall-push"]
EXPOSE 8744
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python3", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('HEALTH_PORT', '8744'), timeout=4)"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["python3"]
CMD ["-m", "hermescall_relay.gateway", "--config", "/etc/hermescall-push/gateway.toml", "serve"]
