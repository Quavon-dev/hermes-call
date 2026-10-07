import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from . import lang

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
    hermes_provider: str
    hermes_reasoning_effort: str
    tts_url: str
    tts_voice: str
    tts_speed: float
    stt_model: str
    stt_model_dir: str
    stt_threads: int
    stt_beam_size: int
    stt_initial_prompt: str = ""
    # [voice]
    language: str = "en"
    # [calls]: timeouts in seconds
    ring_timeout: float = 45.0
    approval_timeout: float = 60.0
    max_call_seconds: float = 3600.0
    call_warning_seconds: float = 60.0
    media_timeout: float = 20.0
    end_silence_ms: int = 500
    acknowledgement_after_ms: int = 1800
    acknowledgement_text: str = ""
    barge_in: bool = True
    # [turn]: which of the relay's TURN URLs the bridge uses first (aiortc uses one)
    turn_transport: str = "auto"
    # [log]
    log_level: str = "INFO"
    log_format: str = "text"

    @property
    def warnings(self) -> list[str]:
        mismatch = lang.voice_language_mismatch(self.tts_voice, self.language)
        return [mismatch] if mismatch else []

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


def _language(raw: dict) -> str:
    """[voice] language, else the older [stt] language, else English."""
    value = raw.get("voice", {}).get("language", raw.get("stt", {}).get("language", "en"))
    language = str(value).strip().lower()
    if not lang.LANGUAGE.fullmatch(language):
        raise ConfigError("voice.language: a 2-3 letter language code such as de or en")
    stt_language = str(raw.get("stt", {}).get("language", language)).strip().lower()
    if stt_language != language:
        raise ConfigError(f"stt.language ({stt_language}) must match voice.language ({language}); set only voice.language")
    return language


def _text(section: dict, key: str, limit: int) -> str:
    value = section.get(key, "")
    if not isinstance(value, str) or len(value) > limit:
        raise ConfigError(f"{key}: a string of at most {limit} characters")
    return value.strip()


def _extras(raw: dict, language: str) -> dict:
    """[calls], [voice], [turn] and [log]: all optional, validated."""
    calls, voice, turn, logs = (raw.get(k, {}) for k in ("calls", "voice", "turn", "log"))
    end_silence = voice.get("end_silence_ms", 500)
    if isinstance(end_silence, bool) or not isinstance(end_silence, int) or not 200 <= end_silence <= 3000:
        raise ConfigError("end_silence_ms: an integer between 200 and 3000")
    acknowledgement_after = voice.get("acknowledgement_after_ms", 1800)
    if (
        isinstance(acknowledgement_after, bool)
        or not isinstance(acknowledgement_after, int)
        or not 0 <= acknowledgement_after <= 5000
    ):
        raise ConfigError("acknowledgement_after_ms: an integer between 0 and 5000")
    acknowledgement_text = _text(voice, "acknowledgement_text", 120) or lang.phrases(language).acknowledgement
    barge_in = voice.get("barge_in", True)
    if not isinstance(barge_in, bool):
        raise ConfigError("barge_in: true or false")
    return {
        "ring_timeout": _seconds(calls, "ring_timeout", 45, 10, 300),
        "approval_timeout": _seconds(calls, "approval_timeout", 60, 10, 600),
        "max_call_seconds": _seconds(calls, "max_call_seconds", 3600, 60, 6 * 3600),
        "call_warning_seconds": _seconds(calls, "warning_seconds", 60, 0, 600),
        "media_timeout": _seconds(calls, "media_timeout", 20, 5, 120),
        "end_silence_ms": end_silence,
        "acknowledgement_after_ms": acknowledgement_after,
        "acknowledgement_text": acknowledgement_text,
        "barge_in": barge_in,
        "turn_transport": _choice(turn, "transport", "auto", TURN_TRANSPORTS),
        "log_level": _choice(logs, "level", "INFO", LOG_LEVELS),
        "log_format": _choice(logs, "format", "text", LOG_FORMATS),
    }


def load(path: Path = DEFAULT_CONFIG) -> Config:
    try:
        raw = tomllib.loads(path.read_text()) if path.exists() else {}
        hermes, tts, stt, api = (raw.get(k, {}) for k in ("hermes", "tts", "stt", "api"))
        language = _language(raw)
        voice = tts.get("voice", lang.DEFAULT_VOICES.get(language))
        if voice is None:
            raise ConfigError(f"tts.voice: no default voice for language {language}; set one")
        config = Config(
            agent_name=str(raw.get("agent_name", "Hermes")),
            state_dir=Path(raw.get("state_dir", "/var/lib/hermes-call-bridge")),
            secrets_dir=Path(raw.get("secrets_dir", "/etc/hermes-call-bridge")),
            api_host=str(api.get("host", "127.0.0.1")),
            api_port=int(api.get("port", 8765)),
            hermes_url=_local_url(str(hermes.get("url", "http://127.0.0.1:8642"))),
            hermes_session=str(hermes.get("session_id", "hermes-call-phone")),
            hermes_model=str(hermes.get("model", "hermes-agent")),
            hermes_provider=str(hermes.get("provider", "")).strip(),
            hermes_reasoning_effort=str(hermes.get("reasoning_effort", "")).strip(),
            tts_url=_local_url(str(tts.get("url", lang.DEFAULT_TTS_URLS.get(language, lang.DEFAULT_TTS_URL)))),
            tts_voice=str(voice),
            tts_speed=float(tts.get("speed", lang.DEFAULT_SPEEDS.get(language, 1.0))),
            stt_model=str(stt.get("model", "base.en" if language == "en" else "small")),
            stt_model_dir=str(stt.get("model_dir", "/var/lib/hermes-call-bridge/models")),
            stt_threads=int(stt.get("threads", 2)),
            stt_beam_size=int(stt.get("beam_size", 1 if language == "en" else 2)),
            stt_initial_prompt=_text(stt, "initial_prompt", 200),
            language=language,
            **_extras(raw, language),
        )
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"invalid config {path}: {exc}") from exc
    if not AGENT_NAME.fullmatch(config.agent_name):
        raise ConfigError("agent_name: 1-32 letters, digits, spaces or . _ ' -")
    if config.api_host not in ("127.0.0.1", "::1"):
        raise ConfigError("the local API must bind to 127.0.0.1 or ::1")
    if not 0.5 <= config.tts_speed <= 2.0:
        raise ConfigError("tts.speed: a number between 0.5 and 2.0")
    if config.hermes_reasoning_effort not in ("", "none", "minimal", "low", "medium", "high"):
        raise ConfigError("hermes.reasoning_effort: one of none, minimal, low, medium, high")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.+-]{0,63}", config.tts_voice):
        raise ConfigError("tts.voice: a voice name such as dm_thorsten or bm_george")
    if not 1 <= config.stt_beam_size <= 5:
        raise ConfigError("stt.beam_size: an integer between 1 and 5")
    if config.stt_model.endswith(".en") and config.language != "en":
        raise ConfigError(
            f"stt.model {config.stt_model} is English-only; voice.language {config.language} needs a multilingual model (small)"
        )
    return config
