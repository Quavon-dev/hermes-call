"""Streaming Silero VAD using the ONNX model shipped with faster-whisper.

One ONNX session is shared by all calls (loading it costs ~100 ms and memory); each
`StreamingVad` keeps its own recurrent state. Inference runs on a dedicated worker thread
(`probability_async`) so the event loop never waits on ONNX.
"""

import asyncio
import os
import threading
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import onnxruntime
from faster_whisper.utils import get_assets_path

SAMPLE_RATE = 16_000
CHUNK = 512
_CONTEXT = 64

_session: onnxruntime.InferenceSession | None = None
_session_lock = threading.Lock()
_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vad")


def shared_session() -> onnxruntime.InferenceSession:
    global _session
    with _session_lock:
        if _session is None:
            opts = onnxruntime.SessionOptions()
            opts.inter_op_num_threads = 1
            opts.intra_op_num_threads = 1
            opts.log_severity_level = 4
            path = os.path.join(get_assets_path(), "silero_vad_v6.onnx")
            _session = onnxruntime.InferenceSession(path, providers=["CPUExecutionProvider"], sess_options=opts)
        return _session


class StreamingVad:
    def __init__(self) -> None:
        self._session = shared_session()
        self.reset()

    def reset(self) -> None:
        self._h = np.zeros((1, 1, 128), dtype=np.float32)
        self._c = np.zeros((1, 1, 128), dtype=np.float32)
        self._context = np.zeros(_CONTEXT, dtype=np.float32)

    def probability(self, chunk: np.ndarray) -> float:
        """Speech probability for exactly 512 float32 samples at 16 kHz."""
        window = np.concatenate([self._context, chunk])[np.newaxis, :]
        output, self._h, self._c = self._session.run(None, {"input": window, "h": self._h, "c": self._c})
        self._context = chunk[-_CONTEXT:]
        return float(np.asarray(output).reshape(-1)[0])

    async def probability_async(self, chunk: np.ndarray) -> float:
        """Same, on the VAD worker thread (chunks of one stream must be awaited in order)."""
        return await asyncio.get_running_loop().run_in_executor(_executor, self.probability, chunk)
