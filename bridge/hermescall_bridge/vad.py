"""Streaming Silero VAD using the ONNX model shipped with faster-whisper."""

import os

import numpy as np
import onnxruntime
from faster_whisper.utils import get_assets_path

SAMPLE_RATE = 16_000
CHUNK = 512
_CONTEXT = 64


class StreamingVad:
    def __init__(self) -> None:
        opts = onnxruntime.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        opts.log_severity_level = 4
        path = os.path.join(get_assets_path(), "silero_vad_v6.onnx")
        self._session = onnxruntime.InferenceSession(path, providers=["CPUExecutionProvider"], sess_options=opts)
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
