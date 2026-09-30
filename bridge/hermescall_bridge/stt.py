"""faster-whisper transcription on one worker thread, live calls first.

Live-call utterances (`transcribe`) always go ahead of voice notes (`transcribe_background`).
A voice note (up to 5 minutes) is cut into pieces of at most `PIECE_SECONDS` at quiet points,
so a live utterance waits for at most one piece, never for a whole note.
"""

import asyncio
import itertools
import logging
import queue
import threading
import time
from dataclasses import dataclass, field

import numpy as np
from faster_whisper import WhisperModel

from .metrics import METRICS

log = logging.getLogger(__name__)

RATE = 16_000
PIECE_SECONDS = 25
# A cut goes at the quietest 100 ms within the last `CUT_WINDOW_SECONDS` of a piece.
CUT_WINDOW_SECONDS = 5
LIVE, BACKGROUND = 0, 1


def split_audio(audio: np.ndarray, piece_seconds: int = PIECE_SECONDS) -> list[np.ndarray]:
    """≤ piece_seconds pieces, cut where the audio is quietest near each boundary (not mid-word)."""
    limit, window, step = piece_seconds * RATE, CUT_WINDOW_SECONDS * RATE, RATE // 10
    pieces, start = [], 0
    while len(audio) - start > limit:
        lo = start + limit - window
        frames = [(float(np.abs(audio[i : i + step]).mean()), i) for i in range(lo, start + limit - step + 1, step)]
        cut = min(frames)[1] + step // 2 if frames else start + limit
        pieces.append(audio[start:cut])
        start = cut
    pieces.append(audio[start:])
    return pieces


@dataclass(order=True)
class _Job:
    priority: int
    serial: int
    audio: np.ndarray = field(compare=False)
    loop: asyncio.AbstractEventLoop = field(compare=False)
    future: asyncio.Future = field(compare=False)


class Transcriber:
    def __init__(self, model_path: str, threads: int, compute_type: str = "int8") -> None:
        self._model = WhisperModel(model_path, device="cpu", compute_type=compute_type, cpu_threads=threads)
        self._model.transcribe(np.zeros(RATE, dtype=np.float32), language="en", beam_size=1)
        self._jobs: queue.PriorityQueue[_Job] = queue.PriorityQueue()
        self._serial = itertools.count()
        self._worker = threading.Thread(target=self._work, name="stt", daemon=True)
        self._worker.start()

    def _transcribe(self, audio: np.ndarray) -> str:
        segments, _ = self._model.transcribe(
            audio,
            language="en",
            beam_size=1,
            vad_filter=False,
            condition_on_previous_text=False,
            without_timestamps=True,
        )
        return " ".join(segment.text.strip() for segment in segments if segment.no_speech_prob < 0.6).strip()

    def _work(self) -> None:
        while True:
            job = self._jobs.get()
            started = time.monotonic()
            try:
                result: str | BaseException = self._transcribe(job.audio)
            except Exception as exc:  # handed to the waiting coroutine, which re-raises it
                result = exc
            if job.priority == LIVE and len(job.audio):
                METRICS.stt_rtf.observe((time.monotonic() - started) / (len(job.audio) / RATE))
            job.loop.call_soon_threadsafe(_settle, job.future, result)

    async def _submit(self, audio: np.ndarray, priority: int) -> str:
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        self._jobs.put(_Job(priority, next(self._serial), audio, loop, future))
        return await future

    async def transcribe(self, audio: np.ndarray) -> str:
        """A live-call utterance: goes ahead of any queued voice-note work."""
        return await self._submit(audio, LIVE)

    async def transcribe_background(self, audio: np.ndarray) -> str:
        """A voice note: in pieces, each queued behind live-call utterances."""
        texts = [await self._submit(piece, BACKGROUND) for piece in split_audio(audio)]
        return " ".join(text for text in texts if text).strip()


def _settle(future: asyncio.Future, result: "str | BaseException") -> None:
    if future.done():
        return
    if isinstance(result, BaseException):
        future.set_exception(result)
    else:
        future.set_result(result)
