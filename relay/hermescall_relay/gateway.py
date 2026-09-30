"""Push gateway: sends APNs pushes for relays that have no APNs key of their own.

It runs next to the app's publisher key (hermes-push.quavon.de for the published app). A relay
signs each request with its own Ed25519 key (`pushauth`); the key is its identity, so no sign-up
is needed. The gateway accepts only the three fixed payload shapes the relay sends to Apple
itself — a call id, a generic alert with E2E ciphertext, a checked Live Activity state — so it
never sees message text. It stores nothing; limits per relay, per device token and per IP keep a
relay (or anyone who learnt a token) from flooding a phone or the publisher's APNs key.
"""

import argparse
import ipaddress
import json
import logging
import re
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

from aiohttp import web

from hermescall_common.errors import ProtocolError
from hermescall_common.wire import b64d

from . import pushauth
from .config import ApnsConfig, ConfigError
from .push import LIVE_EVENTS, MAX_ALERT_CIPHERTEXT, DirectApns, PushResult, PushSender
from .ratelimit import RateLimiter
from .server import client_key, short, valid_content_state
from .store import PUSH_ENVS

log = logging.getLogger(__name__)

DEFAULT_GATEWAY_CONFIG = Path("/etc/hermescall-push/gateway.toml")
MAX_BODY = 8 * 1024
_PUSH_TOKEN = re.compile(r"^[0-9a-f]{64,200}\Z")
# Per device token: a ring is one push; chat alerts match the relay's own limit; Live Activity
# updates come at most every 3 s from a relay, starts rarely.
TOKEN_LIMITS = {
    "voip": ((60.0, 10), (3600.0, 60)),
    "alert": ((600.0, 20),),
    "liveactivity": ((60.0, 30),),
    "liveactivity_start": ((3600.0, 20),),
}
RELAY_LIMIT = (60.0, 600)
# Per IPv4 address or IPv6 /48 (a /64 is too cheap to have many of).
IP_LIMIT = (60.0, 1200)
IPV6_PREFIX = 48
# New relay keys per IP and new device tokens per relay: stop key rotation around the per-relay
# limit and a relay minting tokens to churn the per-token table.
NEW_RELAYS_PER_IP = (3600.0, 10)
NEW_TOKENS_PER_RELAY = (3600.0, 60)
MAX_KNOWN_RELAYS = 200_000
KNOWN_RELAY_SECONDS = 86_400.0
MAX_SEEN_SIGNATURES = 200_000


@dataclass(frozen=True)
class GatewayConfig:
    listen_host: str
    listen_port: int
    trust_proxy: bool
    apns: ApnsConfig
    blocked_relays: frozenset[str]
    secrets_dir: Path
    # Proxies whose X-Forwarded-For is believed (e.g. the Traefik pods' network in Kubernetes);
    # loopback is always trusted when trust_proxy is on (Caddy on the same host).
    trusted_proxies: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...] = ()

    def apns_key(self) -> bytes:
        try:
            return (self.secrets_dir / "apns_key").read_bytes().strip()
        except OSError as exc:
            raise ConfigError("missing credential: apns_key") from exc


def load_gateway(path: Path = DEFAULT_GATEWAY_CONFIG) -> GatewayConfig:
    try:
        raw = tomllib.loads(path.read_text())
        section = raw["apns"]
        apns = ApnsConfig(str(section["key_id"]), str(section["team_id"]), str(section["topic"]))
        if not (apns.key_id.isalnum() and apns.team_id.isalnum() and apns.topic.endswith(".voip")):
            raise ValueError("invalid apns settings")
        return GatewayConfig(
            listen_host=str(raw.get("listen_host", "127.0.0.1")),
            listen_port=int(raw.get("listen_port", 8744)),
            trust_proxy=bool(raw.get("trust_proxy", True)),
            apns=apns,
            blocked_relays=frozenset(str(item) for item in raw.get("blocked_relays", [])),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermescall-push")),
            trusted_proxies=tuple(ipaddress.ip_network(str(net)) for net in raw.get("trusted_proxies", [])),
        )
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid gateway config {path}: {exc}") from exc


class Rejected(Exception):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


def _limiter(limit: tuple[float, int]) -> RateLimiter:
    return RateLimiter(limit=limit[1], window=limit[0], evict=True)


class ExpiringSet:
    """Keys that expire `ttl` seconds after they were last added; oldest first, so pruning is O(1)."""

    def __init__(self, ttl: float, max_keys: int) -> None:
        self._ttl = ttl
        self._max_keys = max_keys
        self._until: dict = {}

    def __len__(self) -> int:
        return len(self._until)

    def contains(self, key: object, now: float) -> bool:
        self._prune(now)
        return key in self._until

    def add(self, key: object, now: float) -> bool:
        """False when full of unexpired keys (the caller decides whether to evict or refuse)."""
        self._prune(now)
        self._until.pop(key, None)
        if len(self._until) >= self._max_keys:
            return False
        self._until[key] = now + self._ttl
        return True

    def evict_oldest(self) -> None:
        if self._until:
            del self._until[next(iter(self._until))]

    def _prune(self, now: float) -> None:
        while self._until:
            key = next(iter(self._until))
            if self._until[key] > now:
                return
            del self._until[key]


class PushGateway:
    def __init__(self, config: GatewayConfig, sender: PushSender) -> None:
        self.config = config
        self.sender = sender
        self.ip_rate = _limiter(IP_LIMIT)
        self.relay_rate = _limiter(RELAY_LIMIT)
        self.new_relay_rate = _limiter(NEW_RELAYS_PER_IP)
        self.new_token_rate = _limiter(NEW_TOKENS_PER_RELAY)
        self.token_limits = {kind: [_limiter(limit) for limit in limits] for kind, limits in TOKEN_LIMITS.items()}
        self.known_relays = ExpiringSet(KNOWN_RELAY_SECONDS, MAX_KNOWN_RELAYS)
        self.seen_signatures = ExpiringSet(2 * pushauth.MAX_SKEW_SECONDS, MAX_SEEN_SIGNATURES)

    def app(self) -> web.Application:
        app = web.Application(client_max_size=MAX_BODY)
        app.router.add_post("/v1/push", self.handle_push)
        app.router.add_get("/healthz", self.healthz)
        app.on_cleanup.append(self._close)
        return app

    async def _close(self, app: web.Application) -> None:
        await self.sender.close()

    async def healthz(self, request: web.Request) -> web.Response:
        return web.Response(text="ok")

    def client_ip(self, request: web.Request) -> str:
        """The address the trusted proxy saw: the last X-Forwarded-For entry is the one it appended."""
        remote = request.remote or ""
        forwarded = request.headers.get("X-Forwarded-For", "")
        if self.config.trust_proxy and forwarded and self._is_trusted_proxy(remote):
            return forwarded.split(",")[-1].strip()
        return remote

    def _is_trusted_proxy(self, remote: str) -> bool:
        try:
            address = ipaddress.ip_address(remote)
        except ValueError:
            return False
        return address.is_loopback or any(address in net for net in self.config.trusted_proxies)

    async def handle_push(self, request: web.Request) -> web.Response:
        try:
            result = await self._push(request)
        except Rejected as exc:
            return web.json_response({"error": exc.reason}, status=exc.status)
        return web.json_response({"result": result.value})

    async def _push(self, request: web.Request) -> PushResult:
        now = time.time()
        ip_key = client_key(self.client_ip(request), IPV6_PREFIX)
        if not self.ip_rate.allow(ip_key):
            raise Rejected(429, "rate_limited")
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge as exc:
            raise Rejected(413, "too_large") from exc
        relay = self._authenticate(request.headers.get("Authorization", ""), body, now, ip_key)
        kind, token, env, fields = parse_request(body)
        limiters = self.token_limits[kind]
        if token not in limiters[0] and not self.new_token_rate.allow(relay):
            raise Rejected(429, "rate_limited")
        if not all(limiter.allow(token) for limiter in limiters):
            raise Rejected(429, "rate_limited")
        result = await self._send(kind, token, env, fields)
        if result is not PushResult.OK:
            log.info("push for relay %s: %s", short(relay), result.value)
        return result

    def _authenticate(self, header: str, body: bytes, now: float, ip_key: str) -> str:
        try:
            relay, signature = pushauth.verify(header, body, now)
        except pushauth.AuthError as exc:
            raise Rejected(401, "unauthorized") from exc
        if relay in self.config.blocked_relays:
            raise Rejected(403, "blocked")
        if self.seen_signatures.contains(signature, now):
            raise Rejected(401, "replayed")
        if not self.known_relays.contains(relay, now) and not self.new_relay_rate.allow(ip_key):
            raise Rejected(429, "rate_limited")
        if not self.relay_rate.allow(relay):
            raise Rejected(429, "rate_limited")
        # Evicting a signature would re-open it for replay: refuse instead (bounded by the IP limits).
        if not self.seen_signatures.add(signature, now):
            raise Rejected(503, "busy")
        if not self.known_relays.add(relay, now):
            self.known_relays.evict_oldest()
            self.known_relays.add(relay, now)
        return relay

    async def _send(self, kind: str, token: str, env: str, fields: dict) -> PushResult:
        if kind == "voip":
            return await self.sender.send_voip(token, env, fields["call_id"])
        if kind == "alert":
            return await self.sender.send_alert(token, env, fields["ciphertext"])
        return await self.sender.send_live_activity(token, env, fields["event"], fields["content_state"])


def parse_request(body: bytes) -> tuple[str, str, str, dict]:
    """Returns (limit kind, token, env, fields); anything but the three known shapes is rejected."""
    try:
        message = json.loads(body)
    except (ValueError, UnicodeDecodeError) as exc:
        raise Rejected(400, "invalid") from exc
    if not isinstance(message, dict):
        raise Rejected(400, "invalid")
    kind, token, env = message.get("kind"), message.get("token"), message.get("env")
    if not isinstance(token, str) or not _PUSH_TOKEN.match(token) or env not in PUSH_ENVS:
        raise Rejected(400, "invalid")
    try:
        if kind == "voip" and set(message) == {"kind", "token", "env", "call_id"}:
            b64d(message["call_id"], length=16)
            return kind, token, env, message
        if kind == "alert" and set(message) == {"kind", "token", "env", "ciphertext"}:
            ciphertext = message["ciphertext"]
            if ciphertext is not None:
                b64d(ciphertext, max_length=MAX_ALERT_CIPHERTEXT)
            return kind, token, env, message
    except ProtocolError as exc:
        raise Rejected(400, "invalid") from exc
    if (
        kind == "liveactivity"
        and set(message) == {"kind", "token", "env", "event", "content_state"}
        and message["event"] in LIVE_EVENTS
        and valid_content_state(message["content_state"])
    ):
        return ("liveactivity_start" if message["event"] == "start" else kind), token, env, message
    raise Rejected(400, "invalid")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermescall-push-gateway")
    parser.add_argument("--config", type=Path, default=DEFAULT_GATEWAY_CONFIG)
    parser.add_argument("command", choices=("serve", "check-config"))
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    # httpx logs every request URL at INFO, and APNs URLs contain the device token.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        config = load_gateway(args.config)
        sender = DirectApns(config.apns, config.apns_key())
    except (ConfigError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.command == "check-config":
        print(f"config ok: topic {config.apns.topic.removesuffix('.voip')}")
        return 0
    gateway = PushGateway(config, sender)
    log.info("push gateway listening on %s:%s", config.listen_host, config.listen_port)
    web.run_app(gateway.app(), host=config.listen_host, port=config.listen_port, access_log=None, print=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
