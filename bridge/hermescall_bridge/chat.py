"""Chat between the owner's phones and the agent (Hermes platform adapter `hermes_call`).

Phones → bridge: E2E `chat` messages (mailbox envelope with `mid`), attachments as
encrypted relay blobs. Bridge → Hermes: an event queue the plugin's adapter
long-polls on the local API. Hermes → phones: E2E messages through the relay
mailbox with an alert push. All paired phones share one chat ("owner").

Logs carry ids and sizes only — never message text.
"""

import asyncio
import contextlib
import io
import logging
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

from .hermes import APPROVAL_CHOICES, MAX_APPROVAL_TEXT
from .state import Device, State
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
SEEN_MESSAGES = 2000
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
    ) -> None:
        self._state = state
        self._tts = tts
        # (owner voice-note id, monotonic deadline): the agent's reply to it is also spoken
        self._voice_note: tuple[str, float] | None = None
        self._relay = relay
        self._channel = channel
        self._transcribe = transcribe
        self._agent_name = agent_name
        self._events: deque[tuple[int, dict[str, Any]]] = deque(maxlen=MAX_EVENTS)
        self._seq = 0
        self._changed = asyncio.Condition()
        self._recent: deque[tuple[str, str]] = deque(maxlen=RECENT_LINES)
        self._call_context = ""
        self._approvals: dict[str, float] = {}
        # Phones resend unacknowledged messages (new envelope, same id): ack again, deliver once.
        self._seen_messages: deque[str] = deque(maxlen=SEEN_MESSAGES)
        self.last_poll = 0.0

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
        await self._live(device, {"type": "chat_ack", "id": message_id, "state": "delivered"})
        if message_id in self._seen_messages:
            return
        self._seen_messages.append(message_id)
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
        context, self._call_context = self._call_context, ""
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
            }
        )
        log.info("chat message from %s: %d chars, %d attachments", device.id[:6], len(text), len(attachments))

    async def _fetch_attachments(self, device: Device, attachments: list[Attachment]) -> tuple[list[dict], list[str], list[str]]:
        """(files for Hermes, voice-note transcripts, notes about attachments that failed)"""
        files: list[dict] = []
        voice: list[str] = []
        problems: list[str] = []
        for item in attachments:
            try:
                data = blobs.open_sealed(item.key, await blobs.download(self._relay, item.blob_id))
            except (ProtocolError, CryptoError, OSError, TimeoutError) as exc:
                log.warning("attachment from %s unavailable: %s", device.id[:6], exc.__class__.__name__)
                problems.append(f"(attachment '{item.name}' could not be downloaded)")
                continue
            finally:
                with contextlib.suppress(ProtocolError, TimeoutError):
                    await blobs.delete(self._relay, item.blob_id)
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

    async def _emit(self, event: dict[str, Any]) -> None:
        async with self._changed:
            self._seq += 1
            self._events.append((self._seq, event))
            self._changed.notify_all()

    async def poll(self, cursor: int, wait: float) -> tuple[int, list[dict[str, Any]]]:
        """Events after `cursor`; everything up to `cursor` counts as received by Hermes."""
        self.last_poll = time.monotonic()
        async with self._changed:
            while self._events and self._events[0][0] <= cursor:
                self._events.popleft()
            if not self._events and wait > 0:
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self._changed.wait(), min(wait, MAX_POLL_SECONDS))
            events = [event for seq, event in self._events if seq > cursor]
            return (self._events[-1][0] if self._events else max(cursor, self._seq)), events

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
        mid = new_id()
        sealed = self._channel.seal(device.id, device.box_key, body, mid=mid)
        try:
            await self._relay.request({"t": "mail", "to": device.id, "id": mid, "data": sealed, "alert": alert})
        except (ProtocolError, TimeoutError) as exc:
            log.warning("chat message for %s not stored: %s", device.id[:6], exc)

    async def _live(self, device: Device, body: dict[str, Any]) -> None:
        sealed = self._channel.seal(device.id, device.box_key, body)
        with contextlib.suppress(ProtocolError):
            await self._relay.send({"t": "e2e", "to": device.id, "data": sealed})
