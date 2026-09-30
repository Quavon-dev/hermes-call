"""faster-whisper transcription on a dedicated worker thread."""

import asyncio
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from faster_whisper import WhisperModel


class Transcriber:
    def __init__(self, model_path: str, threads: int, compute_type: str = "int8") -> None:
        self._model = WhisperModel(model_path, device="cpu", compute_type=compute_type, cpu_threads=threads)
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stt")
        self._model.transcribe(np.zeros(16_000, dtype=np.float32), language="en", beam_size=1)

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

    async def transcribe(self, audio: np.ndarray) -> str:
        return await asyncio.get_running_loop().run_in_executor(self._executor, self._transcribe, audio)
