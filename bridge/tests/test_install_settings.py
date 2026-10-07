# SPDX-License-Identifier: MIT
"""bridge/install.sh: settings survive `update`, flags win, invalid combinations stop the install."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from hermescall_bridge.config import load

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
PRODUCTION = """agent_name = "Hermes"
state_dir = "{state}"
secrets_dir = "{etc}"

[api]
host = "127.0.0.1"
port = 8765

[hermes]
url = "http://127.0.0.1:8642"
session_id = "hermes-call-phone"
model = "hermes-agent"
provider = ""
reasoning_effort = ""

[tts]
url = "http://127.0.0.1:8880"
voice = "bm_george"
speed = 1.0

[stt]
model = "small"
model_dir = "{state}/models"
threads = 4
language = "de"
beam_size = 3

[voice]
end_silence_ms = 550
barge_in = false
acknowledgement_after_ms = 0
acknowledgement_text = ""

[calls]
ring_timeout = 30

[log]
level = "DEBUG"
"""

BASH = shutil.which("bash")


def _bash_major() -> int:
    if BASH is None:
        return 0
    result = subprocess.run([BASH, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True, check=False)
    return int(result.stdout.strip() or 0)


pytestmark = pytest.mark.skipif(_bash_major() < 4, reason="install.sh needs bash 4+ (associative arrays)")


def configure(tmp_path: Path, *flags: str) -> subprocess.CompletedProcess:
    """load_settings + write_config of the real installer against a temporary /etc."""
    tools = tmp_path / "bin"
    tools.mkdir(exist_ok=True)
    python = tools / "python3"
    if not python.exists():
        python.symlink_to(sys.executable)
        (tools / "nproc").write_text("#!/bin/sh\necho 4\n")
        (tools / "nproc").chmod(0o755)
    script = f'source "{INSTALL}"; ETC="$1"; shift; parse_flags "$@"; load_settings; write_config'
    env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "LANGUAGE": "en_US:en"}
    for name in ("HERMES_MODEL", "CALL_LANGUAGE", "STT_LANGUAGE", "TTS_URL", "TTS_VOICE", "BARGE_IN", "STT_MODEL"):
        env.pop(name, None)
    return subprocess.run(
        [BASH, "-c", script, "install.sh", str(tmp_path / "etc"), *flags], env=env, capture_output=True, text=True, check=False
    )


@pytest.fixture
def installed(tmp_path: Path) -> Path:
    etc = tmp_path / "etc"
    etc.mkdir()
    for name in ("api_token", "call_token"):
        (etc / name).write_text("x")
    (etc / "bridge.toml").write_text(PRODUCTION.format(state=tmp_path / "state", etc=etc))
    return etc


def test_update_keeps_every_setting_and_the_hand_set_sections(tmp_path, installed) -> None:
    result = configure(tmp_path)
    assert result.returncode == 0, result.stderr
    assert "English Kokoro voice" in result.stderr
    config = load(installed / "bridge.toml")
    assert config.language == "de" and config.stt_model == "small" and config.stt_beam_size == 3
    assert config.tts_url == "http://127.0.0.1:8880" and config.tts_voice == "bm_george"
    assert config.barge_in is False and config.end_silence_ms == 550
    assert config.acknowledgement_after_ms == 0 and config.acknowledgement_text == "Einen Moment."
    assert config.ring_timeout == 30 and config.log_level == "DEBUG"
    assert config.warnings and "bm_george" in config.warnings[0]
    assert (
        "[stt]\nmodel" in (installed / "bridge.toml").read_text()
        and '\nlanguage = "de"' in (installed / "bridge.toml").read_text()
    )
    again = configure(tmp_path)
    assert again.returncode == 0 and load(installed / "bridge.toml") == config


def test_flags_switch_to_the_german_voice_and_survive_the_next_update(tmp_path, installed) -> None:
    flags = ("--voice", "dm_thorsten", "--tts-url", "http://127.0.0.1:8881", "--tts-speed", "1.05", "--stt-beam-size", "2")
    flags += ("--end-silence-ms", "500", "--ack-after-ms", "1800", "--hermes-model", "voice-fast", "--reasoning-effort", "none")
    assert configure(tmp_path, *flags).returncode == 0
    assert configure(tmp_path).returncode == 0
    config = load(installed / "bridge.toml")
    assert (config.tts_voice, config.tts_url, config.tts_speed) == ("dm_thorsten", "http://127.0.0.1:8881", 1.05)
    assert (config.stt_beam_size, config.end_silence_ms, config.acknowledgement_after_ms) == (2, 500, 1800)
    assert (config.hermes_model, config.hermes_provider, config.hermes_reasoning_effort) == ("voice-fast", "", "none")
    assert config.barge_in is False and config.warnings == []
    assert configure(tmp_path, "--barge-in", "true").returncode == 0
    assert load(installed / "bridge.toml").barge_in is True
    assert configure(tmp_path).returncode == 0
    assert load(installed / "bridge.toml").barge_in is True


def test_a_fresh_german_install_gets_german_defaults(tmp_path) -> None:
    etc = tmp_path / "etc"
    etc.mkdir()
    for name in ("api_token", "call_token"):
        (etc / name).write_text("x")
    assert configure(tmp_path, "--language", "de").returncode == 0
    config = load(etc / "bridge.toml")
    assert (config.language, config.stt_model, config.stt_beam_size) == ("de", "small", 2)
    assert (config.tts_voice, config.tts_url, config.tts_speed) == ("dm_thorsten", "http://127.0.0.1:8881", 1.05)
    assert (config.acknowledgement_after_ms, config.acknowledgement_text) == (1800, "Einen Moment.")
    assert config.barge_in is True and config.end_silence_ms == 500
    assert configure(tmp_path, "--language", "en").returncode == 0
    english = load(etc / "bridge.toml")
    assert (english.stt_model, english.tts_voice, english.tts_url, english.tts_speed) == (
        "base.en",
        "bm_george",
        "http://127.0.0.1:8880",
        1.0,
    )
    assert english.acknowledgement_text == "One moment." and english.barge_in is True
    (etc / "bridge.toml").unlink()
    result = configure(tmp_path, "--language", "fr")
    assert result.returncode != 0 and "no default voice" in result.stderr


@pytest.mark.parametrize(
    ("flags", "message"),
    [
        (("--language", "de", "--stt-model", "base.en"), "English-only"),
        (("--tts-url", "http://192.168.1.5:8881"), "invalid --tts-url"),
        (("--barge-in", "maybe"), "invalid --barge-in"),
        (("--stt-prompt", "x" * 201), "invalid --stt-prompt"),
    ],
)
def test_invalid_settings_stop_the_install(tmp_path, installed, flags, message) -> None:
    before = (installed / "bridge.toml").read_text()
    result = configure(tmp_path, *flags)
    assert result.returncode != 0 and message in result.stderr
    assert (installed / "bridge.toml").read_text() == before
