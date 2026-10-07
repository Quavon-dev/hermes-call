"""Kokoro-FastAPI (OpenAI-compatible /v1/audio/speech) streaming client."""

import time
from collections.abc import AsyncIterator

import httpx

from .metrics import METRICS

SAMPLE_RATE = 24_000


class KokoroTts:
    def __init__(self, url: str, voice: str, model: str = "kokoro", speed: float = 1.0) -> None:
        self._client = httpx.AsyncClient(base_url=url, timeout=httpx.Timeout(30.0, connect=5.0))
        self._voice = voice
        self._model = model
        self._speed = speed
        self._cache: dict[str, bytes] = {}

    async def preload(self, text: str) -> None:
        if not text or text in self._cache:
            return
        chunks = [chunk async for chunk in self._remote(text)]
        if chunks:
            self._cache[text] = b"".join(chunks)

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        """Yields 16-bit little-endian mono PCM at 24 kHz."""
        cached = self._cache.get(text)
        if cached is not None:
            yield cached
            return
        async for chunk in self._remote(text):
            yield chunk

    async def _remote(self, text: str) -> AsyncIterator[bytes]:
        body = {
            "model": self._model,
            "input": text,
            "voice": self._voice,
            "response_format": "pcm",
            "stream": True,
            "speed": self._speed,
        }
        started: float | None = time.monotonic()
        async with self._client.stream("POST", "/v1/audio/speech", json=body) as response:
            response.raise_for_status()
            carry = b""
            async for chunk in response.aiter_bytes():
                data = carry + chunk
                usable = len(data) - len(data) % 2
                carry = data[usable:]
                if usable:
                    if started is not None:
                        METRICS.tts_first_audio.observe(time.monotonic() - started)
                        started = None
                    yield data[:usable]

    async def close(self) -> None:
        await self._client.aclose()
