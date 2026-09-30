"""Audio sources/sinks for the test client: WAV files (with latency measurement) or mic/speaker."""

import asyncio
import fractions
import time
import wave

import av
import numpy as np
from aiortc import MediaStreamTrack
from aiortc.mediastreams import MediaStreamError

RATE = 48_000
FRAME = 960
SPEECH_RMS = 0.02


def _frame(samples: np.ndarray, pts: int) -> av.AudioFrame:
    frame = av.AudioFrame.from_ndarray(samples.astype(np.int16).reshape(1, -1), format="s16", layout="mono")
    frame.sample_rate = RATE
    frame.pts = pts
    frame.time_base = fractions.Fraction(1, RATE)
    return frame


def load_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as wav:
        if wav.getsampwidth() != 2:
            raise ValueError("WAV must be 16-bit PCM")
        data = np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16).reshape(-1, wav.getnchannels())[:, 0]
        rate = wav.getframerate()
    if rate != RATE:
        positions = np.arange(0, len(data), rate / RATE)
        data = np.interp(positions, np.arange(len(data)), data).astype(np.int16)
    return data


class PacedTrack(MediaStreamTrack):
    """Sends 20 ms frames in real time from a sample provider."""

    kind = "audio"

    def __init__(self) -> None:
        super().__init__()
        self._pts = 0
        self._start: float | None = None

    def next_samples(self) -> np.ndarray:
        raise NotImplementedError

    async def recv(self) -> av.AudioFrame:
        if self.readyState != "live":
            raise MediaStreamError
        if self._start is None:
            self._start = time.monotonic()
        wait = self._start + self._pts / RATE - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        frame = _frame(self.next_samples(), self._pts)
        self._pts += FRAME
        return frame


class WavTrack(PacedTrack):
    """Plays a WAV once after `delay` seconds, then silence; records when speech ended."""

    def __init__(self, samples: np.ndarray, delay: float = 1.0) -> None:
        super().__init__()
        self._samples = samples
        self._delay_frames = int(delay * RATE / FRAME)
        self._index = 0
        loud = np.flatnonzero(np.abs(samples.astype(np.float32)) / 32768 > SPEECH_RMS)
        self._speech_end = int(loud[-1]) if len(loud) else len(samples)
        self.speech_ended_at: float | None = None

    def next_samples(self) -> np.ndarray:
        if self._delay_frames > 0:
            self._delay_frames -= 1
            return np.zeros(FRAME, dtype=np.int16)
        chunk = self._samples[self._index : self._index + FRAME]
        self._index += FRAME
        if self.speech_ended_at is None and self._index >= self._speech_end:
            self.speech_ended_at = time.monotonic()
        return np.pad(chunk, (0, FRAME - len(chunk)))


class MicTrack(PacedTrack):
    def __init__(self) -> None:
        super().__init__()
        import sounddevice

        self._queue: asyncio.Queue[np.ndarray] = asyncio.Queue(maxsize=50)
        loop = asyncio.get_running_loop()

        def callback(indata, frames, time_info, status) -> None:
            loop.call_soon_threadsafe(self._put, indata[:, 0].copy())

        self._stream = sounddevice.InputStream(samplerate=RATE, channels=1, dtype="int16", blocksize=FRAME, callback=callback)
        self._stream.start()

    def _put(self, samples: np.ndarray) -> None:
        if self._queue.full():
            self._queue.get_nowait()
        self._queue.put_nowait(samples)

    def next_samples(self) -> np.ndarray:
        return self._queue.get_nowait() if not self._queue.empty() else np.zeros(FRAME, dtype=np.int16)


async def consume(track: MediaStreamTrack, out_path: str | None, source: PacedTrack) -> list[float]:
    """Plays or records the remote audio; returns latencies (s) from each end of
    local speech to the first following remote speech."""
    resampler = av.AudioResampler(format="s16", layout="mono", rate=RATE)
    recorded: list[np.ndarray] = []
    latencies: list[float] = []
    speaker = None
    if out_path is None:
        import sounddevice

        speaker = sounddevice.OutputStream(samplerate=RATE, channels=1, dtype="int16")
        speaker.start()
    measured_for: float | None = None
    try:
        while True:
            try:
                frame = await track.recv()
            except MediaStreamError:
                break
            for out in resampler.resample(frame):
                samples = out.to_ndarray().reshape(-1)
                if speaker is not None:
                    speaker.write(samples)
                else:
                    recorded.append(samples)
                ended = getattr(source, "speech_ended_at", None)
                loud = np.sqrt(np.mean((samples.astype(np.float32) / 32768) ** 2)) > SPEECH_RMS
                if ended and loud and measured_for != ended:
                    latencies.append(time.monotonic() - ended)
                    measured_for = ended
    finally:
        if speaker is not None:
            speaker.stop()
        if out_path and recorded:
            with wave.open(out_path, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(RATE)
                wav.writeframes(np.concatenate(recorded).astype(np.int16).tobytes())
    return latencies
