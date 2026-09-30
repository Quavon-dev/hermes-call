"""Chat between the owner's phones and the agent (Hermes platform adapter `hermes_call`).

Phones → bridge: E2E `chat` messages (mailbox envelope with `mid`), attachments as
encrypted relay blobs. Bridge → Hermes: an event queue the plugin's adapter
long-polls on the local API. Hermes → phones: E2E messages through the relay
mailbox with an alert push. All paired phones share one chat ("owner").

Durability (chatstore.py): an owner message is written to the store before the phone gets
`delivered`, handed to Hermes from there (also after a restart), and only dropped once the
adapter's cursor passed it. Agent messages wait in a persistent outbox until the relay took them.

Logs carry ids and sizes only — never message text.
"""

import asyncio
import contextlib
import io
import logging
import sqlite3
import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import av
import numpy as np

from hermescall_common import blobs, sodium, wire
from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel
from hermescall_common.errors import CryptoError, ProtocolError

from .chatstore import AsyncStore, ChatStore, Pending
from .hermes import APPROVAL_CHOICES, MAX_APPROVAL_TEXT
from .outbox import Outbox
from .state import Device, State
from .transport import Transport
from .tts import SAMPLE_RATE as TTS_RATE
from .voice import MAX_SPOKEN_SECONDS, encode_voice, speech_text

log = logging.getLogger(__name__)

CHAT_ID = "owner"
MAX_TEXT = 12_000
MAX_ATTACHMENTS = 4
MAX_NAME = 120
MAX_EVENTS = 500
MAX_POLL_SECONDS = 30.0
MAX_VOICE_SECONDS = 300
RECENT_LINES = 16
MAX_CONTEXT_CHARS = 6000
APPROVAL_TTL = 600.0
MAX_MAIL = 48 * 1024
ATTACHMENT_KINDS = ("photo", "voice", "file")
# An owner voice note with `voice_replies: true` is answered by voice if the agent's reply to it
# (`answers`/`reply_to` = the note's id) comes within this time; TTS may take at most SPEAK_TIMEOUT.
VOICE_REPLY_TTL = 600.0
SPEAK_TIMEOUT = 20.0
_MIME_OK = frozenset("abcdefghijklmnopqrstuvwxyz0123456789+-./")


def new_id() -> str:
    return wire.b64e(sodium.random_bytes(16))


def decode_audio(data: bytes, max_seconds: int = MAX_VOICE_SECONDS) -> np.ndarray:
    """Any container PyAV can read (the app sends AAC in .m4a) → float32 mono 16 kHz."""
    resampler = av.AudioResampler(format="flt", layout="mono", rate=16_000)
    blocks: list[np.ndarray] = []
    total, limit = 0, max_seconds * 16_000
    with av.open(io.BytesIO(data)) as container:
        for frame in container.decode(audio=0):
            for out in resampler.resample(frame):
                block = out.to_ndarray().reshape(-1)
                blocks.append(block)
                total += len(block)
            if total >= limit:
                break
    audio = np.concatenate(blocks) if blocks else np.zeros(0, dtype=np.float32)
    return audio[:limit].astype(np.float32)


def _clean_name(value: object, default: str) -> str:
    text = value if isinstance(value, str) else ""
    text = "".join(ch for ch in text if ch.isprintable() and ch not in "/\\")[:MAX_NAME].strip()
    return text or default


def _clean_mime(value: object) -> str:
    return (
        value
        if isinstance(value, str) and 0 < len(value) <= 100 and set(value) <= _MIME_OK and "/" in value
        else "application/octet-stream"
    )


@dataclass(frozen=True)
class Attachment:
    kind: str
    blob_id: str
    key: bytes
    name: str
    mime: str

    @classmethod
    def parse(cls, raw: object) -> "Attachment":
        if not isinstance(raw, dict) or raw.get("kind") not in ATTACHMENT_KINDS:
            raise ProtocolError("invalid attachment")
        blob_id = raw.get("blob_id")
        wire.b64d(blob_id, length=16)
        key = wire.b64d(raw.get("key"), length=32)
        return cls(raw["kind"], blob_id, key, _clean_name(raw.get("name"), raw["kind"]), _clean_mime(raw.get("mime")))


class ChatService:
    def __init__(
        self,
        state: State,
        relay: RelaySession,
        channel: Channel,
        transcribe: Callable[[np.ndarray], Awaitable[str]],
        agent_name: str = "Hermes",
        tts: Any = None,
        store: ChatStore | None = None,
        transcribe_long: Callable[[np.ndarray], Awaitable[str]] | None = None,
    ) -> None:
        """`transcribe_long` (voice notes) runs behind live-call speech recognition (stt.py)."""
        self._state = state
        self._tts = tts
        # (owner voice-note id, monotonic deadline): the agent's reply to it is also spoken
        self._voice_note: tuple[str, float] | None = None
        self._relay = relay
        self._channel = channel
        self._transport = Transport(state, relay, channel)
        self._transcribe = transcribe_long or transcribe
        self._agent_name = agent_name
        self._db = AsyncStore(store or ChatStore(":memory:"))
        self.epoch = self._db.store.epoch
        self.outbox = Outbox(self._transport, self._db, self._delivery_failed)
        self._changed = asyncio.Condition()
        recent = self._db.store.get_json("recent", [])
        self._recent: deque[tuple[str, str]] = deque(
            (tuple(line) for line in recent if isinstance(line, list) and len(line) == 2), maxlen=RECENT_LINES
        )
        self._call_context = str(self._db.store.get_json("call_context", "") or "")
        self._approvals: dict[str, float] = {}
        self._resumed = False
        self.last_poll = 0.0

    # ---- lifecycle ---------------------------------------------------------

    async def on_relay_ready(self) -> None:
        """After every relay (re)connect: queued mail goes out; after a restart, accepted messages resume."""
        self.outbox.kick()
        if not self._resumed:
            self._resumed = True
            for pending in await self._db.call(self._db.store.pending):
                await self._resume(pending)

    async def _resume(self, pending: Pending) -> None:
        device = self._state.devices.get(pending.device_id)
        if device is None:
            await self._db.call(self._db.store.drop_pending, pending.message_id)
            return
        log.info("resuming chat message %s from before a restart", pending.message_id[:6])
        try:
            await self._process(device, pending.message_id, pending.body)
        except ProtocolError as exc:
            log.warning("chat message %s dropped: %s", pending.message_id[:6], exc)
            await self._db.call(self._db.store.drop_pending, pending.message_id)

    async def close(self) -> None:
        self.outbox.stop()
        await asyncio.get_running_loop().run_in_executor(None, self._db.close)

    async def depths(self) -> dict[str, int]:
        store = self._db.store
        return {
            "events": await self._db.call(store.event_depth),
            "inbox": await self._db.call(store.inbox_depth),
            "outbox": await self._db.call(store.outbox_depth),
        }

    # ---- phones → Hermes -----------------------------------------------

    async def handle(self, device: Device, body: dict[str, Any]) -> None:
        kind = body.get("type")
        if kind == "chat":
            await self._on_chat(device, body)
        elif kind == "approval":
            await self._on_approval(device, body)
        else:
            raise ProtocolError("unknown message type")

    async def _on_chat(self, device: Device, body: dict[str, Any]) -> None:
        if "mid" not in body:
            raise ProtocolError("chat messages need a mailbox envelope")
        message_id = body.get("id")
        wire.b64d(message_id, length=16)
        text = body.get("text", "")
        raw = body.get("attachments", [])
        if not isinstance(text, str) or len(text) > MAX_TEXT or not isinstance(raw, list) or len(raw) > MAX_ATTACHMENTS:
            raise ProtocolError("invalid chat message")
        attachments = [Attachment.parse(item) for item in raw]
        if not text.strip() and not attachments:
            raise ProtocolError("empty chat message")
        kept = {key: body[key] for key in ("id", "text", "attachments", "reply_to", "voice_replies") if key in body}
        try:
            fresh = await self._db.call(self._db.store.accept, message_id, device.id, kept)
        except sqlite3.Error as exc:
            # No ack: the phone keeps the message and sends it again.
            log.error("chat message %s not stored, not acked: %s", message_id[:6], exc)
            return
        # Phones resend unacknowledged messages (new envelope, same id): ack again, deliver once.
        await self._live(device, {"type": "chat_ack", "id": message_id, "state": "delivered"})
        if fresh:
            await self._process(device, message_id, kept)

    async def _process(self, device: Device, message_id: str, body: dict[str, Any]) -> None:
        """Stored and acked → attachments, transcripts, mirror → an event for Hermes (one transaction with the inbox row)."""
        text = body.get("text", "")
        attachments = [Attachment.parse(item) for item in body.get("attachments", [])]
        wants_voice = body.get("voice_replies") is True and any(a.kind == "voice" for a in attachments)
        self._voice_note = (message_id, time.monotonic() + VOICE_REPLY_TTL) if wants_voice else None
        files, voice, problems = await self._fetch_attachments(device, attachments)
        transcript = " ".join(voice)
        if transcript:
            await self._live(device, {"type": "chat_ack", "id": message_id, "state": "transcribed", "transcript": transcript})
        parts = (text.strip(), *(f"[Voice note] {note}" for note in voice), *problems)
        full_text = "\n".join(part for part in parts if part)
        self._remember("owner", full_text or f"[{len(files)} attachment(s)]")
        await self._mirror(device, message_id, text.strip(), attachments, transcript)
        context = self._take_call_context()
        await self._emit(
            {
                "type": "message",
                "chat_id": CHAT_ID,
                "id": message_id,
                "user_id": device.id,
                "user_name": device.name,
                "text": f"{context}{full_text}",
                "attachments": files,
                "reply_to": body.get("reply_to") if isinstance(body.get("reply_to"), str) else None,
                "ts": int(time.time() * 1000),
            },
            handed_over=message_id,
        )
        for item in attachments:
            with contextlib.suppress(ProtocolError, TimeoutError):
                await blobs.delete(self._relay, item.blob_id)
        log.info("chat message from %s: %d chars, %d attachments", device.id[:6], len(text), len(attachments))

    async def _fetch_attachments(self, device: Device, attachments: list[Attachment]) -> tuple[list[dict], list[str], list[str]]:
        """(files for Hermes, voice-note transcripts, notes about attachments that failed)"""
        files: list[dict] = []
        voice: list[str] = []
        problems: list[str] = []
        # Blobs are deleted only once the message is stored for Hermes (after a crash they are fetched again).
        for item in attachments:
            try:
                data = blobs.open_sealed(item.key, await blobs.download(self._relay, item.blob_id))
            except (ProtocolError, CryptoError, OSError, TimeoutError) as exc:
                log.warning("attachment from %s unavailable: %s", device.id[:6], exc.__class__.__name__)
                problems.append(f"(attachment '{item.name}' could not be downloaded)")
                continue
            if item.kind == "voice":
                voice.append(await self._voice_to_text(data))
            else:
                files.append({"kind": item.kind, "name": item.name, "mime": item.mime, "data": wire.b64e(data)})
        return files, voice, problems

    async def _voice_to_text(self, data: bytes) -> str:
        try:
            audio = await asyncio.get_running_loop().run_in_executor(None, decode_audio, data)
        except (av.error.FFmpegError, ValueError) as exc:
            log.warning("voice note not decodable: %s", exc.__class__.__name__)
            return "(unreadable voice note)"
        started = time.monotonic()
        text = await self._transcribe(audio) if len(audio) else ""
        log.info("voice note: %.1f s audio, stt %.0f ms", len(audio) / 16_000, (time.monotonic() - started) * 1000)
        return text or "(no speech recognized)"

    async def _on_approval(self, device: Device, body: dict[str, Any]) -> None:
        request_id = body.get("request_id")
        if not isinstance(request_id, str) or self._approvals.pop(request_id, 0.0) < time.monotonic():
            return
        choice = body.get("choice") if body.get("choice") in APPROVAL_CHOICES else "deny"
        await self._emit({"type": "approval", "chat_id": CHAT_ID, "request_id": request_id, "choice": choice})
        for other in self._state.devices.values():
            if other.id != device.id:
                await self._live(other, {"type": "approval_done", "request_id": request_id})

    async def _emit(self, event: dict[str, Any], handed_over: str | None = None) -> None:
        store = self._db.store
        if handed_over is None:
            await self._db.call(store.add_event, event)
        else:
            await self._db.call(store.hand_over, handed_over, event)
        dropped = await self._db.call(store.trim_events, MAX_EVENTS)
        if dropped:
            log.warning("chat adapter is not polling: %d old events dropped", dropped)
        async with self._changed:
            self._changed.notify_all()

    async def poll(self, cursor: int, wait: float, epoch: str | None = None) -> tuple[int, list[dict[str, Any]]]:
        """Events after `cursor`; everything up to `cursor` counts as received by Hermes.

        `epoch` names the event store the adapter's cursor belongs to. A different one (the store
        was lost, seq numbers restarted) makes the cursor meaningless: nothing is acked, all is sent."""
        self.last_poll = time.monotonic()
        store = self._db.store
        if epoch is not None and epoch != self.epoch:
            log.info("chat adapter cursor belongs to another event store; delivering from the start")
            cursor = 0
        await self._db.call(store.ack, cursor)
        async with self._changed:
            events = await self._db.call(store.events_after, cursor)
            if not events and wait > 0:
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self._changed.wait(), min(wait, MAX_POLL_SECONDS))
                events = await self._db.call(store.events_after, cursor)
        last = events[-1][0] if events else max(cursor, await self._db.call(store.last_seq))
        return last, [event for _, event in events]

    async def _delivery_failed(self, message_id: str, device_id: str, why: str) -> None:
        """The outbox gave up on a message; the adapter hears of it (Hermes cannot resend it)."""
        event = {"type": "delivery_failed", "chat_id": CHAT_ID, "message_id": message_id, "device_id": device_id}
        await self._emit({**event, "why": why[:100]})

    # ---- Hermes → phones -----------------------------------------------

    async def send_text(self, text: str, reply_to: str | None = None, kind: str = "text", answers: str | None = None) -> str:
        """`answers`: the owner message this is the (final) reply to; a voice note asking for it gets it spoken."""
        message_id = new_id()
        body = {"type": "chat", "id": message_id, "role": "agent", "kind": kind, "text": text[:MAX_TEXT]}
        if reply_to:
            body["reply_to"] = reply_to
        self._remember(self._agent_name, text)
        audio = await self._speak(text) if self._answers_voice_note(kind, answers or reply_to) else None
        if audio is None:
            await self._mail_all(body, alert=True)
        else:
            await self._send_voice_reply(body, audio)
        return message_id

    async def queued(self, message_id: str) -> bool:
        """Whether some phone's copy still waits in the outbox (the relay has not taken it yet)."""
        return await self._db.call(self._db.store.queued, message_id)

    # ---- spoken replies (the owner sent a voice note) --------------------

    def _answers_voice_note(self, kind: str, answers: str | None) -> bool:
        """Only the reply to that very voice note, once; other agent messages (cron, interim) leave it alone."""
        note = self._voice_note
        if kind != "text" or note is None or answers != note[0]:
            return False
        self._voice_note = None
        return time.monotonic() < note[1]

    async def _speak(self, text: str) -> bytes | None:
        """Kokoro → AAC/.m4a, or None (nothing to say, too slow, or failed: the text goes alone)."""
        try:
            return await asyncio.wait_for(self._synthesize(text), SPEAK_TIMEOUT)
        except TimeoutError:
            log.warning("voice reply not synthesized: TTS took longer than %.0f s", SPEAK_TIMEOUT)
            return None

    async def _synthesize(self, text: str) -> bytes | None:
        loop = asyncio.get_running_loop()
        spoken = await loop.run_in_executor(None, speech_text, text)
        if self._tts is None or not spoken:
            return None
        limit = MAX_SPOKEN_SECONDS * TTS_RATE * 2
        pcm = bytearray()
        try:
            async with contextlib.aclosing(self._tts.synthesize(spoken)) as audio:
                async for chunk in audio:
                    pcm += chunk
                    if len(pcm) >= limit:
                        break
            if not pcm:
                return None
            data = await loop.run_in_executor(None, encode_voice, bytes(pcm), TTS_RATE)
        except Exception as exc:  # the reply must still arrive as text
            log.warning("voice reply not synthesized: %s", exc.__class__.__name__)
            return None
        log.info("voice reply: %d chars spoken, %.1f s, %d bytes", len(spoken), len(pcm) / 2 / TTS_RATE, len(data))
        return data

    async def _send_voice_reply(self, body: dict[str, Any], audio: bytes) -> None:
        """One chat message: the reply text plus the voice note (text only for a phone whose upload failed)."""
        for device in list(self._state.devices.values()):
            key, sealed = blobs.seal(audio)
            try:
                blob_id = await blobs.upload(self._relay, sealed, to=device.id)
            except (ProtocolError, OSError, TimeoutError) as exc:
                log.warning("voice reply for %s not uploaded: %s", device.id[:6], exc.__class__.__name__)
                await self._mail(device, body, alert=True)
                continue
            ref = {
                "kind": "voice",
                "blob_id": blob_id,
                "key": wire.b64e(key),
                "name": "reply.m4a",
                "mime": "audio/mp4",
                "size": len(audio),
            }
            voiced = {**body, "attachments": [ref]}
            if not self._fits(device, voiced):
                with contextlib.suppress(ProtocolError, TimeoutError):
                    await blobs.delete(self._relay, blob_id)
                voiced = body
            await self._mail(device, voiced, alert=True)

    async def send_file(self, data: bytes, name: str, mime: str, kind: str, caption: str = "") -> str:
        if kind not in ATTACHMENT_KINDS:
            raise ProtocolError("invalid attachment kind")
        message_id = new_id()
        name, mime = _clean_name(name, kind), _clean_mime(mime)
        self._remember(self._agent_name, f"{caption} [{kind}: {name}]".strip())
        for device in list(self._state.devices.values()):
            key, sealed = blobs.seal(data)
            try:
                blob_id = await blobs.upload(self._relay, sealed, to=device.id)
            except (ProtocolError, OSError, TimeoutError) as exc:
                log.warning("attachment for %s not uploaded: %s", device.id[:6], exc)
                continue
            ref = {"kind": kind, "blob_id": blob_id, "key": wire.b64e(key), "name": name, "mime": mime, "size": len(data)}
            body = {
                "type": "chat",
                "id": message_id,
                "role": "agent",
                "kind": "text",
                "text": caption[:MAX_TEXT],
                "attachments": [ref],
            }
            await self._mail(device, body, alert=True)
        return message_id

    def fits_presentation(self, text: str, presentation: dict[str, Any]) -> bool:
        """Whether the sealed chat message stays within the relay's mail limit (48 KiB)."""
        device = next(iter(self._state.devices.values()), None)
        return device is None or self._fits(device, self._presentation_body(new_id(), text, presentation))

    def _fits(self, device: Device, body: dict[str, Any]) -> bool:
        try:
            sealed = self._channel.seal(device.id, device.box_key, body, mid=new_id())
        except ProtocolError:
            return False
        return len(sealed) * 3 // 4 <= MAX_MAIL

    async def send_presentation(self, text: str, presentation: dict[str, Any], images: dict[int, bytes], summary: str) -> str:
        """Cards in the app; `images` (item index → JPEG) go to each phone as encrypted blobs."""
        message_id = new_id()
        self._remember(self._agent_name, summary)
        for device in list(self._state.devices.values()):
            items = list(presentation["items"])
            for index, jpeg in images.items():
                key, sealed = blobs.seal(jpeg)
                try:
                    blob_id = await blobs.upload(self._relay, sealed, to=device.id)
                except (ProtocolError, OSError, TimeoutError) as exc:
                    log.warning("presentation image for %s not uploaded: %s", device.id[:6], exc)
                    continue
                image = {"blob_id": blob_id, "key": wire.b64e(key), "mime": "image/jpeg", "size": len(jpeg)}
                items[index] = {**items[index], "image": image}
            body = self._presentation_body(message_id, text, {**presentation, "items": items})
            await self._mail(device, body, alert=True)
        return message_id

    @staticmethod
    def _presentation_body(message_id: str, text: str, presentation: dict[str, Any]) -> dict[str, Any]:
        return {
            "type": "chat",
            "id": message_id,
            "role": "agent",
            "kind": "presentation",
            "text": text[:MAX_TEXT],
            "presentation": presentation,
        }

    async def typing(self) -> None:
        for device in list(self._state.devices.values()):
            await self._live(device, {"type": "typing"})

    async def request_approval(self, request_id: str, command: str, description: str) -> bool:
        """Face ID sheet on the phones; the answer comes back as an `approval` event."""
        if len(command) > MAX_APPROVAL_TEXT or len(description) > MAX_APPROVAL_TEXT or not self._state.devices:
            return False
        now = time.monotonic()
        self._approvals = {key: until for key, until in self._approvals.items() if until > now}
        self._approvals[request_id] = now + APPROVAL_TTL
        body = {
            "type": "approval_request",
            "request_id": request_id,
            "command": command,
            "description": description,
            "chat": True,
            "choices": list(APPROVAL_CHOICES),
        }
        await self._mail_all(body, alert=True)
        return True

    async def missed_call(self, reason: str, first_message: str, status: str) -> bool:
        """A ring nobody answered becomes a chat message, so the owner still gets it."""
        if not self._state.devices:
            return False
        what = "declined" if status == "declined" else "missed"
        text = first_message if not reason else f"{first_message}\n\n(Reason for the call: {reason})"
        await self.send_text(text, kind=f"{what}_call")
        return True

    # ---- context shared between calls and chat ---------------------------

    def _remember(self, who: str, text: str) -> None:
        self._recent.append((who, text[:1000]))
        self._persist("recent", [list(line) for line in self._recent])

    def _persist(self, key: str, value: Any) -> None:
        """Ordered after earlier store calls; a failure only costs context, never a message."""
        self._db.submit(self._db.store.set_json, key, value).add_done_callback(_log_failure)

    def _take_call_context(self) -> str:
        context, self._call_context = self._call_context, ""
        if context:
            self._persist("call_context", "")
        return context

    def recent_context(self) -> str:
        lines = [f"{who}: {text}" for who, text in self._recent]
        body = "\n".join(lines)[-MAX_CONTEXT_CHARS:]
        return f"Recent chat messages with your owner (oldest first):\n{body}" if body else ""

    def note_call(self, transcript: list[tuple[str, str]]) -> None:
        """The next chat message tells the agent what was said on the phone."""
        if not transcript:
            return
        lines = "\n".join(f"{who}: {text}" for who, text in transcript)[-MAX_CONTEXT_CHARS:]
        stamp = time.strftime("%H:%M UTC", time.gmtime())
        self._call_context = f"[Context: a phone call with your owner ended at {stamp}. Transcript:\n{lines}]\n\n"
        self._persist("call_context", self._call_context)
        for who, text in transcript:
            self._remember(f"{who} (call)", text)

    # ---- transport -------------------------------------------------------

    async def _mirror(self, sender: Device, message_id: str, text: str, attachments: list[Attachment], transcript: str) -> None:
        """Other phones of the owner see what was sent from this one (text only)."""
        others = [d for d in self._state.devices.values() if d.id != sender.id]
        if not others:
            return
        labels = [f"[{a.kind}: {a.name}]" for a in attachments]
        mirrored = "\n".join(part for part in (text, transcript, *labels) if part)
        for device in others:
            await self._mail(
                device, {"type": "chat", "id": message_id, "role": "owner", "kind": "text", "text": mirrored}, alert=False
            )

    async def _mail_all(self, body: dict[str, Any], alert: bool) -> None:
        for device in list(self._state.devices.values()):
            await self._mail(device, body, alert)

    async def _mail(self, device: Device, body: dict[str, Any], alert: bool) -> None:
        """Through the persistent outbox: kept and retried until the relay's mailbox took it."""
        await self.outbox.queue(device.id, str(body.get("id") or body.get("request_id") or ""), body, alert)

    async def _live(self, device: Device, body: dict[str, Any]) -> None:
        await self._transport.live(device, body)

    def forget_device(self, device_id: str) -> None:
        self._db.submit(self._db.store.forget_device, device_id).add_done_callback(_log_failure)


def _log_failure(future: asyncio.Future) -> None:
    if not future.cancelled() and future.exception() is not None:
        log.warning("chat store update failed: %s", future.exception())
