# SPDX-License-Identifier: MIT
"""KokoroGerman with stand-ins for torch, misaki and the Kokoro model (the real ones only run on the server)."""

import contextlib
import sys
import types

import numpy as np

from hermescall_tts import engine as engine_mod


class FakeModel:
    calls: list[tuple[str, object, float]] = []

    def __init__(self, repo_id: str, config: str, model: str) -> None:
        self.path = model

    def eval(self) -> "FakeModel":
        return self

    def __call__(self, phonemes: str, style, speed: float) -> np.ndarray:
        FakeModel.calls.append((phonemes, style, speed))
        return np.ones(len(phonemes), dtype=np.float32)


class FakeG2P:
    def __call__(self, text: str) -> tuple[str, None]:
        return text.replace("ü", "ʏ"), None


def fake_modules(monkeypatch) -> None:
    torch = types.SimpleNamespace(
        set_num_threads=lambda n: None,
        load=lambda path, map_location, weights_only: [f"style{i}" for i in range(510)],
        inference_mode=contextlib.nullcontext,
    )
    monkeypatch.setitem(sys.modules, "torch", torch)
    misaki, de = types.ModuleType("misaki"), types.ModuleType("misaki.de")
    de.DEG2P = FakeG2P
    monkeypatch.setitem(sys.modules, "misaki", misaki)
    monkeypatch.setitem(sys.modules, "misaki.de", de)
    monkeypatch.setattr(engine_mod, "_use_system_espeak", lambda: None)
    monkeypatch.setattr(engine_mod, "_import_kokoro_model", lambda: FakeModel)
    FakeModel.calls = []


def test_each_voice_is_its_own_model_and_is_warmed_up(monkeypatch, tmp_path) -> None:
    fake_modules(monkeypatch)
    german = engine_mod.KokoroGerman(tmp_path, ["dm_thorsten", "df_victoria"], threads=2)
    assert german.voices == ["dm_thorsten", "df_victoria"]
    assert german._models["df_victoria"].path == str(tmp_path / "df_victoria" / "model.pth")
    assert [call[0] for call in FakeModel.calls] == ["Hallo.", "Hallo."]


def test_short_u_is_mapped_and_the_style_matches_the_phoneme_count(monkeypatch, tmp_path) -> None:
    fake_modules(monkeypatch)
    german = engine_mod.KokoroGerman(tmp_path, ["dm_thorsten"])
    FakeModel.calls = []
    audio = german.synthesize("Müller", "dm_thorsten", 1.08)
    assert FakeModel.calls == [("Myller", "style5", 1.08)] and len(audio) == 6


def test_text_beyond_the_model_context_is_split_at_clauses(monkeypatch, tmp_path) -> None:
    fake_modules(monkeypatch)
    german = engine_mod.KokoroGerman(tmp_path, ["dm_thorsten"])
    FakeModel.calls = []
    clause = "a" * 300
    german.synthesize(f"{clause}, {clause}", "dm_thorsten", 1.0)
    assert [len(call[0]) for call in FakeModel.calls] == [301, 300]
    FakeModel.calls = []
    german.synthesize("b" * 700, "dm_thorsten", 1.0)
    assert [len(call[0]) for call in FakeModel.calls] == [engine_mod.CONTEXT]
    assert len(german.synthesize("", "dm_thorsten", 1.0)) == 0
