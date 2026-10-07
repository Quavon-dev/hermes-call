"""`hermes-call-bridge doctor`: checks config, secrets, pairing, relay, Hermes, the TTS service and its
voice, the call language, the speech model, disk space and the running service. Prints one line per
check; exit 1 when one failed."""

import asyncio
import re
import shutil
import socket
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import httpx

from .config import Config, ConfigError
from .health import PROBE_TIMEOUT, probe_http
from .state import StateStore

MIN_FREE_BYTES = 500 * 1024 * 1024
SECRETS = ("api_token", "call_token", "hermes_api_key")


@dataclass(frozen=True)
class Check:
    name: str
    status: str  # ok / warn / fail
    detail: str


def _secrets(config: Config) -> Check:
    missing = []
    for name in SECRETS:
        try:
            if not config.secret(name):
                missing.append(name)
        except ConfigError:
            missing.append(name)
    return Check("secrets", "fail" if missing else "ok", f"missing: {', '.join(missing)}" if missing else "present")


def _pairing(config: Config) -> tuple[Check, tuple[str, int] | None]:
    try:
        state = StateStore(config.state_dir).load()
    except (OSError, ValueError, KeyError) as exc:
        return Check("pairing", "fail", f"state unreadable: {exc.__class__.__name__}"), None
    if not state.paired:
        return Check("pairing", "fail", "not paired with a relay (hermes-call-bridge relay add …)"), None
    endpoint = state.endpoint
    return Check("pairing", "ok", f"relay {endpoint.authority}, {len(state.devices)} phone(s)"), (endpoint.host, endpoint.port)


def _relay(address: tuple[str, int] | None, timeout: float) -> Check:
    if address is None:
        return Check("relay", "warn", "skipped (not paired)")
    try:
        with socket.create_connection(address, timeout=timeout):
            return Check("relay", "ok", f"{address[0]}:{address[1]} reachable")
    except OSError as exc:
        return Check("relay", "fail", f"{address[0]}:{address[1]} unreachable ({exc.__class__.__name__})")


def _model(config: Config) -> Check:
    path = Path(config.stt_model_dir) / config.stt_model
    ok = (path / "model.bin").is_file()
    return Check("speech model", "ok" if ok else "fail", f"{config.stt_model} {'found' if ok else 'missing'} in {path.parent}")


def _language(config: Config) -> Check:
    detail = f"{config.language}: speech recognition {config.stt_model} (beam {config.stt_beam_size}), voice {config.tts_voice}"
    if config.warnings:
        return Check("language", "warn", "; ".join(config.warnings))
    return Check("language", "ok", detail)


async def _voice(config: Config) -> Check:
    """The configured voice is one the TTS service offers (a missing German TTS shows up here)."""
    try:
        async with httpx.AsyncClient(base_url=config.tts_url, timeout=PROBE_TIMEOUT, trust_env=False) as client:
            response = await client.get("/v1/audio/voices")
        voices = response.json().get("voices") if response.status_code == 200 else None
    except (httpx.HTTPError, ValueError, AttributeError) as exc:
        return Check("voice", "warn", f"{config.tts_url}/v1/audio/voices: {exc.__class__.__name__}")
    if not isinstance(voices, list):
        return Check("voice", "warn", f"{config.tts_url} does not list its voices; {config.tts_voice} not checked")
    if not set(re.sub(r"\([\d.]+\)", "", config.tts_voice).split("+")) <= set(voices):
        return Check("voice", "fail", f"{config.tts_voice} is not offered by {config.tts_url} (language {config.language})")
    return Check("voice", "ok", f"{config.tts_voice} offered by {config.tts_url}")


def _disk(config: Config) -> Check:
    try:
        free = shutil.disk_usage(config.state_dir).free
    except OSError as exc:
        return Check("disk", "warn", f"{config.state_dir}: {exc.__class__.__name__}")
    status = "ok" if free >= MIN_FREE_BYTES else "warn"
    return Check("disk", status, f"{free / 1024**3:.1f} GiB free in {config.state_dir}")


async def _http_checks(config: Config) -> list[Check]:
    hermes, kokoro, service, voice = await asyncio.gather(
        probe_http(config.hermes_url),
        probe_http(config.tts_url),
        probe_http(f"http://{config.api_host}:{config.api_port}", "/healthz"),
        _voice(config),
    )
    return [
        Check("hermes", "ok" if hermes.ok else "fail", f"{config.hermes_url}/health: {hermes.detail}"),
        Check("kokoro", "ok" if kokoro.ok else "fail", f"{config.tts_url}/health: {kokoro.detail}"),
        voice,
        Check(
            "service",
            "ok" if service.ok else "warn",
            f"running ({service.detail})" if service.ok else f"not answering /healthz ({service.detail})",
        ),
    ]


def run_checks(config: Config, timeout: float = 5.0) -> list[Check]:
    pairing, address = _pairing(config)
    checks = [Check("config", "ok", "loaded"), _secrets(config), pairing, _relay(address, timeout)]
    checks += asyncio.run(_http_checks(config))
    return [*checks, _language(config), _model(config), _disk(config)]


def doctor(config: Config, out: Callable[[str], None] = print) -> int:
    checks = run_checks(config)
    for check in checks:
        out(f"{check.status:<4}  {check.name:<12}  {check.detail}")
    return 1 if any(check.status == "fail" for check in checks) else 0
