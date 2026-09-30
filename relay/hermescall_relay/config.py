import ipaddress
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from hermescall_common.codes import parse_authority, validate_pin
from hermescall_common.errors import ProtocolError

DEFAULT_CONFIG = Path("/etc/hermescall-relay/relay.toml")
# Push gateway run by the app's publisher; used when the relay has no APNs key of its own.
DEFAULT_PUSH_GATEWAY = "https://hermes-push.quavon.de"


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
    trusted_proxies: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...] = ()
    secrets_dir: Path = field(default=Path("/etc/hermescall-relay"))

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


def load(path: Path = DEFAULT_CONFIG) -> Config:
    try:
        raw = tomllib.loads(path.read_text())
        host, port = parse_authority(str(raw["authority"]))
        turn = raw.get("turn", {})
        apns = _apns(raw.get("apns"))
        return Config(
            host=host,
            port=port,
            tls_pin=validate_pin(str(raw.get("tls_pin", ""))),
            listen_host=str(raw.get("listen_host", "127.0.0.1")),
            listen_port=int(raw.get("listen_port", 8743)),
            db_path=Path(raw.get("db_path", "/var/lib/hermescall-relay/relay.db")),
            trust_proxy=bool(raw.get("trust_proxy", True)),
            turn_urls=tuple(str(url) for url in turn.get("urls", [])),
            turn_ttl=int(turn.get("ttl", 600)),
            apns=apns,
            push_gateway=_push_gateway(raw.get("push_gateway"), apns),
            trusted_proxies=tuple(ipaddress.ip_network(str(net)) for net in raw.get("trusted_proxies", [])),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermescall-relay")),
        )
    except (OSError, KeyError, ValueError, ProtocolError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid config {path}: {exc}") from exc
