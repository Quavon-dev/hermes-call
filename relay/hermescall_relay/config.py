import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from hermescall_common.codes import parse_authority, validate_pin
from hermescall_common.errors import ProtocolError

from . import limits as limits_mod
from . import logs
from .limits import Limits
from .netutil import Network, parse_networks

DEFAULT_CONFIG = Path("/etc/hermescall-relay/relay.toml")
# Push gateway run by the app's publisher; used when the relay has no APNs key of its own.
DEFAULT_PUSH_GATEWAY = "https://hermes-push.quavon.de"
# TURN credentials must outlive the longest call (the bridge ends calls after 60 minutes) plus
# ringing and ICE restarts: a client that re-allocates mid-call reuses the credentials it has.
DEFAULT_TURN_TTL = 5400


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class ApnsConfig:
    key_id: str
    team_id: str
    topic: str


@dataclass(frozen=True)
class Config:
    host: str
    port: int
    tls_pin: str
    listen_host: str
    listen_port: int
    db_path: Path
    trust_proxy: bool
    turn_urls: tuple[str, ...]
    turn_ttl: int
    apns: ApnsConfig | None
    push_gateway: str | None = None
    # A reverse proxy in front (NPM, Traefik, ...): whose X-Forwarded-For is believed. Loopback (the
    # installer's own Caddy) is always trusted when trust_proxy is on.
    trusted_proxies: tuple[Network, ...] = ()
    secrets_dir: Path = field(default=Path("/etc/hermescall-relay"))
    limits: Limits = field(default_factory=Limits)
    # Prometheus /metrics on its own listener (0 = off); never on the public port.
    metrics_host: str = "127.0.0.1"
    metrics_port: int = 0
    log_level: str = "info"
    log_format: str = "text"
    # /healthz shows the exact version to everyone, not only to local requests ([health]).
    public_version: bool = False

    @property
    def authority(self) -> str:
        return self.host if self.port == 443 else f"{self.host}:{self.port}"

    def secret(self, name: str) -> bytes:
        path = self.secrets_dir / name
        try:
            return path.read_bytes().strip()
        except OSError as exc:
            raise ConfigError(f"missing credential: {name}") from exc


def _apns(section: dict | None) -> ApnsConfig | None:
    if not section or not section.get("enabled", False):
        return None
    try:
        apns = ApnsConfig(str(section["key_id"]), str(section["team_id"]), str(section["topic"]))
    except KeyError as exc:
        raise ConfigError(f"apns.{exc.args[0]} missing") from exc
    if not (apns.key_id.isalnum() and apns.team_id.isalnum() and apns.topic.endswith(".voip")):
        raise ConfigError("invalid apns settings")
    return apns


def _push_gateway(section: dict | None, apns: ApnsConfig | None) -> str | None:
    """Own APNs key wins; otherwise the gateway, unless `[push_gateway] enabled = false`."""
    section = section or {}
    if apns is not None or not section.get("enabled", True):
        return None
    url = str(section.get("url", DEFAULT_PUSH_GATEWAY)).rstrip("/")
    if not url.startswith("https://") or len(url) > 200 or any(c.isspace() for c in url):
        raise ConfigError("push_gateway.url must be an https URL")
    return url


def _turn_urls(values: object) -> tuple[str, ...]:
    if not isinstance(values, list) or not all(isinstance(url, str) for url in values):
        raise ValueError("turn.urls must be a list of strings")
    if any(not url.startswith(("turn:", "turns:", "stun:")) for url in values):
        raise ValueError("turn.urls must be turn:, turns: or stun: URLs")
    return tuple(values)


def _turn_ttl(value: object) -> int:
    ttl = int(value)  # type: ignore[call-overload]
    if not 60 <= ttl <= 86_400:
        raise ValueError("turn.ttl must be between 60 and 86400 seconds")
    return ttl


def _port(value: object) -> int:
    port = int(value)  # type: ignore[call-overload]
    if not 0 <= port <= 65535:
        raise ValueError("port out of range")
    return port


def local_path(path: Path) -> Path:
    """relay.toml -> relay.local.toml: your own settings, which the installer never rewrites."""
    return path.with_name(f"{path.stem}.local{path.suffix}")


def _merged(path: Path) -> dict:
    raw = tomllib.loads(path.read_text())
    local = local_path(path)
    if not local.is_file():
        return raw
    overlay = tomllib.loads(local.read_text())
    merged = dict(raw)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(raw.get(key), dict):
            merged[key] = {**raw[key], **value}
        else:
            merged[key] = value
    return merged


def _bool(value: object, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be true or false")
    return value


def load(path: Path = DEFAULT_CONFIG) -> Config:
    try:
        raw = _merged(path)
        host, port = parse_authority(str(raw["authority"]))
        turn = raw.get("turn", {})
        apns = _apns(raw.get("apns"))
        log_level, log_format = logs.validate(raw.get("log_level", "info"), raw.get("log_format", "text"))
        metrics = raw.get("metrics", {})
        return Config(
            host=host,
            port=port,
            tls_pin=validate_pin(str(raw.get("tls_pin", ""))),
            listen_host=str(raw.get("listen_host", "127.0.0.1")),
            listen_port=int(raw.get("listen_port", 8743)),
            db_path=Path(raw.get("db_path", "/var/lib/hermescall-relay/relay.db")),
            trust_proxy=bool(raw.get("trust_proxy", True)),
            turn_urls=_turn_urls(turn.get("urls", [])),
            turn_ttl=_turn_ttl(turn.get("ttl", DEFAULT_TURN_TTL)),
            apns=apns,
            push_gateway=_push_gateway(raw.get("push_gateway"), apns),
            trusted_proxies=parse_networks(raw.get("trusted_proxies", [])),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermescall-relay")),
            limits=limits_mod.parse(raw.get("limits")),
            metrics_host=str(metrics.get("listen_host", "127.0.0.1")),
            metrics_port=_port(metrics.get("port", 0)),
            log_level=log_level,
            log_format=log_format,
            public_version=_bool(raw.get("health", {}).get("public_version", False), "health.public_version"),
        )
    except (OSError, AttributeError, KeyError, TypeError, ValueError, ProtocolError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid config {path}: {exc}") from exc
