# SPDX-License-Identifier: MIT
"""German Kokoro voices (StyleTTS2 fine-tunes of Kokoro-82M) on the CPU.

Each voice is its own fine-tuned model: <models>/<voice>/{model.pth,voice.pt} plus a shared
<models>/config.json. German text goes through misaki's German G2P (number, date and abbreviation
normalization, then espeak-ng) and the phonemes straight into Kokoro's model.
"""

import importlib.util
import logging
import re
import sys
import types
from pathlib import Path

import numpy as np

log = logging.getLogger(__name__)

CONTEXT = 510
SYSTEM_ESPEAK = (
    Path("/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1"),
    Path("/usr/lib/aarch64-linux-gnu/libespeak-ng.so.1"),
)
_CLAUSE = re.compile(r"(?<=[,;:])\s+")


def _import_kokoro_model():
    """kokoro/__init__ imports its English pipeline (spaCy, transformers' BART); only the model is used."""
    spec = importlib.util.find_spec("kokoro")
    if spec is None or spec.submodule_search_locations is None:
        raise ImportError("kokoro (the pinned German fork) is not on PYTHONPATH")
    if "kokoro" not in sys.modules:
        package = types.ModuleType("kokoro")
        package.__path__ = list(spec.submodule_search_locations)
        sys.modules["kokoro"] = package
    from kokoro.model import KModel

    return KModel


def _use_system_espeak() -> None:
    import misaki.espeak  # noqa: F401  # sets espeakng-loader's bundled library first
    from phonemizer.backend.espeak.wrapper import EspeakWrapper

    for library in SYSTEM_ESPEAK:
        if library.exists():
            EspeakWrapper.set_library(str(library))
            EspeakWrapper.set_data_path(str(library.parent / "espeak-ng-data"))
            return


class KokoroGerman:
    def __init__(self, models: Path, voices: list[str], threads: int = 4) -> None:
        import torch
        from misaki.de import DEG2P

        torch.set_num_threads(threads)
        _use_system_espeak()
        model_class = _import_kokoro_model()
        self._torch = torch
        self._g2p = DEG2P()
        self._models = {}
        self._packs = {}
        for voice in voices:
            folder = models / voice
            self._models[voice] = model_class(
                repo_id="hexgrad/Kokoro-82M", config=str(models / "config.json"), model=str(folder / "model.pth")
            ).eval()
            self._packs[voice] = torch.load(folder / "voice.pt", map_location="cpu", weights_only=True)
        self.voices = list(voices)
        for voice in voices:
            self.synthesize("Hallo.", voice, 1.0)
        log.info("German voices ready: %s (%d threads)", ", ".join(voices), threads)

    def phonemes(self, text: str) -> str:
        phonemes, _ = self._g2p(text)
        return (phonemes or "").replace("ʏ", "y")

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        parts = [self.phonemes(text)]
        if len(parts[0]) > CONTEXT:
            parts = [self.phonemes(clause) for clause in _CLAUSE.split(text)]
        audio = [self._infer(part[:CONTEXT], voice, speed) for part in parts if part.strip()]
        return np.concatenate(audio) if audio else np.zeros(0, dtype=np.float32)

    def _infer(self, phonemes: str, voice: str, speed: float) -> np.ndarray:
        style = self._packs[voice][len(phonemes) - 1]
        with self._torch.inference_mode():
            audio = self._models[voice](phonemes, style, speed)
        return np.asarray(audio, dtype=np.float32).reshape(-1)
