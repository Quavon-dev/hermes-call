# Relay and push gateway image. Runs on Debian 13's python3-* packages, the same versions CI tests
# (job relay-distro), with the code from this repository and no pip installs.
#
#   docker build -f relay/Dockerfile -t hermes-call-relay .
#   docker run ... hermes-call-relay                          push gateway (default)
#   docker run ... hermes-call-relay -m hermescall_relay.cli --config /etc/hermescall-relay/relay.toml serve
#
# Configuration and keys come in as files (gateway: /etc/hermescall-push/gateway.toml and
# apns_key; see docs/push-gateway.md); nothing is read from environment variables.
FROM debian:13-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-aiohttp python3-httpx python3-h2 \
      python3-cryptography libsodium23 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin hermescall

COPY common/hermescall_common /opt/hermes-call/common/hermescall_common
COPY relay/hermescall_relay /opt/hermes-call/relay/hermescall_relay

ENV PYTHONPATH=/opt/hermes-call/common:/opt/hermes-call/relay \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 10001:10001
EXPOSE 8744
ENTRYPOINT ["python3"]
CMD ["-m", "hermescall_relay.gateway", "--config", "/etc/hermescall-push/gateway.toml", "serve"]
