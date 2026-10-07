# SPDX-License-Identifier: MIT
"""`hermes-call-bridge voice-bench`: measures the call voice on this host with fixed sample sentences.

Speech synthesis (first audio, total time, real-time factor, speaking rate) per voice and speed, then
recognition of that synthesized speech per beam size (latency and word errors: a round trip that also
shows pronunciation problems), and optionally Hermes' time to first text. No owner audio is involved.
"""

import asyncio
import contextlib
import re
import statistics
import time
from collections.abc import Callable
from pathlib import Path

import av
import httpx
import numpy as np

from .config import Config
from .hermes import HermesClient, TextDelta
from .tts import SAMPLE_RATE

SENTENCES = {
    "de": [
        "Hallo, wie kann ich dir helfen?",
        "Ich habe deinen Kalender überprüft.",
        "Morgen hast du um halb vier einen Termin.",
        "Einen Moment, ich schaue nach.",
        "Soll ich dich später daran erinnern?",
        "Schalte bitte das Licht im Wohnzimmer aus.",
        "Erinnere mich morgen um halb sieben daran.",
        "Ich möchte wissen, ob die Haustür geschlossen ist.",
        "Kannst du bitte schauen, was morgen in meinem Kalender steht?",
        "Stell die Heizung im Bad auf einundzwanzig Grad.",
    ],
    "en": [
        "Hello, how can I help you?",
        "I checked your calendar.",
        "You have an appointment at half past three tomorrow.",
        "One moment, let me look.",
        "Should I remind you later?",
        "Please turn off the living room lights.",
        "Remind me tomorrow at half past six.",
        "Is the front door locked?",
        "Can you check what is on my calendar tomorrow?",
        "Set the bathroom heating to twenty one degrees.",
    ],
}
QUESTIONS = {
    "de": "Antworte in einem kurzen Satz: Wie spät ist es ungefähr?",
    "en": "Answer in one short sentence: roughly what time is it?",
}


def _words(text: str) -> list[str]:
    return re.sub(r"[^\w\s]", " ", text.lower()).split()


def word_errors(reference: str, hypothesis: str) -> tuple[int, int]:
    ref, hyp = _words(reference), _words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        previous, row[0] = row[0], i
        for j, other in enumerate(hyp, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (word != other))
    return row[len(hyp)], len(ref)


def summary(values: list[float]) -> str:
    ordered = sorted(values)
    p95 = ordered[min(len(ordered) - 1, round(0.95 * (len(ordered) - 1)))]
    return f"median {statistics.median(ordered) * 1000:5.0f} ms  p95 {p95 * 1000:5.0f} ms"


async def synthesize(client: httpx.AsyncClient, text: str, voice: str, speed: float) -> tuple[float, float, bytes]:
    body = {"model": "kokoro", "input": text, "voice": voice, "response_format": "pcm", "stream": True, "speed": speed}
    started, first, pcm = time.monotonic(), None, bytearray()
    async with client.stream("POST", "/v1/audio/speech", json=body) as response:
        response.raise_for_status()
        async for chunk in response.aiter_bytes():
            first = first or time.monotonic() - started
            pcm += chunk
    return first or 0.0, time.monotonic() - started, bytes(pcm)


def to_16k(pcm: bytes) -> np.ndarray:
    frame = av.AudioFrame.from_ndarray(np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").reshape(1, -1), layout="mono")
    frame.sample_rate = SAMPLE_RATE
    resampler = av.AudioResampler(format="s16", layout="mono", rate=16_000)
    out = [f.to_ndarray().reshape(-1) for f in [*resampler.resample(frame), *resampler.resample(None)]]
    audio = np.concatenate(out).astype(np.float32) / 32768 if out else np.zeros(0, dtype=np.float32)
    quiet = np.zeros(8000, dtype=np.float32)
    return np.concatenate([quiet, audio, quiet])


async def run(config: Config, voices: list[str], speeds: list[float], beams: list[int], hermes_turns: int, out: Callable) -> int:
    sentences = SENTENCES.get(config.language, SENTENCES["en"])
    spoken: dict[str, bytes] = {}
    async with httpx.AsyncClient(base_url=config.tts_url, timeout=60, trust_env=False) as client:
        for voice in voices:
            for speed in speeds:
                firsts, totals, seconds, chars = [], [], 0.0, 0
                for text in sentences:
                    first, total, pcm = await synthesize(client, text, voice, speed)
                    firsts.append(first)
                    totals.append(total)
                    seconds += len(pcm) / 2 / SAMPLE_RATE
                    chars += len(text)
                    if speed == speeds[0] and voice == voices[0]:
                        spoken[text] = pcm
                rtf = sum(totals) / seconds if seconds else 0.0
                out(
                    f"tts {voice} speed {speed:.2f}: first audio {summary(firsts)}, complete {summary(totals)}, "
                    f"real-time factor {rtf:.2f}, {chars / seconds if seconds else 0:.1f} characters/s"
                )
    if beams:
        from faster_whisper import WhisperModel

        model = WhisperModel(
            str(Path(config.stt_model_dir) / config.stt_model), device="cpu", compute_type="int8", cpu_threads=config.stt_threads
        )
        audio = {text: to_16k(pcm) for text, pcm in spoken.items()}
        for beam in beams:
            latencies, errors, words = [], 0, 0
            for text, samples in audio.items():
                started = time.monotonic()
                segments, _ = model.transcribe(
                    samples,
                    language=config.language,
                    beam_size=beam,
                    temperature=0.0,
                    vad_filter=False,
                    condition_on_previous_text=False,
                    without_timestamps=True,
                    initial_prompt=config.stt_initial_prompt or None,
                )
                heard = " ".join(segment.text.strip() for segment in segments)
                latencies.append(time.monotonic() - started)
                wrong, total = word_errors(text, heard)
                errors, words = errors + wrong, words + total
                if wrong:
                    out(f"  beam {beam}: '{text}' heard as '{heard}'")
            out(f"stt {config.stt_model} beam {beam}: {summary(latencies)}, word errors {100 * errors / max(words, 1):.1f} %")
    if hermes_turns:
        hermes = HermesClient(
            config.hermes_url,
            config.secret("hermes_api_key"),
            "hermes-call-bench",
            config.hermes_model,
            config.hermes_provider,
            config.hermes_reasoning_effort,
        )
        firsts = []
        try:
            for _ in range(hermes_turns):
                started = time.monotonic()
                question = QUESTIONS.get(config.language, QUESTIONS["en"])
                async with contextlib.aclosing(hermes.turn("You are on a phone call. Answer briefly.", question)) as events:
                    async for event in events:
                        if isinstance(event, TextDelta):
                            firsts.append(time.monotonic() - started)
                            break
        finally:
            await hermes.close()
        out(f"hermes {config.hermes_model}: first text {summary(firsts)}" if firsts else "hermes: no text")
    return 0


def voice_bench(config: Config, voices: list[str], speeds: list[float], beams: list[int], hermes_turns: int, out=print) -> int:
    return asyncio.run(run(config, voices or [config.tts_voice], speeds or [config.tts_speed], beams, hermes_turns, out))
