"""Unit tests for stt.py, tts.py and common/blobs.py (K4)."""

import asyncio

import httpx
import numpy as np
import pytest

from hermescall_bridge import stt
from hermescall_bridge.metrics import METRICS
from hermescall_bridge.tts import KokoroTts
from hermescall_common import blobs
from hermescall_common.errors import CryptoError, ProtocolError

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import online_device, stop_devices  # noqa: F401 - fixtures
from .test_regressions import SlowModel

# ---- stt -----------------------------------------------------------------------


def test_split_audio_cuts_long_notes_at_quiet_points() -> None:
    loud = np.ones(stt.RATE * 60, dtype=np.float32) * 0.5
    loud[stt.RATE * 22 : stt.RATE * 22 + stt.RATE // 5] = 0.0  # a pause at 22 s
    pieces = stt.split_audio(loud)
    assert sum(len(p) for p in pieces) == len(loud)
    assert all(len(p) <= stt.PIECE_SECONDS * stt.RATE for p in pieces)
    assert abs(len(pieces[0]) / stt.RATE - 22.05) < 0.2, "the first cut goes into the pause"
    assert len(stt.split_audio(np.zeros(stt.RATE * 3, dtype=np.float32))) == 1


async def test_background_note_is_transcribed_piecewise_and_joined(monkeypatch) -> None:
    monkeypatch.setattr(stt, "WhisperModel", SlowModel)
    transcriber = stt.Transcriber("model", 1)
    text = await transcriber.transcribe_background(np.zeros(60 * stt.RATE, dtype=np.float32))
    assert text == "words words words"
    assert len(transcriber._model.log) == 1 + 3  # warm-up + three pieces


async def test_live_transcription_errors_reach_the_caller_and_rtf_is_measured(monkeypatch) -> None:
    class Broken(SlowModel):
        def transcribe(self, audio, **kwargs):
            if len(audio) == 7:
                raise RuntimeError("model crashed")
            return super().transcribe(audio, **kwargs)

    monkeypatch.setattr(stt, "WhisperModel", Broken)
    transcriber = stt.Transcriber("model", 1)
    before = METRICS.stt_rtf.count
    assert await transcriber.transcribe(np.zeros(stt.RATE, dtype=np.float32)) == "words"
    assert METRICS.stt_rtf.count == before + 1
    with pytest.raises(RuntimeError):
        await transcriber.transcribe(np.zeros(7, dtype=np.float32))
    assert await transcriber.transcribe(np.zeros(stt.RATE, dtype=np.float32)) == "words"  # the worker survived


# ---- tts -------------------------------------------------------------------------


async def test_kokoro_streams_whole_samples_and_sends_the_voice() -> None:
    seen: list[httpx.Request] = []

    async def body():
        for part in (b"\x01", b"\x02\x03", b"\x04\x05\x06"):
            yield part

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, content=body())

    tts = KokoroTts("http://127.0.0.1:8880", "bm_george")
    tts._client = httpx.AsyncClient(base_url="http://127.0.0.1:8880", transport=httpx.MockTransport(handler))
    chunks = [chunk async for chunk in tts.synthesize("Hello.")]
    assert all(len(c) % 2 == 0 for c in chunks) and b"".join(chunks) == b"\x01\x02\x03\x04\x05\x06"
    sent = seen[0]
    assert sent.url.path == "/v1/audio/speech" and b'"voice":"bm_george"' in sent.content.replace(b" ", b"")
    await tts.close()


async def test_kokoro_errors_raise() -> None:
    tts = KokoroTts("http://127.0.0.1:8880", "v")
    tts._client = httpx.AsyncClient(
        base_url="http://127.0.0.1:8880", transport=httpx.MockTransport(lambda request: httpx.Response(500))
    )
    with pytest.raises(httpx.HTTPStatusError):
        [chunk async for chunk in tts.synthesize("x")]
    await tts.close()


# ---- blobs --------------------------------------------------------------------------


def test_blob_seal_roundtrip_and_tamper_detection() -> None:
    key, sealed = blobs.seal(b"secret photo")
    assert blobs.open_sealed(key, sealed) == b"secret photo"
    with pytest.raises(CryptoError):
        blobs.open_sealed(key, sealed[:-1] + bytes([sealed[-1] ^ 1]))
    with pytest.raises(CryptoError):
        blobs.open_sealed(bytes(32), sealed)
    other_key, other = blobs.seal(b"secret photo")
    assert other_key != key and other != sealed


def test_blob_size_limit() -> None:
    with pytest.raises(ProtocolError):
        blobs.seal(b"\0" * (blobs.MAX_PLAINTEXT + 1))


def test_pinned_relay_needs_the_session_certificate() -> None:
    class Relay:
        endpoint = type("E", (), {"pin": "abc", "authority": "relay"})()
        cert_fingerprint = None

    with pytest.raises(ProtocolError):
        blobs._ssl(Relay())
    Relay.cert_fingerprint = b"\x00" * 32
    assert blobs._ssl(Relay()) is not True
    Relay.endpoint = type("E", (), {"pin": "", "authority": "relay"})()
    assert blobs._ssl(Relay()) is True


async def test_blob_transfer_through_the_relay(h) -> None:  # noqa: F811
    device = await online_device(h)
    key, sealed = blobs.seal(b"x" * 1000)
    blob_id = await blobs.upload(h.bridge.relay, sealed, to=device.state["device_id"])
    assert blobs.open_sealed(key, await blobs.download(device.session, blob_id)) == b"x" * 1000
    await blobs.delete(device.session, blob_id)
    with pytest.raises(ProtocolError):
        await blobs.download(device.session, blob_id)
    await asyncio.sleep(0)
