"""Kokoro-FastAPI (OpenAI-compatible /v1/audio/speech) streaming client."""

from collections.abc import AsyncIterator

import httpx

SAMPLE_RATE = 24_000


class KokoroTts:
    def __init__(self, url: str, voice: str, model: str = "kokoro", speed: float = 1.0) -> None:
        self._client = httpx.AsyncClient(base_url=url, timeout=httpx.Timeout(30.0, connect=5.0))
        self._voice = voice
        self._model = model
        self._speed = speed

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        """Yields 16-bit little-endian mono PCM at 24 kHz."""
        body = {
            "model": self._model,
            "input": text,
            "voice": self._voice,
            "response_format": "pcm",
            "stream": True,
            "speed": self._speed,
        }
        async with self._client.stream("POST", "/v1/audio/speech", json=body) as response:
            response.raise_for_status()
            carry = b""
            async for chunk in response.aiter_bytes():
                data = carry + chunk
                usable = len(data) - len(data) % 2
                carry = data[usable:]
                if usable:
                    yield data[:usable]

    async def close(self) -> None:
        await self._client.aclose()
