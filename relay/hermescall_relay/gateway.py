"""Push gateway: sends APNs pushes for relays that have no APNs key of their own.

It runs next to the app's publisher key (hermes-push.quavon.de for the published app). A relay
signs each request with its own Ed25519 key (`pushauth`); the key is its identity, so no sign-up
is needed. The gateway accepts only the three fixed payload shapes the relay sends to Apple
itself — a call id, a generic alert with E2E ciphertext, a checked Live Activity state — so it
never sees message text. It keeps only what abuse protection needs (`gateway_state`): hashes of
recent request signatures and, per hashed device token, which relays used it. Limits per relay,
per device token and per IP keep a relay (or anyone who learnt a token) from flooding a phone or
the publisher's APNs key.
"""

import argparse
import asyncio
import contextlib
import json
import logging
import re
import signal
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

from aiohttp import web

from hermescall_common.errors import ProtocolError
from hermescall_common.wire import b64d

from . import logs, pushauth
from .config import ApnsConfig, ConfigError
from .gateway_state import REPLAY_SECONDS, GatewayState
from .metrics import CONTENT_TYPE, Registry
from .netutil import Network, parse_networks
from .netutil import client_ip as forwarded_client_ip
from .netutil import key as client_key
from .push import LIVE_EVENTS, MAX_ALERT_CIPHERTEXT, DirectApns, PushResult, PushSender
from .ratelimit import RateLimiter
from .server import short, valid_content_state
from .store import PUSH_ENVS
from .version import VERSION

log = logging.getLogger(__name__)

DEFAULT_GATEWAY_CONFIG = Path("/etc/hermescall-push/gateway.toml")
MAX_BODY = 8 * 1024
_PUSH_TOKEN = re.compile(r"^[0-9a-f]{64,200}\Z")
_RELAY_ID = re.compile(r"^[A-Za-z0-9_-]{43}\Z")
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
# Replay cache entries per REPLAY_SECONDS: per relay (what RELAY_LIMIT allows) and per IPv4 /24 or
# IPv6 /48, so one network cannot fill the cache for everyone (see gateway_state, PRESSURE_SEEN).
SEEN_PER_RELAY = RELAY_LIMIT[1] * 2
SEEN_PER_PREFIX = 4_800
SEEN_IPV4_PREFIX = 24
KNOWN_RELAY_SECONDS = 86_400.0
# How often the blocklist files are checked for changes (SIGHUP reloads at once).
RELOAD_SECONDS = 10.0
PRUNE_SECONDS = 600.0


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
    trusted_proxies: tuple[Network, ...] = ()
    # SQLite file for the replay cache and token bindings; None keeps them in memory only.
    state_path: Path | None = None
    # Extra blocklist, one relay id per line (# comments); reloaded when it changes.
    blocklist_path: Path | None = None
    config_path: Path | None = None
    metrics_host: str = "127.0.0.1"
    metrics_port: int = 0
    log_level: str = "info"
    log_format: str = "text"

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
        log_level, log_format = logs.validate(raw.get("log_level", "info"), raw.get("log_format", "text"))
        metrics = raw.get("metrics", {})
        return GatewayConfig(
            listen_host=str(raw.get("listen_host", "127.0.0.1")),
            listen_port=int(raw.get("listen_port", 8744)),
            trust_proxy=bool(raw.get("trust_proxy", True)),
            apns=apns,
            blocked_relays=frozenset(str(item) for item in raw.get("blocked_relays", [])),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermescall-push")),
            trusted_proxies=parse_networks(raw.get("trusted_proxies", [])),
            state_path=Path(raw["state_path"]) if raw.get("state_path") else None,
            blocklist_path=Path(raw["blocklist_path"]) if raw.get("blocklist_path") else None,
            config_path=path,
            metrics_host=str(metrics.get("listen_host", "127.0.0.1")),
            metrics_port=int(metrics.get("port", 0)),
            log_level=log_level,
            log_format=log_format,
        )
    except (OSError, AttributeError, KeyError, TypeError, ValueError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid gateway config {path}: {exc}") from exc


def read_blocklist(config: GatewayConfig) -> frozenset[str]:
    """blocked_relays from gateway.toml plus the lines of blocklist_path. Raises OSError or
    ValueError when a file cannot be read, so the caller keeps the previous list (fail closed)."""
    blocked = set(config.blocked_relays)
    if config.config_path is not None:
        raw = tomllib.loads(config.config_path.read_text())
        blocked = {str(item) for item in raw.get("blocked_relays", [])}
    if config.blocklist_path is not None and config.blocklist_path.exists():
        for line in config.blocklist_path.read_text().splitlines():
            entry = line.split("#", 1)[0].strip()
            if _RELAY_ID.match(entry):
                blocked.add(entry)
    return frozenset(blocked)


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
    def __init__(self, config: GatewayConfig, sender: PushSender, state: GatewayState | None = None) -> None:
        self.config = config
        self.sender = sender
        self.state = state or GatewayState(config.state_path)
        self.blocked = read_blocklist(config)  # at start a broken file is a config error
        self.ip_rate = _limiter(IP_LIMIT)
        self.relay_rate = _limiter(RELAY_LIMIT)
        self.new_relay_rate = _limiter(NEW_RELAYS_PER_IP)
        self.new_token_rate = _limiter(NEW_TOKENS_PER_RELAY)
        self.seen_per_relay = _limiter((REPLAY_SECONDS, SEEN_PER_RELAY))
        self.seen_per_prefix = _limiter((REPLAY_SECONDS, SEEN_PER_PREFIX))
        self.token_limits = {kind: [_limiter(limit) for limit in limits] for kind, limits in TOKEN_LIMITS.items()}
        self.known_relays = ExpiringSet(KNOWN_RELAY_SECONDS, MAX_KNOWN_RELAYS)
        self._stamps: tuple = ()
        self.metrics = Registry("hermescall_gateway")
        self.metrics.gauge("build_info", "Gateway version.", lambda: {(("version", VERSION),): 1})
        self.requests = self.metrics.counter("requests_total", "Push requests by outcome.")
        self.metrics.gauge("push_total", "APNs results (retry = repeated attempts).", self._sender_stats, "counter")
        self.metrics.gauge("state_rows", "Replay cache and token binding rows.", self._state_counts)
        self.metrics.gauge("blocked_relays", "Relays on the blocklist.", lambda: len(self.blocked))

    def _sender_stats(self) -> dict:
        return {(("result", str(key)),): value for key, value in (getattr(self.sender, "stats", None) or {}).items()}

    def _state_counts(self) -> dict:
        return {(("kind", key),): value for key, value in self.state.counts().items()}

    def app(self) -> web.Application:
        app = web.Application(client_max_size=MAX_BODY)
        app.router.add_post("/v1/push", self.handle_push)
        app.router.add_get("/healthz", self.healthz)
        app.on_startup.append(self._start)
        app.on_cleanup.append(self._close)
        return app

    def metrics_app(self) -> web.Application:
        app = web.Application()
        app.router.add_get("/metrics", self.metrics_endpoint)
        return app

    async def _start(self, app: web.Application) -> None:
        app["maintenance"] = asyncio.create_task(self._maintenance())
        with contextlib.suppress(NotImplementedError, RuntimeError, ValueError):
            asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, self.reload_blocklist)
        app["metrics_runner"] = None
        if self.config.metrics_port:
            runner = web.AppRunner(self.metrics_app(), access_log=None)
            await runner.setup()
            await web.TCPSite(runner, self.config.metrics_host, self.config.metrics_port).start()
            app["metrics_runner"] = runner

    async def _close(self, app: web.Application) -> None:
        app["maintenance"].cancel()
        if app["metrics_runner"] is not None:
            await app["metrics_runner"].cleanup()
        await self.sender.close()
        self.state.close()

    async def _maintenance(self) -> None:
        last_prune = 0.0
        while True:
            await asyncio.sleep(RELOAD_SECONDS)
            try:
                self._reload_if_changed()
                if time.monotonic() - last_prune > PRUNE_SECONDS:
                    self.state.prune(time.time())
                    last_prune = time.monotonic()
            except Exception:
                log.exception("gateway maintenance failed; retrying")

    def _file_stamps(self) -> tuple:
        stamps = []
        for path in (self.config.config_path, self.config.blocklist_path):
            try:
                stat = path.stat() if path else None
                stamps.append((stat.st_mtime_ns, stat.st_size, stat.st_ino) if stat else None)
            except OSError:
                stamps.append(None)
        return tuple(stamps)

    def _reload_if_changed(self) -> None:
        stamps = self._file_stamps()
        if stamps != self._stamps and self.reload_blocklist():
            self._stamps = stamps

    def reload_blocklist(self) -> bool:
        try:
            blocked = read_blocklist(self.config)
        except (OSError, ValueError, TypeError) as exc:
            log.warning("blocklist not reloaded, keeping %d relay(s): %s", len(self.blocked), exc.__class__.__name__)
            return False
        if blocked != self.blocked:
            log.info("blocklist reloaded: %d relay(s)", len(blocked))
        self.blocked = blocked
        return True

    async def healthz(self, request: web.Request) -> web.Response:
        ok = self.state.writable()
        body = {"status": "ok" if ok else "unhealthy", "version": VERSION, "checks": {"state": "ok" if ok else "failed"}}
        return web.json_response(body, status=200 if ok else 503, headers={"Cache-Control": "no-store"})

    async def metrics_endpoint(self, request: web.Request) -> web.Response:
        return web.Response(body=self.metrics.render().encode(), headers={"Content-Type": CONTENT_TYPE})

    def client_ip(self, request: web.Request) -> str:
        return forwarded_client_ip(
            request.remote or "",
            ",".join(request.headers.getall("X-Forwarded-For", [])),
            self.config.trust_proxy,
            self.config.trusted_proxies,
        )

    async def handle_push(self, request: web.Request) -> web.Response:
        try:
            result = await self._push(request)
        except Rejected as exc:
            self.requests.inc(outcome=exc.reason)
            return web.json_response({"error": exc.reason}, status=exc.status)
        self.requests.inc(outcome=result.value)
        return web.json_response({"result": result.value})

    async def _push(self, request: web.Request) -> PushResult:
        now = time.time()
        ip = self.client_ip(request)
        ip_key = client_key(ip, IPV6_PREFIX)
        if not self.ip_rate.allow(ip_key):
            raise Rejected(429, "rate_limited")
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge as exc:
            raise Rejected(413, "too_large") from exc
        relay, signature = self._authenticate(request.headers.get("Authorization", ""), body, now, ip_key)
        kind, token, env, fields = parse_request(body)  # before anything is remembered
        self._remember(relay, signature, client_key(ip, IPV6_PREFIX, SEEN_IPV4_PREFIX), now)
        limiters = self.token_limits[kind]
        if token not in limiters[0] and not self.new_token_rate.allow(relay):
            raise Rejected(429, "rate_limited")
        decision = self.state.token_allowed(token, relay, now)
        if not decision.allowed:
            log.info("relay %s refused: token used by too many relays", short(relay))
            raise Rejected(403, decision.reason)
        if not all(limiter.allow(token) for limiter in limiters):
            raise Rejected(429, "rate_limited")
        self.state.record_token(token, relay, now)  # only a push that goes out counts as use
        result = await self._send(kind, token, env, fields)
        if result is PushResult.OK:
            self.state.mark_delivered(relay, now)
        elif result is PushResult.INVALID_TOKEN:
            self.state.forget(token)
        if result is not PushResult.OK:
            log.info("push for relay %s: %s", short(relay), result.value)
        return result

    def _authenticate(self, header: str, body: bytes, now: float, ip_key: str) -> tuple[str, bytes]:
        try:
            relay, signature = pushauth.verify(header, body, now)
        except pushauth.AuthError as exc:
            raise Rejected(401, "unauthorized") from exc
        if relay in self.blocked:
            raise Rejected(403, "blocked")
        if self.state.seen_signature(signature, now):
            raise Rejected(401, "replayed")
        if not self.known_relays.contains(relay, now) and not self.new_relay_rate.allow(ip_key):
            raise Rejected(429, "rate_limited")
        if not self.relay_rate.allow(relay):
            raise Rejected(429, "rate_limited")
        return relay, signature

    def _remember(self, relay: str, signature: bytes, prefix: str, now: float) -> None:
        """Persists the signature, so a restart does not re-open the window; refused, never evicted,
        when full. Under pressure only relays with a recent delivery get in: a flood from fresh
        keys cannot take the gateway away from the relays in use."""
        if self.state.under_pressure() and not self.state.delivered(relay, now):
            raise Rejected(503, "busy")
        if not (self.seen_per_relay.allow(relay) and self.seen_per_prefix.allow(prefix)):
            raise Rejected(429, "rate_limited")
        seen = self.state.remember_signature(signature, now)
        if seen == "replayed":
            raise Rejected(401, "replayed")
        if seen == "full":
            raise Rejected(503, "busy")
        if not self.known_relays.add(relay, now):
            self.known_relays.evict_oldest()
            self.known_relays.add(relay, now)

    async def _send(self, kind: str, token: str, env: str, fields: dict) -> PushResult:
        if kind == "voip":
            return await self.sender.send_voip(token, env, fields["call_id"])
        if kind == "alert":
            return await self.sender.send_alert(token, env, fields["ciphertext"])
        return await self.sender.send_live_activity(token, env, fields["event"], fields["content_state"])


_SHAPES = {
    "voip": {"kind", "token", "env", "call_id"},
    "alert": {"kind", "token", "env", "ciphertext"},
    "liveactivity": {"kind", "token", "env", "event", "content_state"},
}


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
    if kind not in _SHAPES or set(message) != _SHAPES[kind]:
        raise Rejected(400, "invalid")
    try:
        if kind == "voip":
            b64d(message["call_id"], length=16)
            return kind, token, env, message
        if kind == "alert":
            ciphertext = message["ciphertext"]
            if ciphertext is not None:
                b64d(ciphertext, max_length=MAX_ALERT_CIPHERTEXT)
            return kind, token, env, message
    except ProtocolError as exc:
        raise Rejected(400, "invalid") from exc
    if message["event"] in LIVE_EVENTS and valid_content_state(message["content_state"]):
        return ("liveactivity_start" if message["event"] == "start" else kind), token, env, message
    raise Rejected(400, "invalid")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermescall-push-gateway")
    parser.add_argument("--config", type=Path, default=DEFAULT_GATEWAY_CONFIG)
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("command", choices=("serve", "check-config"))
    args = parser.parse_args(argv)
    logs.setup()
    try:
        config = load_gateway(args.config)
        logs.setup(config.log_level, config.log_format)
        sender = DirectApns(config.apns, config.apns_key())
    except (ConfigError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.command == "check-config":
        print(f"config ok: topic {config.apns.topic.removesuffix('.voip')}")
        return 0
    gateway = PushGateway(config, sender)
    log.info(
        "push gateway %s listening on %s:%s (state %s)",
        VERSION,
        config.listen_host,
        config.listen_port,
        config.state_path or "in memory: replays possible after a restart",
    )
    web.run_app(gateway.app(), host=config.listen_host, port=config.listen_port, access_log=None, print=None, shutdown_timeout=10)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
