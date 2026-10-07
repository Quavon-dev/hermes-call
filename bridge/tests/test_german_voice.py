# SPDX-License-Identifier: MIT
"""German calls: language-aware config, chunking, the speakerphone echo guard and the acknowledgement."""

import asyncio
import json
import time

import httpx
import numpy as np
import pytest

from hermescall_bridge import stt as stt_mod
from hermescall_bridge.audio import SpeechTrack
from hermescall_bridge.config import ConfigError, load
from hermescall_bridge.conversation import Conversation, TurnSettings
from hermescall_bridge.hermes import HermesClient, TextDelta, ToolProgress
from hermescall_bridge.lang import voice_language_mismatch
from hermescall_bridge.metrics import METRICS
from hermescall_bridge.text import Chunker
from hermescall_bridge.voice import speech_text

from .conftest import FakeHermes, FakeTts
from .test_units import ThinkingHermes, blocks_of, drain, speech_16k, talk, until

GERMAN = TurnSettings(barge_in=False, language="de", acknowledgement_text="Einen Moment.")


def write(tmp_path, text: str):
    path = tmp_path / "bridge.toml"
    path.write_text(text)
    return path


# ---- config ---------------------------------------------------------------------


def test_german_call_language_sets_every_default(tmp_path) -> None:
    config = load(write(tmp_path, "[voice]\nlanguage = 'de'\n"))
    assert (config.language, config.stt_model, config.stt_beam_size) == ("de", "small", 2)
    assert (config.tts_voice, config.tts_url) == ("dm_thorsten", "http://127.0.0.1:8881")
    assert (config.acknowledgement_after_ms, config.acknowledgement_text) == (1800, "Einen Moment.")
    assert config.end_silence_ms == 500 and config.warnings == []


def test_english_defaults_are_unchanged(tmp_path) -> None:
    config = load(write(tmp_path, ""))
    assert (config.language, config.stt_model, config.stt_beam_size) == ("en", "base.en", 1)
    assert (config.tts_voice, config.tts_url) == ("bm_george", "http://127.0.0.1:8880")
    assert config.acknowledgement_text == "One moment."


def test_older_configs_take_the_language_from_stt(tmp_path) -> None:
    config = load(write(tmp_path, "[stt]\nmodel = 'small'\nlanguage = 'de'\n[tts]\nvoice = 'bm_george'\n"))
    assert config.language == "de" and config.tts_url == "http://127.0.0.1:8881"
    assert config.warnings == ["tts.voice bm_george is a en Kokoro voice, but the call language is de"]


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("[voice]\nlanguage = 'de'\n[stt]\nmodel = 'base.en'\n", "English-only"),
        ("[stt]\nmodel = 'small.en'\nlanguage = 'de'\n", "English-only"),
        ("[voice]\nlanguage = 'de'\n[stt]\nlanguage = 'en'\n", "must match"),
        ("[voice]\nlanguage = 'german'\n", "language code"),
        ("[voice]\nlanguage = 'fr'\n", "no default voice"),
        ("[stt]\ninitial_prompt = '" + "x" * 201 + "'\n", "initial_prompt"),
        ("[tts]\nvoice = 'bad voice'\n", "tts.voice"),
        ("[tts]\nurl = 'http://10.0.0.2:8881'\n", "loopback"),
    ],
)
def test_invalid_language_combinations_fail_clearly(tmp_path, text, message) -> None:
    with pytest.raises(ConfigError, match=message):
        load(write(tmp_path, text))


def test_voice_language_mismatch_only_for_known_kokoro_voices() -> None:
    assert voice_language_mismatch("af_heart", "de")
    assert voice_language_mismatch("dm_thorsten", "de") is None
    assert voice_language_mismatch("dm_thorsten", "en")
    assert voice_language_mismatch("thorsten", "de") is None
    assert voice_language_mismatch("bm_george", "en") is None


def test_vocabulary_prompt_is_optional(tmp_path) -> None:
    assert load(write(tmp_path, "")).stt_initial_prompt == ""
    config = load(write(tmp_path, "[stt]\ninitial_prompt = ' Hermes, Home Assistant '\n"))
    assert config.stt_initial_prompt == "Hermes, Home Assistant"


# ---- chunking -------------------------------------------------------------------


def chunks_of(*deltas: str) -> list[str]:
    chunker = Chunker("ein Link")
    out = [chunk for delta in deltas for chunk in chunker.feed(delta)]
    return out + chunker.flush()


def test_ordinals_and_abbreviations_do_not_end_a_chunk() -> None:
    assert chunks_of("Dein Termin ist am 3. Oktober bei Dr. Schneider. ", "Soll ich dich erinnern?") == [
        "Dein Termin ist am 3. Oktober bei Dr. Schneider.",
        "Soll ich dich erinnern?",
    ]


def test_long_streamed_first_sentence_is_cut_before_a_joining_word() -> None:
    sentence = "Morgen hast du um halb vier einen Termin beim Zahnarzt und danach noch das Training. "
    chunks = chunks_of(*(word + " " for word in sentence.split()))
    assert chunks == ["Morgen hast du um halb vier einen Termin beim Zahnarzt", "und danach noch das Training."]


def test_short_german_first_sentence_stays_whole() -> None:
    assert chunks_of("Morgen hast du um halb vier einen Termin. ") == ["Morgen hast du um halb vier einen Termin."]


def test_links_are_named_in_the_call_language() -> None:
    assert chunks_of("Siehe https://example.org/x dort.") == ["Siehe ein Link dort."]


def test_voice_replies_point_to_the_chat_in_the_call_language() -> None:
    assert speech_text("Satz eins. " * 300, limit=40, language="de").endswith("Mehr dazu im Chat.")


# ---- speakerphone echo (barge_in = false) ---------------------------------------


def german(hermes, tts, out, transcribe, settings: TurnSettings = GERMAN) -> Conversation:
    return Conversation(hermes, tts, transcribe, out, lambda r: asyncio.sleep(0, "deny"), settings=settings)


class Recognizer:
    def __init__(self, *texts: str) -> None:
        self.texts = list(texts)
        self.calls = 0

    async def __call__(self, audio: np.ndarray) -> str:
        self.calls += 1
        return self.texts.pop(0) if self.texts else "noch etwas"


async def test_echo_during_playback_starts_no_recognition_and_no_turn() -> None:
    hermes, tts, out, recognize = FakeHermes(), FakeTts(), SpeechTrack(), Recognizer()
    conversation = german(hermes, tts, out, recognize)
    out.enqueue_pcm(b"\1\0" * 48000 * 6, 48000)
    ignored = METRICS.playback_ignored_seconds.value()
    barge_ins = METRICS.barge_ins.value()
    speech, quiet = speech_16k(), np.zeros(16000, dtype=np.float32)
    await asyncio.wait_for(conversation.run(_source(np.concatenate([speech, quiet, speech, quiet]))), 10)
    assert hermes.turns == [] and recognize.calls == 0 and conversation._speculation is None
    assert conversation._utterance is None and conversation._interrupted is False
    assert METRICS.playback_ignored_seconds.value() - ignored > 2 and METRICS.barge_ins.value() == barge_ins


async def test_echo_tail_after_playback_is_ignored_then_listening_resumes() -> None:
    hermes, tts, out, recognize = FakeHermes(), FakeTts(), SpeechTrack(), Recognizer("wie spät ist es")
    conversation = german(hermes, tts, out, recognize, TurnSettings(barge_in=False, language="de", echo_tail_ms=600))
    speech, quiet = speech_16k()[: 61 * 512], np.zeros(16000, dtype=np.float32)

    async def playback_ends() -> None:
        out.enqueue_pcm(b"\1\0" * 4800, 48000)
        await asyncio.sleep(0)
        conversation._on_chunk(np.zeros(512, dtype=np.float32), 0.0)
        out.clear()

    async def tail_passes() -> None:
        await asyncio.sleep(0.7)

    await talk(conversation, playback_ends, speech[: 8 * 512], quiet[:4000], tail_passes, quiet, speech, quiet)
    assert [turn[1] for turn in hermes.turns] == ["wie spät ist es"] and recognize.calls == 1
    assert not hermes.turns[0][1].startswith("(I interrupted you.)")


async def test_a_gap_between_answer_sentences_stays_guarded_for_the_echo_tail() -> None:
    conversation = german(FakeHermes(), FakeTts(), SpeechTrack(), Recognizer(), TurnSettings(barge_in=False, echo_tail_ms=100))
    conversation._out.enqueue_pcm(b"\1\0" * 480, 48000)
    assert conversation._hears_playback()
    conversation._out.clear()
    assert conversation._hears_playback(), "the last words are still reaching the microphone"
    await asyncio.sleep(0.15)
    assert not conversation._hears_playback(), "a long silent tool run lets the owner speak again"


async def test_barge_in_enabled_keeps_full_duplex() -> None:
    conversation = german(FakeHermes(), FakeTts(), SpeechTrack(), Recognizer(), TurnSettings(barge_in=True))
    conversation._out.enqueue_pcm(b"\1\0" * 4800, 48000)
    assert not conversation._hears_playback()


async def test_tap_interrupts_playback_and_listening_resumes_at_once() -> None:
    hermes, tts, out, recognize = FakeHermes(), FakeTts(), SpeechTrack(), Recognizer("stopp, andere frage")
    conversation = german(hermes, tts, out, recognize)
    speech, quiet = speech_16k()[: 61 * 512], np.zeros(16000, dtype=np.float32)

    async def tap() -> None:
        out.enqueue_pcm(b"\1\0" * 48000 * 5, 48000)
        conversation._on_chunk(np.zeros(512, dtype=np.float32), 0.0)
        conversation.interrupt()
        assert not out.speaking and not conversation._hears_playback()

    await talk(conversation, tap, speech, quiet)
    assert [turn[1] for turn in hermes.turns] == ["(I interrupted you.) stopp, andere frage"]


async def test_push_to_talk_works_while_the_agent_speaks() -> None:
    hermes, tts, out, recognize = FakeHermes(), FakeTts(), SpeechTrack(), Recognizer("licht aus")
    conversation = german(hermes, tts, out, recognize)
    out.enqueue_pcm(b"\1\0" * 48000 * 5, 48000)
    conversation.set_ptt(True)
    assert not out.speaking
    for block in blocks_of(speech_16k()[: 30 * 512], 512):
        conversation._on_chunk(block)
    conversation.set_ptt(False)
    player = drain(out)
    await until(lambda: hermes.turns)
    await conversation.stop()
    player.cancel()
    assert hermes.turns[0][1].endswith("licht aus") and recognize.calls == 1


async def test_phone_transcripts_of_playback_are_dropped() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    conversation = german(hermes, tts, out, Recognizer())
    conversation.use_device_stt()
    out.enqueue_pcm(b"\1\0" * 48000, 48000)
    conversation.submit_text("Hallo, wie kann ich dir helfen?")
    assert conversation._turn is None
    out.clear()
    conversation._audible_until = 0.0
    conversation.submit_text("wie wird das wetter")
    await until(lambda: hermes.turns)
    await conversation.stop()
    assert [turn[1] for turn in hermes.turns] == ["wie wird das wetter"]


def _source(audio: np.ndarray):
    async def source():
        for block in blocks_of(audio):
            yield block
            await asyncio.sleep(0)

    return source()


# ---- acknowledgement ------------------------------------------------------------


class SlowHermes(FakeHermes):
    def __init__(self, delay: float, tool: bool = False) -> None:
        super().__init__()
        self.delay, self.tool = delay, tool

    async def turn(self, system, text, images=(), session_id=None):
        self.turns.append((system, text))
        if self.tool:
            yield ToolProgress("calendar", "running", "c1")
        await asyncio.sleep(self.delay)
        yield TextDelta("Morgen um halb vier hast du einen Termin.")


def acknowledging(after_ms: int = 200) -> TurnSettings:
    return TurnSettings(language="de", acknowledgement_after_ms=after_ms, acknowledgement_text="Einen Moment.")


async def answer(hermes, settings: TurnSettings, ended: float | None = None, carry=None) -> tuple[FakeTts, Conversation]:
    tts, out = FakeTts(), SpeechTrack()
    conversation = Conversation(hermes, tts, None, out, None, settings=settings)
    player = drain(out)
    await conversation._run_turn(None, time.monotonic() if ended is None else ended, "was steht morgen an", carry=carry)
    player.cancel()
    return tts, conversation


async def test_no_acknowledgement_for_a_fast_answer() -> None:
    tts, conversation = await answer(SlowHermes(0.0), acknowledging())
    assert "Einen Moment." not in tts.spoken
    assert ("Hermes", "Einen Moment.") not in conversation.transcript


async def test_slow_answer_gets_one_acknowledgement_timed_from_the_end_of_speech() -> None:
    tts, conversation = await answer(SlowHermes(0.4), acknowledging(300), ended=time.monotonic() - 0.25)
    assert tts.spoken.count("Einen Moment.") == 1 and tts.spoken[0] == "Einen Moment."
    assert all("Einen Moment" not in text for _, text in conversation.transcript)
    assert "This call is in German." in conversation._system


async def test_tool_start_acknowledges_at_once_and_only_once() -> None:
    tts, _ = await answer(SlowHermes(0.4, tool=True), acknowledging(5000))
    assert tts.spoken.count("Einen Moment.") == 1


async def test_a_continued_turn_does_not_acknowledge_again() -> None:
    from hermescall_bridge.conversation import _Said

    carry = _Said(None, text="was steht", acknowledged=True)
    tts, _ = await answer(SlowHermes(0.4, tool=True), acknowledging(100), carry=carry)
    assert "Einen Moment." not in tts.spoken


async def test_acknowledgement_after_zero_is_off_even_for_tools() -> None:
    tts, _ = await answer(SlowHermes(0.1, tool=True), acknowledging(0))
    assert "Einen Moment." not in tts.spoken


async def test_owner_going_on_before_the_answer_still_joins_with_barge_in_off() -> None:
    hermes, tts, out = ThinkingHermes(), FakeTts(), SpeechTrack()
    conversation = german(hermes, tts, out, Recognizer("ruf mama an", "und sag ihr ich komme später"))
    speech, quiet = speech_16k()[: 61 * 512], np.zeros(16000, dtype=np.float32)

    async def first_turn_started() -> None:
        await until(lambda: len(hermes.turns) == 1)

    await talk(conversation, quiet, speech, quiet, first_turn_started, speech, quiet)
    assert hermes.turns[-1][1] == "ruf mama an und sag ihr ich komme später"


# ---- Hermes route and speech recognition ----------------------------------------


async def test_voice_route_alias_is_sent_without_a_provider() -> None:
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200, json={"version": "0.22.0"})
        if request.url.path == "/v1/runs":
            bodies.append(json.loads(request.content))
            return httpx.Response(202, json={"run_id": "r1"})
        return httpx.Response(200, text='data: {"event": "run.completed", "output": "Hallo."}\n\n')

    client = HermesClient("http://127.0.0.1:8642", "key", "s", model="voice-fast", provider="", reasoning_effort="none")
    client._client = httpx.AsyncClient(base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(handler))
    events = [event async for event in client.turn("system", "hallo")]
    assert events == [TextDelta("Hallo.")]
    assert bodies[0]["model"] == "voice-fast" and "provider" not in bodies[0]
    assert bodies[0]["model_options"] == {"reasoning": {"enabled": False}}


class FakeWhisper:
    def __init__(self, *args, **kwargs) -> None:
        self.calls: list[dict] = []

    def transcribe(self, audio, **options):
        self.calls.append(options)
        return iter(()), None


async def test_live_recognition_decodes_once_and_uses_the_vocabulary_prompt(monkeypatch) -> None:
    monkeypatch.setattr(stt_mod, "WhisperModel", FakeWhisper)
    transcriber = stt_mod.Transcriber("model", 4, "de", 2, initial_prompt="Hermes, Home Assistant")
    audio = np.zeros(16000, dtype=np.float32)
    await transcriber.transcribe(audio)
    await transcriber.transcribe_background(audio)
    live, note = transcriber._model.calls[1:]
    assert live["language"] == "de" and live["beam_size"] == 2 and live["temperature"] == 0.0
    assert live["initial_prompt"] == "Hermes, Home Assistant"
    assert "temperature" not in note
