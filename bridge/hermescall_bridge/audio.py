"""WebRTC audio plumbing: an outgoing speech track and an inbound reader."""

import asyncio
import fractions
import time
from collections.abc import AsyncIterator

import av
import numpy as np
from aiortc import MediaStreamTrack
from aiortc.mediastreams import MediaStreamError

OUT_RATE = 48_000
FRAME_SAMPLES = 960
_FRAME_BYTES = FRAME_SAMPLES * 2


class SpeechTrack(MediaStreamTrack):
    """Plays queued 48 kHz mono PCM in 20 ms frames, silence when idle."""

    kind = "audio"

    def __init__(self) -> None:
        super().__init__()
        self._buffer = bytearray()
        self._pts = 0
        self._start: float | None = None
        self._resampler = av.AudioResampler(format="s16", layout="mono", rate=OUT_RATE)
        self.drained = asyncio.Event()
        self.drained.set()

    @property
    def speaking(self) -> bool:
        return bool(self._buffer)

    @property
    def buffered_seconds(self) -> float:
        return len(self._buffer) / (OUT_RATE * 2)

    def enqueue_pcm(self, pcm: bytes, rate: int) -> None:
        if rate == OUT_RATE:
            self._buffer += pcm
        else:
            frame = av.AudioFrame.from_ndarray(np.frombuffer(pcm, dtype=np.int16).reshape(1, -1), format="s16", layout="mono")
            frame.sample_rate = rate
            for out in self._resampler.resample(frame):
                self._buffer += out.to_ndarray().tobytes()
        if self._buffer:
            self.drained.clear()

    def clear(self) -> None:
        self._buffer.clear()
        self.drained.set()

    async def recv(self) -> av.AudioFrame:
        if self.readyState != "live":
            raise MediaStreamError
        if self._start is None:
            self._start = time.monotonic()
        wait = self._start + self._pts / OUT_RATE - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        chunk = bytes(self._buffer[:_FRAME_BYTES])
        del self._buffer[:_FRAME_BYTES]
        if not self._buffer:
            self.drained.set()
        chunk = chunk.ljust(_FRAME_BYTES, b"\0")
        frame = av.AudioFrame.from_ndarray(np.frombuffer(chunk, dtype=np.int16).reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate = OUT_RATE
        frame.pts = self._pts
        frame.time_base = fractions.Fraction(1, OUT_RATE)
        self._pts += FRAME_SAMPLES
        return frame


async def read_16k(track: MediaStreamTrack) -> AsyncIterator[np.ndarray]:
    """Yields float32 mono 16 kHz audio blocks from a remote WebRTC track."""
    resampler = av.AudioResampler(format="s16", layout="mono", rate=16_000)
    while True:
        try:
            frame = await track.recv()
        except MediaStreamError:
            return
        for out in resampler.resample(frame):
            yield out.to_ndarray().reshape(-1).astype(np.float32) / 32768.0
