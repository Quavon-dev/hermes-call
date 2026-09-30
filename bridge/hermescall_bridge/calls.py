"""Call signaling (E2E over the relay) and the lifecycle of the single active call."""

import asyncio
import contextlib
import logging
import math
import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from aiortc import RTCSessionDescription

from hermescall_common import blobs, sodium, wire
from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel
from hermescall_common.errors import CryptoError, ProtocolError

from .audio import SpeechTrack, read_16k
from .conversation import Conversation
from .hermes import APPROVAL_CHOICES, MAX_APPROVAL_TEXT, ApprovalRequest
from .present import to_jpeg
from .state import Device, State
from .webrtc import peer_connection

log = logging.getLogger(__name__)

RING_TIMEOUT = 45.0
APPROVAL_TIMEOUT = 60.0
MAX_CALL_SECONDS = 3600.0
MAX_SDP = 16 * 1024
MAX_REASON = 500
MAX_FIRST_MESSAGE = 1000
MAX_TRANSCRIPT = 2000
MAX_CAPTION = 500
CAPTION_ROLES = ("agent", "owner")
# Rings per window (the relay adds 10/min); stops a prompt-injected agent from phoning in a loop.
RING_LIMITS = ((600.0, 3), (86_400.0, 20))
# "Look at this": stills the owner shows during a call.
CALL_IMAGE_MIMES = ("image/jpeg", "image/png", "image/heic")
CALL_IMAGE_INTERVAL = 1.0
MAX_CALL_IMAGES = 30
CALL_IMAGE_SIDE = 1280
# All call_image messages per device (accepted or not): each costs a download or a blob delete.
CALL_IMAGE_MESSAGES = (60.0, 40)


def _open_image(key: bytes, sealed: bytes) -> bytes:
    """Decrypt and re-encode in one executor call (both are CPU work)."""
    return to_jpeg(blobs.open_sealed(key, sealed), CALL_IMAGE_SIDE)


async def _metered(inbound: Any, level: dict) -> Any:
    """Passes audio through while tracking duration and peak level (no content)."""
    async for block in inbound:
        level["seconds"] += len(block) / 16_000
        level["peak"] = max(level["peak"], float(abs(block).max()) if len(block) else 0.0)
        yield block


def prefer_constant_bitrate(sdp: str) -> str:
    """Ask the phone's Opus encoder for CBR so packet sizes do not reveal speech patterns."""
    opus = {line.split()[0].split(":")[1] for line in sdp.splitlines() if line.startswith("a=rtpmap:") and "opus/48000" in line}
    lines = []
    for line in sdp.splitlines():
        if line.startswith("a=fmtp:") and line.split()[0].split(":")[1] in opus and "cbr=" not in line:
            line += ";cbr=1"
        lines.append(line)
    return "\r\n".join(lines) + "\r\n"


def new_call_id() -> str:
    return wire.b64e(sodium.random_bytes(16))


def valid_call_id(value: object) -> str:
    wire.b64d(value, length=16)
    return value  # type: ignore[return-value]


@dataclass
class Ring:
    call_id: str
    targets: set[str]
    reason: str
    first_message: str
    outcome: asyncio.Future = field(default_factory=lambda: asyncio.get_running_loop().create_future())


@dataclass
class ActiveCall:
    call_id: str
    device: Device
    pc: Any
    conversation: Conversation | None = None
    task: asyncio.Task | None = None
    approvals: dict[str, asyncio.Future] = field(default_factory=dict)
    device_stt: bool = False
    started: float = field(default_factory=time.monotonic)
    captions: set[asyncio.Task] = field(default_factory=set)
    images: int = 0
    last_image: float = -math.inf


class CallManager:
    def __init__(
        self,
        state: State,
        relay: RelaySession,
        channel: Channel,
        conversation_factory: Callable,
        on_unpair: Callable[[str], Awaitable[None]] | None = None,
        other_messages: Callable[[Device, dict], Awaitable[None]] | None = None,
        on_missed: Callable[[Ring, str], Awaitable[bool]] | None = None,
        on_call_ended: Callable[[list[tuple[str, str]]], None] | None = None,
    ) -> None:
        self._state = state
        self._on_unpair_request = on_unpair
        self._other_messages = other_messages
        self._on_missed = on_missed
        self._on_call_ended = on_call_ended
        self._relay = relay
        self._channel = channel
        self._make_conversation = conversation_factory
        self._rings: dict[str, Ring] = {}
        self._ring_times: deque[float] = deque(maxlen=max(n for _, n in RING_LIMITS))
        self._offer_lock = asyncio.Lock()
        self._image_messages: dict[str, deque[float]] = {}
        self.active: ActiveCall | None = None

    # ---- outbound ------------------------------------------------------

    async def ring(self, reason: str, first_message: str, device: str = "all") -> dict[str, str]:
        if self.active is not None or self._rings:
            return {"status": "busy"}
        targets = set(self._state.devices) if device == "all" else {device} & set(self._state.devices)
        if not targets:
            return {"status": "no_devices"}
        now = time.monotonic()
        if any(sum(now - t < window for t in self._ring_times) >= limit for window, limit in RING_LIMITS):
            return {"status": "rate_limited"}
        self._ring_times.append(now)
        ring = Ring(new_call_id(), targets, reason[:MAX_REASON], first_message[:MAX_FIRST_MESSAGE])
        self._rings[ring.call_id] = ring
        try:
            try:
                await self._relay.request({"t": "ring", "call_id": ring.call_id, "devices": sorted(targets)})
            except ProtocolError as exc:
                log.warning("push failed: %s", exc)
            for device_id in targets:
                await self._send(device_id, {"type": "invite", "call_id": ring.call_id, "reason": ring.reason})
            status = await asyncio.wait_for(asyncio.shield(ring.outcome), RING_TIMEOUT)
        except TimeoutError:
            status = "no_answer"
            for device_id in ring.targets:
                await self._send(device_id, {"type": "cancel", "call_id": ring.call_id, "why": "timeout"})
        finally:
            self._rings.pop(ring.call_id, None)
        log.info("ring finished: %s", status)
        result: dict = {"status": status, "call_id": ring.call_id}
        if status in ("no_answer", "declined") and self._on_missed is not None:
            result["messaged"] = await self._on_missed(ring, status)
        return result

    # ---- inbound E2E ---------------------------------------------------

    async def on_e2e(self, from_id: str, data: str) -> None:
        device = self._state.devices.get(from_id)
        if device is None:
            return
        try:
            body = self._channel.open(device.id, device.box_key, data)
            if self._other_messages is not None and (
                body["type"] in ("chat", "phone_answer", "task_prefs") or (body["type"] == "approval" and "call_id" not in body)
            ):
                await self._other_messages(device, body)
                return
            handler = {
                "offer": self._on_offer,
                "hangup": self._on_hangup,
                "decline": self._on_decline,
                "invite_query": self._on_invite_query,
                "ptt": self._on_ptt,
                "interrupt": self._on_interrupt,
                "call_image": self._on_call_image,
                "transcript": self._on_transcript,
                "approval": self._on_approval_answer,
                "unpair": self._on_unpair,
            }.get(body["type"])
            if handler is None:
                raise ProtocolError("unknown message type")
            await handler(device, body)
        except ProtocolError as exc:
            log.warning("rejected message from device %s: %s", device.id[:6], exc)

    async def _on_invite_query(self, device: Device, body: dict) -> None:
        call_id = valid_call_id(body.get("call_id"))
        ring = self._rings.get(call_id)
        if ring is not None and device.id in ring.targets:
            await self._send(device.id, {"type": "invite", "call_id": call_id, "reason": ring.reason})
        else:
            await self._send(device.id, {"type": "cancel", "call_id": call_id, "why": "unknown_call"})

    async def _on_decline(self, device: Device, body: dict) -> None:
        ring = self._rings.get(valid_call_id(body.get("call_id")))
        if ring is None or device.id not in ring.targets:
            return
        ring.targets.discard(device.id)
        if not ring.targets and not ring.outcome.done():
            ring.outcome.set_result("declined")

    async def _on_offer(self, device: Device, body: dict) -> None:
        async with self._offer_lock:
            await self._accept_offer(device, body)

    async def _accept_offer(self, device: Device, body: dict) -> None:
        call_id = valid_call_id(body.get("call_id"))
        sdp = body.get("sdp")
        if not isinstance(sdp, str) or not 0 < len(sdp) <= MAX_SDP:
            raise ProtocolError("invalid sdp")
        ring = self._rings.get(call_id)
        stale = self.active
        if stale is not None and stale.device.id == device.id and stale.call_id != call_id:
            log.info("replacing a stale call from the same device")
            await self.end(stale.call_id, notify=False)
        if self.active is not None or (self._rings and ring is None):
            await self._send(device.id, {"type": "busy", "call_id": call_id})
            return
        if ring is not None and (device.id not in ring.targets or ring.outcome.done()):
            await self._send(device.id, {"type": "cancel", "call_id": call_id, "why": "answered_elsewhere"})
            return
        await self._start_call(device, call_id, sdp, ring, body.get("stt") == "device")
        if ring is not None:
            ring.outcome.set_result("answered")
            for other in ring.targets - {device.id}:
                await self._send(other, {"type": "cancel", "call_id": call_id, "why": "answered_elsewhere"})

    async def _start_call(self, device: Device, call_id: str, sdp: str, ring: Ring | None, device_stt: bool) -> None:
        turn = await self._relay.request({"t": "turn"})
        pc = peer_connection(turn)
        call = ActiveCall(call_id, device, pc, device_stt=device_stt)
        self.active = call
        out = SpeechTrack()
        pc.addTrack(out)

        @pc.on("track")
        def on_track(track: Any) -> None:
            if track.kind == "audio" and call.task is None:
                call.conversation = self._make_conversation(
                    out, lambda req: self._ask_approval(call, req), ring, lambda role, text: self._caption(call, role, text)
                )
                if call.device_stt:
                    call.conversation.use_device_stt()
                first = ring.first_message if ring else ""
                call.task = asyncio.ensure_future(self._run_conversation(call, read_16k(track), first))

        @pc.on("connectionstatechange")
        async def on_state() -> None:
            if pc.connectionState in ("failed", "closed"):
                await self.end(call_id, notify=pc.connectionState == "failed")

        try:
            await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
            await pc.setLocalDescription(await pc.createAnswer())
        except Exception as exc:
            await self.end(call_id, notify=False)
            raise ProtocolError("offer rejected") from exc
        answer = prefer_constant_bitrate(pc.localDescription.sdp)
        await self._send(device.id, {"type": "answer", "call_id": call_id, "sdp": answer})
        log.info("call started (%s) with device %s", "outbound" if ring else "inbound", device.id[:6])

    async def _run_conversation(self, call: ActiveCall, inbound: Any, first_message: str) -> None:
        level = {"seconds": 0.0, "peak": 0.0}
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(call.conversation.run(_metered(inbound, level), first_message), MAX_CALL_SECONDS)
        peak_db = 20 * math.log10(level["peak"]) if level["peak"] > 0 else -120.0
        log.info("inbound audio: %.1f s, peak %.0f dBFS", level["seconds"], peak_db)
        await self.end(call.call_id)

    async def _on_hangup(self, device: Device, body: dict) -> None:
        call = self.active
        if call is not None and call.device.id == device.id and call.call_id == body.get("call_id"):
            await self.end(call.call_id, notify=False)

    async def _on_transcript(self, device: Device, body: dict) -> None:
        call = self.active
        text, stt_ms = body.get("text"), body.get("stt_ms")
        if call is None or call.device.id != device.id or call.call_id != body.get("call_id") or not call.device_stt:
            return
        if not isinstance(text, str) or not 0 < len(text.strip()) <= MAX_TRANSCRIPT:
            raise ProtocolError("invalid transcript")
        if call.conversation is not None:
            call.conversation.submit_text(text.strip(), stt_ms if isinstance(stt_ms, int) else None)

    async def _on_ptt(self, device: Device, body: dict) -> None:
        call = self.active
        if call and call.device.id == device.id and call.call_id == body.get("call_id") and call.conversation:
            call.conversation.set_ptt(body.get("down") is True)

    async def _on_interrupt(self, device: Device, body: dict) -> None:
        call = self.active
        if call and call.device.id == device.id and call.call_id == body.get("call_id") and call.conversation:
            call.conversation.interrupt()

    # ---- "look at this": photos during a call (never logged, never stored) -------

    async def _on_call_image(self, device: Device, body: dict) -> None:
        blob_id = body.get("blob_id")
        wire.b64d(blob_id, length=16)
        if not self._image_message_allowed(device.id):
            log.warning("call images from %s ignored: too many", device.id[:6])
            return
        call_id, ok = body.get("call_id"), False
        try:
            valid_call_id(call_id)
            ok = await self._accept_image(device, call_id, blob_id, body)
        except ProtocolError:
            log.warning("call image from %s rejected: invalid call id", device.id[:6])
            call_id = ""
        finally:
            # Accepted or not, the blob never stays on the relay (its quota is small).
            with contextlib.suppress(ProtocolError, TimeoutError):
                await blobs.delete(self._relay, blob_id)
        await self._send(device.id, {"type": "call_image_ack", "call_id": call_id, "blob_id": blob_id, "ok": ok})

    def _image_message_allowed(self, device_id: str) -> bool:
        window, limit = CALL_IMAGE_MESSAGES
        now = time.monotonic()
        times = self._image_messages.setdefault(device_id, deque(maxlen=limit))
        if len(times) == limit and now - times[0] < window:
            return False
        times.append(now)
        return True

    async def _accept_image(self, device: Device, call_id: str, blob_id: str, body: dict) -> bool:
        call = self.active
        if call is None or call.device.id != device.id or call.call_id != call_id or call.conversation is None:
            log.warning("call image from %s rejected: not in this call", device.id[:6])
            return False
        if body.get("mime") not in CALL_IMAGE_MIMES:
            log.warning("call image rejected: unsupported type")
            return False
        now = time.monotonic()
        if call.images >= MAX_CALL_IMAGES or now - call.last_image < CALL_IMAGE_INTERVAL:
            log.info("call image dropped (rate limit, %d so far)", call.images)
            return False
        call.images += 1
        call.last_image = now
        try:
            key = wire.b64d(body.get("key"), length=32)
            sealed = await blobs.download(self._relay, blob_id)
            image = await asyncio.get_running_loop().run_in_executor(None, _open_image, key, sealed)
        except (ProtocolError, CryptoError, OSError, TimeoutError, ValueError) as exc:
            log.warning("call image unavailable: %s", exc.__class__.__name__)
            return False
        if self.active is not call:
            return False
        call.conversation.add_image(image)
        log.info("call image %d attached (%d bytes)", call.images, len(image))
        return True

    # ---- live captions (best-effort, text never logged) -----------------

    def _caption(self, call: ActiveCall, role: str, text: str) -> None:
        if self.active is not call or role not in CAPTION_ROLES or (role == "owner" and call.device_stt):
            return
        text = text.strip()[:MAX_CAPTION].strip()
        if not text:
            return
        task = asyncio.ensure_future(self._send_caption(call, role, text))
        call.captions.add(task)
        task.add_done_callback(call.captions.discard)

    async def _send_caption(self, call: ActiveCall, role: str, text: str) -> None:
        try:
            await self._send(call.device.id, {"type": "caption", "call_id": call.call_id, "role": role, "text": text})
        except Exception as exc:
            log.warning("caption (%s, %d chars) not sent: %s", role, len(text), type(exc).__name__)

    async def end(self, call_id: str, notify: bool = True) -> None:
        call = self.active
        if call is None or call.call_id != call_id:
            return
        self.active = None
        for future in call.approvals.values():
            if not future.done():
                future.set_result("deny")
        if call.task is not None and call.task is not asyncio.current_task():
            call.task.cancel()
        await call.pc.close()
        if self._on_call_ended is not None and call.conversation is not None:
            self._on_call_ended(list(call.conversation.transcript))
        if notify:
            await self._send(call.device.id, {"type": "hangup", "call_id": call_id})
        log.info("call ended after %.0f s", time.monotonic() - call.started)

    async def _on_unpair(self, device: Device, body: dict) -> None:
        if self._on_unpair_request is not None:
            await self._on_unpair_request(device.id)

    async def forget_device(self, device_id: str) -> None:
        """A revoked device loses any ring slot and its active call immediately."""
        for ring in self._rings.values():
            ring.targets.discard(device_id)
            if not ring.targets and not ring.outcome.done():
                ring.outcome.set_result("declined")
        if self.active is not None and self.active.device.id == device_id:
            await self.end(self.active.call_id, notify=False)

    # ---- approvals (on the phone screen, never by voice) ----------------

    async def _ask_approval(self, call: ActiveCall, request: ApprovalRequest) -> str:
        if len(request.command) > MAX_APPROVAL_TEXT or len(request.description) > MAX_APPROVAL_TEXT:
            log.warning("approval request too long to show in full; denied")
            return "deny"
        key = request.request_id or new_call_id()
        future = asyncio.get_running_loop().create_future()
        call.approvals[key] = future
        await self._send(
            call.device.id,
            {
                "type": "approval_request",
                "call_id": call.call_id,
                "request_id": key,
                "command": request.command,
                "description": request.description,
            },
        )
        try:
            return await asyncio.wait_for(future, APPROVAL_TIMEOUT)
        except TimeoutError:
            return "deny"
        finally:
            call.approvals.pop(key, None)

    async def _on_approval_answer(self, device: Device, body: dict) -> None:
        call = self.active
        if call is None or call.device.id != device.id or call.call_id != body.get("call_id"):
            return
        request_id = body.get("request_id")
        future = call.approvals.get(request_id) if isinstance(request_id, str) else None
        choice = body.get("choice")
        if future is not None and not future.done():
            future.set_result(choice if choice in APPROVAL_CHOICES else "deny")

    # ---- transport -----------------------------------------------------

    async def _send(self, device_id: str, body: dict[str, Any]) -> None:
        device = self._state.devices.get(device_id)
        if device is None:
            return
        sealed = self._channel.seal(device.id, device.box_key, body)
        try:
            await self._relay.send({"t": "e2e", "to": device.id, "data": sealed})
        except ProtocolError as exc:
            log.warning("could not reach device %s: %s", device.id[:6], exc)
