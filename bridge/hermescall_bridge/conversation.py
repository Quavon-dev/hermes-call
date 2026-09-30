"""Turn-taking: VAD endpointing (or push-to-talk) → STT → Hermes → TTS, with barge-in.

Logs carry timings only — never audio or text.
"""

import asyncio
import contextlib
import logging
import secrets
import time
from collections import deque
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass

import httpx
import numpy as np

from .audio import SpeechTrack
from .hermes import ApprovalRequest, HermesClient, TextDelta, ToolProgress
from .metrics import METRICS
from .tasks import TOOL_NAME, Progress
from .text import Chunker
from .tts import SAMPLE_RATE as TTS_RATE
from .tts import KokoroTts
from .vad import CHUNK, SAMPLE_RATE, StreamingVad

log = logging.getLogger(__name__)

CHUNK_MS = CHUNK * 1000 // SAMPLE_RATE
MAX_BUFFERED_SPEECH_S = 10.0
# "Look at this": images wait for the owner's next utterance; only the newest few are kept.
MAX_PENDING_IMAGES = 3

PHONE_SYSTEM = (
    "You are on a live phone call with your owner through Hermes Call. Everything you write is spoken "
    "aloud by a text-to-speech voice. Talk naturally in short, plain sentences. Never use markdown, lists, "
    "tables, code blocks, emojis or URLs. Keep answers brief unless asked for detail. Before a slow tool "
    "call, say in a few words what you are about to do. Commands that need approval are approved on the "
    "owner's phone screen, never by voice; do not ask for spoken approval."
)
APPROVAL_PROMPT = "I need your approval on your phone screen before I run that."
APPROVAL_DENIED = "Understood, I will not run it."
FALLBACK_LINE = "Sorry, I couldn't reach {agent} just now."
# Hermes (API server) or Kokoro failing mid-turn: the owner hears a short line or tone, never silence.
HERMES_ERRORS = (httpx.HTTPError, TimeoutError, OSError, ValueError)
TTS_ERRORS = (httpx.HTTPError, TimeoutError, OSError)
# When even TTS is down: two short tones instead of silence (24 kHz, 16-bit mono).
_TONE_RATE = 24_000


def fallback_tone() -> bytes:
    t = np.arange(int(_TONE_RATE * 0.15)) / _TONE_RATE
    beep = (np.sin(2 * np.pi * 660 * t) * 6000).astype(np.int16)
    gap = np.zeros(int(_TONE_RATE * 0.12), dtype=np.int16)
    return np.concatenate([beep, gap, beep]).tobytes()


def describe(exc: BaseException) -> str:
    """For logs: the error class and, for HTTP errors, the status (never URLs or bodies)."""
    if isinstance(exc, httpx.HTTPStatusError):
        return f"HTTP {exc.response.status_code}"
    return exc.__class__.__name__


@dataclass(frozen=True)
class TurnSettings:
    threshold: float = 0.5
    start_ms: int = 96
    min_speech_ms: int = 200
    end_silence_ms: int = 550
    barge_in_ms: int = 250
    preroll_ms: int = 320
    max_utterance_ms: int = 30_000


ApprovalHandler = Callable[[ApprovalRequest], Awaitable[str]]
# (role, text) with role "agent" or "owner"; best-effort, must not block.
CaptionHandler = Callable[[str, str], None]
# Tool progress of the agent's turns (tasks ring / Live Activity); must not block.
ProgressHandler = Callable[[Progress], None]


class _TurnProgress:
    """Maps the stream's tool events of one turn onto the bridge's task progress (turn id, tool index)."""

    def __init__(self, report: ProgressHandler | None) -> None:
        self._report = report
        self.turn_id = f"call-{secrets.token_hex(6)}"
        self._indexes: dict[str, int] = {}

    def tool(self, event: ToolProgress) -> None:
        if not TOOL_NAME.fullmatch(event.tool):
            return
        if event.status == "running" and event.call_id not in self._indexes:
            self._indexes[event.call_id] = len(self._indexes)
            preview = event.label[:200] or None
            self._send(Progress(self.turn_id, event.tool, self._indexes[event.call_id], "started", preview=preview))
        elif event.status == "completed" and event.call_id in self._indexes:
            self._send(Progress(self.turn_id, event.tool, self._indexes[event.call_id], "finished"))

    def end(self, state: str) -> None:
        if self._indexes:
            self._send(Progress(self.turn_id, "", 0, state))

    def _send(self, progress: Progress) -> None:
        if self._report is None:
            return
        try:
            self._report(progress)
        except Exception:
            log.warning("task progress failed", exc_info=True)


class Conversation:
    def __init__(
        self,
        hermes: HermesClient,
        tts: KokoroTts,
        transcribe: Callable[[np.ndarray], Awaitable[str]],
        out: SpeechTrack,
        on_approval: ApprovalHandler,
        system_note: str = "",
        settings: TurnSettings | None = None,
        agent_name: str = "Hermes",
        on_caption: CaptionHandler | None = None,
        on_progress: ProgressHandler | None = None,
    ) -> None:
        self._hermes = hermes
        self._tts = tts
        self._transcribe = transcribe
        self._out = out
        self._on_approval = on_approval
        self._system = PHONE_SYSTEM + (f"\n\n{system_note}" if system_note else "")
        self._s = settings or TurnSettings()
        self._vad = StreamingVad()
        self._turn: asyncio.Task | None = None
        self._speaker: asyncio.Task | None = None
        self._interrupted = False
        self._ptt_mode = False
        self._ptt_down = False
        self._ptt_audio: list[np.ndarray] = []
        self._device_stt = False
        self._agent_name = agent_name
        self._on_caption = on_caption
        self._on_progress = on_progress
        self._images: deque[bytes] = deque(maxlen=MAX_PENDING_IMAGES)
        # Agent captions wait until their audio reaches the front of the output buffer.
        self._pending_captions: set[asyncio.Handle] = set()
        # What was said, kept in memory only, so the chat can continue where the call ended.
        self.transcript: list[tuple[str, str]] = []
        self._reset_utterance()

    @property
    def busy(self) -> bool:
        return (self._turn is not None and not self._turn.done()) or self._out.speaking

    async def run(self, inbound: AsyncIterator[np.ndarray], first_message: str = "") -> None:
        if first_message:
            self.transcript.append((self._agent_name, first_message))
            self._turn = asyncio.ensure_future(self._speak_all([first_message]))
        pending = np.zeros(0, dtype=np.float32)
        try:
            async for block in inbound:
                pending = np.concatenate([pending, block])
                while len(pending) >= CHUNK:
                    chunk, pending = pending[:CHUNK], pending[CHUNK:]
                    self._on_chunk(chunk)
        finally:
            await self.stop()

    async def stop(self) -> None:
        self._cancel_captions()
        if self._turn is not None:
            self._turn.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._turn

    def use_device_stt(self) -> None:
        """The phone transcribes on-device and sends text; audio is used only for barge-in."""
        self._device_stt = True

    def submit_text(self, text: str, stt_ms: int | None = None) -> None:
        if not self._device_stt:
            return
        if self._turn is not None:
            self._turn.cancel()
        self._turn = asyncio.ensure_future(self._run_turn(None, time.monotonic(), text, stt_ms))

    def add_image(self, jpeg: bytes) -> None:
        """A photo the owner showed during the call; it goes to Hermes with the next utterance."""
        self._images.append(jpeg)

    def _forget_images(self, sent: list[bytes]) -> None:
        for image in sent:
            with contextlib.suppress(ValueError):
                self._images.remove(image)

    def interrupt(self) -> None:
        """The owner cut the agent off (tap on the phone): stop speaking, go back to listening."""
        if self.busy:
            self._interrupt()

    def set_ptt(self, down: bool) -> None:
        self._ptt_mode = True
        if down and not self._ptt_down:
            self._interrupt()
            self._ptt_audio = []
        elif not down and self._ptt_down and self._ptt_audio and not self._device_stt:
            self._submit(np.concatenate(self._ptt_audio))
        self._ptt_down = down

    def _reset_utterance(self) -> None:
        self._preroll: deque[np.ndarray] = deque(maxlen=max(1, self._s.preroll_ms // CHUNK_MS))
        self._utterance: list[np.ndarray] | None = None
        self._speech_run = 0
        self._voiced = 0
        self._silence = 0
        self._barged = False

    def _on_chunk(self, chunk: np.ndarray) -> None:
        if self._ptt_mode:
            if self._ptt_down:
                self._ptt_audio.append(chunk)
                if len(self._ptt_audio) * CHUNK_MS >= self._s.max_utterance_ms:
                    self._submit(np.concatenate(self._ptt_audio))
                    self._ptt_audio = []
            return
        speech = self._vad.probability(chunk) >= self._s.threshold
        if self._utterance is None:
            self._preroll.append(chunk)
            self._speech_run = self._speech_run + CHUNK_MS if speech else 0
            if self._speech_run >= self._s.start_ms:
                self._utterance = list(self._preroll)
                self._voiced = self._speech_run
            return
        self._utterance.append(chunk)
        if speech:
            self._voiced += CHUNK_MS
            self._silence = 0
        else:
            self._silence += CHUNK_MS
        if not self._barged and self.busy and self._voiced >= self._s.barge_in_ms:
            self._interrupt()
            self._barged = True
        duration = len(self._utterance) * CHUNK_MS
        if self._silence >= self._s.end_silence_ms or duration >= self._s.max_utterance_ms:
            audio, voiced, barged = np.concatenate(self._utterance), self._voiced, self._barged
            self._reset_utterance()
            if voiced >= self._s.min_speech_ms and (barged or not self.busy) and not self._device_stt:
                self._submit(audio)

    def _interrupt(self) -> None:
        if self.busy:
            self._interrupted = True
            log.info("barge-in")
        # Cancel the speaker directly too, so not one more TTS block is queued after the clear.
        for task in (self._turn, self._speaker):
            if task is not None:
                task.cancel()
        self._cancel_captions()
        self._out.clear()

    def _caption(self, role: str, text: str) -> None:
        if self._on_caption is None:
            return
        try:
            self._on_caption(role, text)
        except Exception:
            log.warning("caption failed", exc_info=True)

    def _caption_when_heard(self, text: str) -> None:
        """Caption an agent sentence when the audio queued ahead of it has played out."""
        if self._on_caption is None:
            return
        loop = asyncio.get_running_loop()
        delay = self._out.buffered_seconds

        def fire() -> None:
            self._pending_captions.discard(handle)
            self._caption("agent", text)

        handle = loop.call_later(delay, fire) if delay > 0 else loop.call_soon(fire)
        self._pending_captions.add(handle)

    def _cancel_captions(self) -> None:
        for handle in self._pending_captions:
            handle.cancel()
        self._pending_captions.clear()

    def _submit(self, audio: np.ndarray) -> None:
        if self._turn is not None:
            self._turn.cancel()
        self._turn = asyncio.ensure_future(self._run_turn(audio, time.monotonic()))

    async def _run_turn(self, audio: np.ndarray | None, ended: float, text: str = "", stt_ms: int | None = None) -> None:
        if audio is not None:
            text = await self._transcribe(audio)
        stt_done = time.monotonic()
        if not text:
            return
        if audio is not None:
            self._caption("owner", text)
        if self._interrupted:
            text = f"(I interrupted you.) {text}"
            self._interrupted = False
        chunks: asyncio.Queue[str | None] = asyncio.Queue()
        speaker = self._speaker = asyncio.ensure_future(self._speak_queue(chunks, ended))
        marks = {"stt": stt_done}
        self.transcript.append(("owner", text))
        try:
            try:
                await self._stream_reply(text, chunks, marks)
            except HERMES_ERRORS as exc:
                log.warning("turn failed: Hermes %s after %.0f ms", describe(exc), (time.monotonic() - stt_done) * 1000)
                METRICS.turn_errors.inc("hermes")
                await chunks.put(FALLBACK_LINE.format(agent=self._agent_name))
            await chunks.put(None)
            await speaker
        finally:
            speaker.cancel()
        log.info(
            "turn timings: stt %.0f ms (%s), llm first text %.0f ms, first chunk %.0f ms",
            (stt_done - ended) * 1000 if audio is not None else (stt_ms or 0),
            "bridge" if audio is not None else "phone",
            (marks.get("delta", stt_done) - stt_done) * 1000,
            (marks.get("chunk", stt_done) - stt_done) * 1000,
        )

    async def _stream_reply(self, text: str, chunks: asyncio.Queue, marks: dict[str, float]) -> None:
        chunker = Chunker()
        spoken: list[str] = []
        progress = _TurnProgress(self._on_progress)
        state = "failed"
        try:
            await self._stream_events(text, chunks, marks, chunker, spoken, progress)
            state = "done"
        except asyncio.CancelledError:
            state = "done"  # barge-in or hang-up ends the turn; it did not fail
            raise
        finally:
            progress.end(state)
            if reply := "".join(spoken).strip():
                self.transcript.append((self._agent_name, reply))

    async def _stream_events(
        self,
        text: str,
        chunks: asyncio.Queue,
        marks: dict[str, float],
        chunker: Chunker,
        spoken: list[str],
        progress: _TurnProgress,
    ) -> None:
        images = list(self._images)
        turn = self._hermes.turn(self._system, text, images=images) if images else self._hermes.turn(self._system, text)
        async with contextlib.aclosing(turn) as events:
            async for event in events:
                if images:  # Hermes answered, so it has them; until then they wait for a retry
                    self._forget_images(images)
                    images = []
                if isinstance(event, ToolProgress):
                    progress.tool(event)
                    continue
                if isinstance(event, TextDelta):
                    spoken.append(event.text)
                    marks.setdefault("delta", time.monotonic())
                    for chunk in chunker.feed(event.text):
                        marks.setdefault("chunk", time.monotonic())
                        await chunks.put(chunk)
                    continue
                await chunks.put(APPROVAL_PROMPT)
                choice = await self._on_approval(event)
                await self._hermes.answer_approval(event, choice)
                if choice == "deny":
                    await chunks.put(APPROVAL_DENIED)
        self._forget_images(images)
        for chunk in chunker.flush():
            await chunks.put(chunk)

    async def _speak_queue(self, chunks: asyncio.Queue, ended: float | None = None) -> None:
        tts_failed = False
        while (chunk := await chunks.get()) is not None:
            if tts_failed:
                continue  # Kokoro is down: the tone played once; the rest of the turn is dropped
            try:
                async with contextlib.aclosing(self._tts.synthesize(chunk)) as audio:
                    await self._play(audio, ended, chunk)
            except TTS_ERRORS as exc:
                log.warning("speech synthesis failed: %s; playing a tone instead", describe(exc))
                METRICS.turn_errors.inc("tts")
                tts_failed = True
                self._out.enqueue_pcm(fallback_tone(), _TONE_RATE)
            ended = None
        await self._out.drained.wait()

    async def _play(self, audio: AsyncIterator[bytes], ended: float | None, caption: str = "") -> None:
        async for pcm in audio:
            if ended is not None:
                latency = time.monotonic() - ended
                log.info("latency: end of speech → first audio %.0f ms", latency * 1000)
                METRICS.call_latency.observe(latency)
                ended = None
            if caption:
                self._caption_when_heard(caption)
                caption = ""
            self._out.enqueue_pcm(pcm, TTS_RATE)
            excess = self._out.buffered_seconds - MAX_BUFFERED_SPEECH_S
            if excess > 0:
                await asyncio.sleep(excess)

    async def _speak_all(self, texts: list[str]) -> None:
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        for text in texts:
            chunker = Chunker()
            for chunk in chunker.feed(text) + chunker.flush():
                await queue.put(chunk)
        await queue.put(None)
        await self._speak_queue(queue)
