# SPDX-License-Identifier: MIT
"""`hermes-call-bridge voice-bench` against a stand-in TTS service and recognizer."""

import types

import numpy as np
from aiohttp import web

from hermescall_bridge.bench import SENTENCES, run, to_16k, word_errors
from hermescall_bridge.config import load


def test_word_errors_ignore_case_and_punctuation() -> None:
    assert word_errors("Wie wird das Wetter morgen?", "wie wird das wetter morgen") == (0, 5)
    assert word_errors("Licht im Wohnzimmer aus.", "Licht im Wald aus") == (1, 4)
    assert word_errors("eins zwei", "") == (2, 2)


def test_speech_is_resampled_to_16k_with_quiet_edges() -> None:
    pcm = (np.ones(24_000) * 1000).astype("<i2").tobytes()
    audio = to_16k(pcm)
    assert abs(len(audio) - 32_000) < 400 and audio[0] == 0 and abs(audio[16_000] - 1000 / 32768) < 1e-3


async def test_bench_reports_synthesis_and_recognition(tmp_path, aiohttp_server, monkeypatch) -> None:
    async def speech(request: web.Request) -> web.StreamResponse:
        body = await request.json()
        response = web.StreamResponse()
        await response.prepare(request)
        await response.write(b"\0\0" * int(24_000 * len(body["input"]) / 15 / body["speed"]))
        return response

    app = web.Application()
    app.router.add_post("/v1/audio/speech", speech)
    server = await aiohttp_server(app)
    (tmp_path / "bridge.toml").write_text(f"[voice]\nlanguage = 'de'\n[tts]\nurl = 'http://127.0.0.1:{server.port}'\n")
    config = load(tmp_path / "bridge.toml")

    class FakeWhisper:
        def __init__(self, *args, **kwargs) -> None:
            self.texts = iter(SENTENCES["de"])

        def transcribe(self, audio, **options):
            text = next(self.texts)
            return iter([types.SimpleNamespace(text=text if "Licht" not in text else "Schalte bitte")]), None

    import faster_whisper

    monkeypatch.setattr(faster_whisper, "WhisperModel", FakeWhisper)
    lines: list[str] = []
    assert await run(config, ["dm_thorsten"], [1.0, 1.1], [2], 0, lines.append) == 0
    assert lines[0].startswith("tts dm_thorsten speed 1.00: first audio median") and "15.0 characters/s" in lines[0]
    assert lines[1].startswith("tts dm_thorsten speed 1.10") and "16.5 characters/s" in lines[1]
    assert "heard as 'Schalte bitte'" in lines[2]
    assert lines[3].startswith("stt small beam 2:") and "word errors 7.1 %" in lines[3]
