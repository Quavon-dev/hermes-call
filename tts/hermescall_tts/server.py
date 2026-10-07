# SPDX-License-Identifier: MIT
"""OpenAI-compatible speech endpoint for the German call voice, loopback only.

POST /v1/audio/speech  {"input", "voice", "speed", "response_format": "pcm"} -> 16-bit mono PCM at 24 kHz,
                       streamed sentence by sentence
GET  /v1/audio/voices  {"voices": [...]}
GET  /health           {"status": "ok"}
"""

import asyncio
import ipaddress
import logging
import re
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from typing import Protocol

import numpy as np
from aiohttp import web

log = logging.getLogger(__name__)

SAMPLE_RATE = 24_000
MAX_INPUT_CHARS = 4000
MAX_BODY_BYTES = 64 * 1024
SPLIT_ABOVE_CHARS = 300
_SENTENCES = re.compile(r"(?<=[^\d\s][.!?…])\s+|\n+")


class Engine(Protocol):
    voices: list[str]

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray: ...


def sentences(text: str) -> Iterator[str]:
    """The bridge sends one sentence at a time; longer texts (spoken chat replies) stream per sentence."""
    for sentence in _SENTENCES.split(text) if len(text) > SPLIT_ABOVE_CHARS else [text]:
        if sentence := sentence.strip():
            yield sentence


def pcm16(audio: np.ndarray) -> bytes:
    return (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()


def build_app(engine: Engine) -> web.Application:
    worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts")

    async def health(request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def voices(request: web.Request) -> web.Response:
        return web.json_response({"voices": engine.voices})

    async def speech(request: web.Request) -> web.StreamResponse:
        try:
            body = await request.json()
        except ValueError:
            raise web.HTTPBadRequest(text="JSON body expected") from None
        if not isinstance(body, dict):
            raise web.HTTPBadRequest(text="JSON object expected")
        text, voice, speed = body.get("input"), body.get("voice", engine.voices[0]), body.get("speed", 1.0)
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_INPUT_CHARS:
            raise web.HTTPBadRequest(text=f"input: 1 to {MAX_INPUT_CHARS} characters")
        if voice not in engine.voices:
            raise web.HTTPBadRequest(text=f"voice: one of {', '.join(engine.voices)}")
        if isinstance(speed, bool) or not isinstance(speed, int | float) or not 0.5 <= speed <= 2.0:
            raise web.HTTPBadRequest(text="speed: 0.5 to 2.0")
        if body.get("response_format", "pcm") != "pcm":
            raise web.HTTPBadRequest(text="response_format: pcm")
        response = web.StreamResponse(headers={"Content-Type": "audio/pcm", "X-Sample-Rate": str(SAMPLE_RATE)})
        await response.prepare(request)
        loop = asyncio.get_running_loop()
        started = time.monotonic()
        first: float | None = None
        seconds = 0.0
        for sentence in sentences(text):
            audio = await loop.run_in_executor(worker, engine.synthesize, sentence, voice, float(speed))
            if first is None:
                first = time.monotonic() - started
            seconds += len(audio) / SAMPLE_RATE
            await response.write(pcm16(audio))
        took = time.monotonic() - started
        log.info(
            "speech: %d characters, first audio %.0f ms, %.1f s of audio in %.0f ms (real-time factor %.2f)",
            len(text),
            (first or 0.0) * 1000,
            seconds,
            took * 1000,
            took / seconds if seconds else 0.0,
        )
        await response.write_eof()
        return response

    async def close(app: web.Application) -> None:
        worker.shutdown(wait=False, cancel_futures=True)

    app = web.Application(client_max_size=MAX_BODY_BYTES)
    app.router.add_get("/health", health)
    app.router.add_get("/v1/audio/voices", voices)
    app.router.add_post("/v1/audio/speech", speech)
    app.on_cleanup.append(close)
    return app


def loopback(host: str) -> str:
    if host != "localhost" and not ipaddress.ip_address(host).is_loopback:
        raise ValueError(f"{host} is not a loopback address; the speech service never listens on the network")
    return host
