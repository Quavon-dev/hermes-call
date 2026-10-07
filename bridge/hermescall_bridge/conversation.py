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
from .lang import Phrases, phrases
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
    "You are on a live phone call with your owner through Hermes Call. Everything you write is spoken aloud "
    "by a text-to-speech voice, so write only plain spoken sentences: no markdown, lists, tables, code, emojis, "
    "URLs or symbols that cannot be read aloud. Answer in the language the owner speaks. {language}"
    "Start with a short, useful sentence that answers or says what you are doing, then add detail only when "
    "it helps; sound natural and conversational, not clipped. Say numbers, times and dates the way people "
    "speak them. Do not introduce yourself, do not mention being an AI and skip filler phrases. Before a "
    "tool call, do not announce it at length; Hermes Call plays a short progress line while tools run. "
    "Commands that need approval are approved on the owner's phone screen, never by voice; do not ask for "
    "spoken approval."
)
APPROVAL_PROMPT = phrases("en").approval_prompt
APPROVAL_DENIED = phrases("en").approval_denied
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
    # Recognition starts this far into the closing silence and is kept if the owner stays quiet;
    # only this much of the silence goes to Whisper.
    speculate_ms: int = 250
    barge_in_ms: int = 250
    preroll_ms: int = 320
    max_utterance_ms: int = 30_000
    acknowledgement_after_ms: int = 0
    acknowledgement_text: str = ""
    barge_in: bool = True
    # barge_in = false: the agent's voice keeps reaching the microphone this long after the bridge
    # sent its last audio (the phone's jitter buffer, the network both ways, the room).
    echo_tail_ms: int = 400
    language: str = "en"


@dataclass
class _Said:
    """What the owner said for one turn, until the agent's answer starts to play."""

    audio: np.ndarray | None
    prefix: str = ""
    text: str = ""
    answered: bool = False
    # A tool started: the request is being acted on, so more speech is a new turn, not its rest.
    acting: bool = False
    interrupted: bool = False
    # The owner line this turn put into the transcript (replaced when the turn is continued).
    sent: str = ""
    acknowledged: bool = False
    audio_at: float | None = None

    @property
    def full(self) -> str:
        return f"{self.prefix} {self.text}".strip()

    @property
    def open(self) -> bool:
        return not self.answered and not self.acting


ApprovalHandler = Callable[[ApprovalRequest], Awaitable[str]]
# (role, text) with role "agent" or "owner"; best-effort, must not block.
CaptionHandler = Callable[[str, str], None]
# Device STT: how long the phone's transcript may take after the bridge heard the utterance end.
CARRY_WAIT_S = 2.0
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
        session_id: str | None = None,
        on_turn: Callable[[], None] | None = None,
    ) -> None:
        """`session_id`: the Hermes session for this call (per phone); `on_turn` counts turns for its rollover."""
        self._session_id = session_id
        self._on_turn = on_turn
        self._announcer: asyncio.Task | None = None
        self._hermes = hermes
        self._tts = tts
        self._transcribe = transcribe
        self._out = out
        self._on_approval = on_approval
        self._s = settings or TurnSettings()
        self._phrases = phrases(self._s.language)
        language = "" if self._s.language == "en" else f"This call is in {self._phrases.name}. "
        self._system = PHONE_SYSTEM.format(language=language) + (f"\n\n{system_note}" if system_note else "")
        self._vad = StreamingVad()
        self._turn: asyncio.Task | None = None
        self._speaker: asyncio.Task | None = None
        self._interrupted = False
        # The owner went on talking before the answer played: their words so far, joined to the next.
        self._said: _Said | None = None
        self._carry: _Said | None = None
        self._carry_wait: asyncio.TimerHandle | None = None
        self._ptt_mode = False
        self._ptt_down = False
        self._audible_until = 0.0
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
    def phrases(self) -> Phrases:
        return self._phrases

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
                    probability = None if self._ptt_mode else await self._vad.probability_async(chunk)
                    self._on_chunk(chunk, probability)
        finally:
            await self.stop()

    async def stop(self) -> None:
        self._drop_speculation()
        self._cancel_carry_wait()
        self._cancel_captions()
        if self._announcer is not None:
            self._announcer.cancel()
        if self._turn is not None:
            self._turn.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._turn

    def use_device_stt(self) -> None:
        """The phone transcribes on-device and sends text; audio is used only for barge-in."""
        self._device_stt = True
        self._drop_speculation()

    def submit_text(self, text: str, stt_ms: int | None = None) -> None:
        if not self._device_stt:
            return
        if not self._ptt_mode and self._hears_playback():
            log.info("phone transcript ignored: the agent was speaking (barge_in = false)")
            return
        if self._turn is not None:
            self._turn.cancel()
        self._cancel_carry_wait()
        carry, self._carry = self._carry, None
        self._turn = asyncio.ensure_future(self._run_turn(None, time.monotonic(), text, stt_ms, carry=carry))

    def _cancel_carry_wait(self) -> None:
        if self._carry_wait is not None:
            self._carry_wait.cancel()
            self._carry_wait = None

    def _await_phone_transcript(self) -> None:
        """Device STT: the owner's going-on was noise the phone does not transcribe. Their question
        must not be lost, so it is asked again on its own if no transcript follows."""
        self._cancel_carry_wait()
        self._carry_wait = asyncio.get_running_loop().call_later(CARRY_WAIT_S, self._resubmit_carry)

    def _resubmit_carry(self) -> None:
        self._carry_wait = None
        carry, self._carry = self._carry, None
        if carry is not None and carry.full and (self._turn is None or self._turn.done()):
            self._turn = asyncio.ensure_future(self._run_turn(None, time.monotonic(), "", carry=carry))

    def announce(self, text: str, wait: float = 30.0) -> None:
        """Say something on the bridge's own account (e.g. the call's time limit) once the agent is quiet."""
        self._announcer = asyncio.ensure_future(self._announce(text, wait))

    async def _announce(self, text: str, wait: float) -> None:
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._quiet(), wait)
        if not self.busy:
            self.transcript.append((self._agent_name, text))
            self._turn = asyncio.ensure_future(self._speak_all([text]))

    async def _quiet(self) -> None:
        while self.busy:
            if self._turn is not None and not self._turn.done():
                await asyncio.wait({self._turn})
            await self._out.drained.wait()

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
        self._drop_speculation()
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
        self._speculation: asyncio.Task | None = None
        # One early guess per utterance: a guess already running on the single Whisper worker
        # finishes even when cancelled, and the final recognition would wait behind each one.
        self._guessed = False

    def _drop_speculation(self) -> None:
        if self._speculation is not None:
            self._speculation.cancel()
            self._speculation = None

    def _trimmed(self) -> np.ndarray:
        """The utterance without the closing silence beyond `speculate_ms` (same audio either way)."""
        assert self._utterance is not None
        extra = max(0, self._silence - min(self._s.speculate_ms, self._s.end_silence_ms)) // CHUNK_MS
        return np.concatenate(self._utterance[: len(self._utterance) - extra])

    def _on_chunk(self, chunk: np.ndarray, probability: float | None = None) -> None:
        """`probability`: the VAD result computed off the event loop (None: compute it here)."""
        if self._ptt_mode:
            if self._ptt_down:
                self._ptt_audio.append(chunk)
                if len(self._ptt_audio) * CHUNK_MS >= self._s.max_utterance_ms:
                    self._submit(np.concatenate(self._ptt_audio))
                    self._ptt_audio = []
            return
        if probability is None:
            probability = self._vad.probability(chunk)
        if self._hears_playback():
            METRICS.playback_ignored_seconds.inc(amount=CHUNK_MS / 1000)
            if self._utterance is not None or self._speech_run or self._preroll:
                self._drop_speculation()
                self._reset_utterance()
            return
        speech = probability >= self._s.threshold
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
            self._drop_speculation()
        else:
            self._silence += CHUNK_MS
        if not self._barged and self.busy and self._voiced >= self._s.barge_in_ms:
            self._interrupt(continuing=True)
            self._barged = True
        duration = len(self._utterance) * CHUNK_MS
        wanted = self._voiced >= self._s.min_speech_ms and (self._barged or not self.busy) and not self._device_stt
        if self._silence >= self._s.end_silence_ms or duration >= self._s.max_utterance_ms:
            audio, guess = self._trimmed(), self._speculation
            self._speculation = None
            self._reset_utterance()
            if wanted:
                self._submit(audio, guess)
            else:
                if guess is not None:
                    guess.cancel()
                if self._device_stt and self._carry is not None:
                    self._await_phone_transcript()
        elif wanted and not self._guessed and self._silence >= self._s.speculate_ms:
            self._guessed = True
            self._speculation = asyncio.ensure_future(self._transcribe(self._trimmed()))

    def _hears_playback(self) -> bool:
        """barge_in = false: the microphone may be hearing the agent (speakerphone echo), so it makes no turn."""
        if self._s.barge_in:
            return False
        now = time.monotonic()
        if self._out.speaking:
            self._audible_until = now + self._s.echo_tail_ms / 1000
            return True
        return now < self._audible_until

    def _interrupt(self, continuing: bool = False) -> None:
        """`continuing`: the owner started speaking (not a tap); before any answer played, that is
        the rest of what they were saying, so it is joined to it instead of cutting the agent off."""
        said = self._said
        running = self._turn is not None and not self._turn.done()
        if continuing and running and said is not None and said.open:
            self._carry = said
            log.info("owner kept talking")
        elif self.busy:
            self._interrupted = True
            METRICS.barge_ins.inc()
            log.info("barge-in")
        self._audible_until = 0.0
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

    def _submit(self, audio: np.ndarray, guess: asyncio.Task | None = None) -> None:
        """`guess`: recognition of this same audio, started early in the closing silence."""
        if self._turn is not None:
            self._turn.cancel()
        carry, self._carry = self._carry, None
        if carry is not None and not carry.text and carry.audio is not None:  # not recognized yet: both as one
            audio = np.concatenate([carry.audio, audio])
            if guess is not None:
                guess.cancel()
                guess = None
        METRICS.utterance_seconds.observe(len(audio) / SAMPLE_RATE)
        self._turn = asyncio.ensure_future(self._run_turn(audio, time.monotonic(), guess=guess, carry=carry))

    async def _run_turn(
        self,
        audio: np.ndarray | None,
        ended: float,
        text: str = "",
        stt_ms: int | None = None,
        guess: asyncio.Task | None = None,
        carry: "_Said | None" = None,
    ) -> None:
        """`carry`: the turn the owner went on from; its words come first (`audio` already holds its
        audio when it had not been recognized yet)."""
        recognized_before = carry is not None and bool(carry.text)
        prefix = carry.full if recognized_before else (carry.prefix if carry is not None else "")
        said = self._said = _Said(
            audio,
            prefix,
            interrupted=carry is not None and carry.interrupted,
            acknowledged=carry is not None and carry.acknowledged,
        )
        try:
            await self._answer(said, audio, ended, text, stt_ms, guess, carry)
        finally:
            if self._said is said:
                self._said = None

    async def _answer(
        self,
        said: _Said,
        audio: np.ndarray | None,
        ended: float,
        text: str,
        stt_ms: int | None,
        guess: asyncio.Task | None,
        carry: "_Said | None",
    ) -> None:
        if audio is not None:
            text = await (guess if guess is not None else self._transcribe(audio))
        stt_done = time.monotonic()
        said.text = text
        if not said.full:
            return
        if audio is not None and text:
            self._caption("owner", text)
        if carry is not None and carry.sent and self.transcript and self.transcript[-1] == ("owner", carry.sent):
            self.transcript.pop()
        text = said.full
        if self._interrupted:
            said.interrupted = True
            self._interrupted = False
        if said.interrupted:
            text = f"(I interrupted you.) {text}"
        chunks: asyncio.Queue[str | None] = asyncio.Queue()
        speaker = self._speaker = asyncio.ensure_future(self._speak_queue(chunks, ended, said))
        marks = {"stt": stt_done}
        acknowledgement = None
        if self._s.acknowledgement_after_ms and self._s.acknowledgement_text:
            acknowledgement = asyncio.ensure_future(self._acknowledge(chunks, marks, said, ended))
        self.transcript.append(("owner", text))
        said.sent = text
        try:
            try:
                await self._stream_reply(text, chunks, marks, said)
            except HERMES_ERRORS as exc:
                log.warning("turn failed: Hermes %s after %.0f ms", describe(exc), (time.monotonic() - stt_done) * 1000)
                METRICS.turn_errors.inc("hermes")
                marks.setdefault("chunk", time.monotonic())
                await chunks.put(self._phrases.fallback.format(agent=self._agent_name))
            await chunks.put(None)
            await speaker
        finally:
            if acknowledgement is not None:
                acknowledgement.cancel()
            speaker.cancel()
        log.info(
            "turn timings: utterance %.1f s, stt %.0f ms (%s), llm first text %.0f ms, first chunk %.0f ms, "
            "end of speech to first answer audio %s, acknowledgement %s",
            len(audio) / SAMPLE_RATE if audio is not None else 0.0,
            (stt_done - ended) * 1000 if audio is not None else (stt_ms or 0),
            "bridge" if audio is not None else "phone",
            (marks.get("delta", stt_done) - stt_done) * 1000,
            (marks.get("chunk", stt_done) - stt_done) * 1000,
            f"{(said.audio_at - ended) * 1000:.0f} ms" if said.audio_at is not None else "none",
            f"{(marks['acknowledgement'] - ended) * 1000:.0f} ms" if "acknowledgement" in marks else "none",
        )

    async def _acknowledge(self, chunks: asyncio.Queue, marks: dict[str, float], said: _Said, ended: float) -> None:
        """No answer this long after the owner stopped speaking: say the acknowledgement once."""
        await asyncio.sleep(max(0.0, ended + self._s.acknowledgement_after_ms / 1000 - time.monotonic()))
        await self._queue_acknowledgement(chunks, marks, said)

    async def _queue_acknowledgement(self, chunks: asyncio.Queue, marks: dict[str, float], said: _Said) -> None:
        if "chunk" in marks or said.acknowledged or not self._s.acknowledgement_after_ms or not self._s.acknowledgement_text:
            return
        said.acknowledged = True
        marks["acknowledgement"] = time.monotonic()
        await chunks.put(self._s.acknowledgement_text)

    async def _stream_reply(self, text: str, chunks: asyncio.Queue, marks: dict[str, float], said: _Said) -> None:
        chunker = Chunker(self._phrases.link)
        spoken: list[str] = []
        progress = _TurnProgress(self._on_progress)
        state = "failed"
        try:
            await self._stream_events(text, chunks, marks, chunker, spoken, progress, said)
            state = "done"
        except asyncio.CancelledError:
            state = "done"  # barge-in or hang-up ends the turn; it did not fail
            raise
        finally:
            progress.end(state)
            # A reply cut off before any of it played was never heard: the transcript leaves it out.
            if (reply := "".join(spoken).strip()) and said.answered:
                self.transcript.append((self._agent_name, reply))

    async def _stream_events(
        self,
        text: str,
        chunks: asyncio.Queue,
        marks: dict[str, float],
        chunker: Chunker,
        spoken: list[str],
        progress: _TurnProgress,
        said: _Said,
    ) -> None:
        images = list(self._images)
        extra: dict = {"images": images} if images else {}
        if self._session_id:
            extra["session_id"] = self._session_id
        if self._on_turn is not None:
            self._on_turn()
        turn = self._hermes.turn(self._system, text, **extra)
        async with contextlib.aclosing(turn) as events:
            async for event in events:
                if images:  # Hermes answered, so it has them; until then they wait for a retry
                    self._forget_images(images)
                    images = []
                if isinstance(event, ToolProgress):
                    progress.tool(event)
                    if event.status == "running":
                        said.acting = True
                        await self._queue_acknowledgement(chunks, marks, said)
                    continue
                if isinstance(event, TextDelta):
                    spoken.append(event.text)
                    if "delta" not in marks:
                        marks["delta"] = time.monotonic()
                        METRICS.hermes_first_text.observe(marks["delta"] - marks["stt"])
                    for chunk in chunker.feed(event.text):
                        marks.setdefault("chunk", time.monotonic())
                        await chunks.put(chunk)
                    continue
                marks.setdefault("chunk", time.monotonic())
                await chunks.put(self._phrases.approval_prompt)
                choice = await self._on_approval(event)
                accepted = await self._hermes.answer_approval(event, choice)
                if choice == "deny" or accepted in ("deny", None):
                    await chunks.put(self._phrases.approval_denied)
        self._forget_images(images)
        for chunk in chunker.flush():
            await chunks.put(chunk)

    async def _speak_queue(self, chunks: asyncio.Queue, ended: float | None = None, said: _Said | None = None) -> None:
        tts_failed = False
        previous: str | None = None
        own_lines = (None, self._s.acknowledgement_text, self._phrases.approval_prompt, self._phrases.approval_denied)
        while (chunk := await chunks.get()) is not None:
            if tts_failed:
                continue  # Kokoro is down: the tone played once; the rest of the turn is dropped
            # Silence after the bridge's own lines is expected (a tool runs, the owner approves).
            watch_gap = previous not in own_lines
            acknowledgement = bool(chunk) and chunk == self._s.acknowledgement_text
            try:
                async with contextlib.aclosing(self._tts.synthesize(chunk)) as audio:
                    await self._play(audio, ended, chunk, acknowledgement, None if acknowledgement else said, watch_gap)
            except TTS_ERRORS as exc:
                log.warning("speech synthesis failed: %s; playing a tone instead", describe(exc))
                METRICS.turn_errors.inc("tts")
                tts_failed = True
                self._out.enqueue_pcm(fallback_tone(), _TONE_RATE)
            previous = chunk
            if not acknowledgement:
                ended = None  # the acknowledgement is not the answer: keep timing until the reply plays
        await self._out.drained.wait()

    async def _play(
        self,
        audio: AsyncIterator[bytes],
        ended: float | None,
        caption: str = "",
        acknowledgement: bool = False,
        answer: _Said | None = None,
        watch_gap: bool = False,
    ) -> None:
        """`answer`: the owner's turn this audio answers; it counts as heard from its first audio.
        `watch_gap`: count it when the previous sentence had already played out before this one."""
        async for pcm in audio:
            if answer is not None:
                answer.answered = True
                if answer.audio_at is None:
                    answer.audio_at = time.monotonic()
            if watch_gap:
                if not self._out.speaking:
                    METRICS.speech_gaps.inc()
                watch_gap = False
            if ended is not None:
                latency = time.monotonic() - ended
                if acknowledgement:
                    METRICS.acknowledgement_latency.observe(latency)
                else:
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
            chunker = Chunker(self._phrases.link)
            for chunk in chunker.feed(text) + chunker.flush():
                await queue.put(chunk)
        await queue.put(None)
        await self._speak_queue(queue)
