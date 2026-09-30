import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

AGENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._'-]{0,31}")
DEFAULT_CONFIG = Path("/etc/hermes-call-bridge/bridge.toml")


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    agent_name: str
    state_dir: Path
    secrets_dir: Path
    api_host: str
    api_port: int
    hermes_url: str
    hermes_session: str
    hermes_model: str
    tts_url: str
    tts_voice: str
    stt_model: str
    stt_model_dir: str
    stt_threads: int

    def secret(self, name: str) -> str:
        try:
            return (self.secrets_dir / name).read_text().strip()
        except OSError as exc:
            raise ConfigError(f"missing secret {self.secrets_dir / name}") from exc


def _local_url(value: str) -> str:
    try:
        parts = urlsplit(value.rstrip("/"))
        loopback = parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1") and parts.port
    except ValueError:
        loopback = False
    if not loopback or parts.username or parts.password or parts.path or parts.query or parts.fragment:
        raise ConfigError(f"{value} must be a loopback http:// URL with a port")
    return value.rstrip("/")


def load(path: Path = DEFAULT_CONFIG) -> Config:
    try:
        raw = tomllib.loads(path.read_text()) if path.exists() else {}
        hermes, tts, stt, api = (raw.get(k, {}) for k in ("hermes", "tts", "stt", "api"))
        config = Config(
            agent_name=str(raw.get("agent_name", "Hermes")),
            state_dir=Path(raw.get("state_dir", "/var/lib/hermes-call-bridge")),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermes-call-bridge")),
            api_host=str(api.get("host", "127.0.0.1")),
            api_port=int(api.get("port", 8765)),
            hermes_url=_local_url(str(hermes.get("url", "http://127.0.0.1:8642"))),
            hermes_session=str(hermes.get("session_id", "hermes-call-phone")),
            hermes_model=str(hermes.get("model", "hermes-agent")),
            tts_url=_local_url(str(tts.get("url", "http://127.0.0.1:8880"))),
            tts_voice=str(tts.get("voice", "bm_george")),
            stt_model=str(stt.get("model", "base.en")),
            stt_model_dir=str(stt.get("model_dir", "/var/lib/hermes-call-bridge/models")),
            stt_threads=int(stt.get("threads", 2)),
        )
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid config {path}: {exc}") from exc
    if not AGENT_NAME.fullmatch(config.agent_name):
        raise ConfigError("agent_name: 1-32 letters, digits, spaces or . _ ' -")
    if config.api_host not in ("127.0.0.1", "::1"):
        raise ConfigError("the local API must bind to 127.0.0.1 or ::1")
    return config
