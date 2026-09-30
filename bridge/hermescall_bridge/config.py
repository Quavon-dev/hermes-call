import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

AGENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._'-]{0,31}")
DEFAULT_CONFIG = Path("/etc/hermes-call-bridge/bridge.toml")
LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR")
LOG_FORMATS = ("text", "json")
TURN_TRANSPORTS = ("auto", "udp", "tcp", "tls")


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
    # [calls]: timeouts in seconds
    ring_timeout: float = 45.0
    approval_timeout: float = 60.0
    max_call_seconds: float = 3600.0
    call_warning_seconds: float = 60.0
    media_timeout: float = 20.0
    # [voice]
    end_silence_ms: int = 550
    # [turn]: which of the relay's TURN URLs the bridge uses first (aiortc uses one)
    turn_transport: str = "auto"
    # [log]
    log_level: str = "INFO"
    log_format: str = "text"

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


def _seconds(section: dict, key: str, default: float, low: float, high: float) -> float:
    value = section.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int | float) or not low <= value <= high:
        raise ConfigError(f"{key}: a number of seconds between {low:g} and {high:g}")
    return float(value)


def _choice(section: dict, key: str, default: str, choices: tuple[str, ...]) -> str:
    value = str(section.get(key, default))
    if value not in choices:
        raise ConfigError(f"{key}: one of {', '.join(choices)}")
    return value


def _extras(raw: dict) -> dict:
    """[calls], [voice], [turn] and [log]: all optional, validated."""
    calls, voice, turn, logs = (raw.get(k, {}) for k in ("calls", "voice", "turn", "log"))
    end_silence = voice.get("end_silence_ms", 550)
    if isinstance(end_silence, bool) or not isinstance(end_silence, int) or not 200 <= end_silence <= 3000:
        raise ConfigError("end_silence_ms: an integer between 200 and 3000")
    return {
        "ring_timeout": _seconds(calls, "ring_timeout", 45, 10, 300),
        "approval_timeout": _seconds(calls, "approval_timeout", 60, 10, 600),
        "max_call_seconds": _seconds(calls, "max_call_seconds", 3600, 60, 6 * 3600),
        "call_warning_seconds": _seconds(calls, "warning_seconds", 60, 0, 600),
        "media_timeout": _seconds(calls, "media_timeout", 20, 5, 120),
        "end_silence_ms": end_silence,
        "turn_transport": _choice(turn, "transport", "auto", TURN_TRANSPORTS),
        "log_level": _choice(logs, "level", "INFO", LOG_LEVELS),
        "log_format": _choice(logs, "format", "text", LOG_FORMATS),
    }


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
            **_extras(raw),
        )
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid config {path}: {exc}") from exc
    if not AGENT_NAME.fullmatch(config.agent_name):
        raise ConfigError("agent_name: 1-32 letters, digits, spaces or . _ ' -")
    if config.api_host not in ("127.0.0.1", "::1"):
        raise ConfigError("the local API must bind to 127.0.0.1 or ::1")
    return config
