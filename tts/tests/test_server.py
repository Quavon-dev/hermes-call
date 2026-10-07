# SPDX-License-Identifier: MIT
"""The German speech service's HTTP contract, the one the bridge's KokoroTts client speaks."""

import numpy as np
import pytest

from hermescall_tts.server import SAMPLE_RATE, build_app, loopback, sentences


class FakeEngine:
    voices = ["dm_thorsten", "df_victoria"]

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, float]] = []

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        self.calls.append((text, voice, speed))
        return np.full(SAMPLE_RATE // 10, 0.5, dtype=np.float32)


@pytest.fixture
async def service(aiohttp_client):
    engine = FakeEngine()
    return engine, await aiohttp_client(build_app(engine))


async def test_speech_streams_pcm_sentence_by_sentence(service) -> None:
    engine, client = service
    long = "Am 3. Oktober hast du einen Termin. " * 9
    body = {"model": "kokoro", "input": long + "Wie kann ich dir helfen?", "voice": "df_victoria", "speed": 1.08}
    response = await client.post("/v1/audio/speech", json={**body, "response_format": "pcm", "stream": True})
    assert response.status == 200 and response.headers["Content-Type"] == "audio/pcm"
    audio = await response.read()
    assert len(audio) == 10 * 2 * SAMPLE_RATE // 10
    assert np.frombuffer(audio, dtype="<i2")[0] == 16383
    assert engine.calls[0] == ("Am 3. Oktober hast du einen Termin.", "df_victoria", 1.08)
    assert engine.calls[-1] == ("Wie kann ich dir helfen?", "df_victoria", 1.08) and len(engine.calls) == 10


async def test_default_voice_and_listing(service) -> None:
    engine, client = service
    assert (await (await client.get("/v1/audio/voices")).json()) == {"voices": ["dm_thorsten", "df_victoria"]}
    assert (await client.get("/health")).status == 200
    await (await client.post("/v1/audio/speech", json={"input": "Einen Moment."})).read()
    assert engine.calls == [("Einen Moment.", "dm_thorsten", 1.0)]


@pytest.mark.parametrize(
    "body",
    [
        {"input": ""},
        {"input": "x" * 4001},
        {"input": "Hallo", "voice": "bm_george"},
        {"input": "Hallo", "speed": 3},
        {"input": "Hallo", "speed": True},
        {"input": "Hallo", "response_format": "mp3"},
        ["Hallo"],
    ],
)
async def test_bad_requests_are_rejected(service, body) -> None:
    engine, client = service
    assert (await client.post("/v1/audio/speech", json=body)).status == 400
    assert engine.calls == []


def test_only_loopback_addresses_are_accepted() -> None:
    assert loopback("127.0.0.1") == "127.0.0.1" and loopback("::1") == "::1"
    for host in ("0.0.0.0", "192.168.1.10", "::", "example.org"):  # noqa: S104
        with pytest.raises(ValueError):
            loopback(host)


def test_short_texts_stay_whole_and_long_ones_split_at_sentence_ends() -> None:
    assert list(sentences("Ja. Am 3. Oktober!")) == ["Ja. Am 3. Oktober!"]
    long = "Ja. Morgen um halb vier am 3. Oktober!\nGut. " + "x" * 300
    assert list(sentences(long))[:3] == ["Ja.", "Morgen um halb vier am 3. Oktober!", "Gut."]
