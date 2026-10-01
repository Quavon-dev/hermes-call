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

from . import resume
from .audio import SpeechTrack
from .conversation import Conversation
from .hermes import APPROVAL_CHOICES, MAX_APPROVAL_TEXT, ApprovalRequest
from .metrics import METRICS
from .peers import Peers, hello_body, unsupported_body
from .present import to_jpeg
from .resume import CONNECTION_LOST, RESUME_CAP, ForwardTrack, InboundAudio
from .state import Device, State
from .transport import Transport
from .webrtc import peer_connection

log = logging.getLogger(__name__)

RING_TIMEOUT = 45.0
APPROVAL_TIMEOUT = 60.0
MAX_CALL_SECONDS = 3600.0
CALL_WARNING_SECONDS = 60.0
# No audio track from the phone this long after the answer: the call never really started.
MEDIA_TIMEOUT = 20.0
CALL_ENDING_LINE = "We have about a minute left on this call."
# Captions that could not be sent while the relay was away; re-sent after it reconnects.
MAX_UNSENT_CAPTIONS = 3
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
# E2E types for chat, phone context and tasks (handed to `other_messages`).
OTHER_TYPES = ("chat", "phone_answer", "task_prefs", "history_request")


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


@dataclass(frozen=True)
class CallTimeouts:
    """From bridge.toml [calls]; None = the module default."""

    ring: float | None = None
    approval: float | None = None
    max_call: float | None = None
    warning: float | None = None
    media: float | None = None


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
    # Approval requests still waiting for an answer (re-sent after a relay reconnect).
    pending_approvals: dict[str, dict] = field(default_factory=dict)
    unsent_captions: deque = field(default_factory=lambda: deque(maxlen=MAX_UNSENT_CAPTIONS))
    timers: list[asyncio.TimerHandle] = field(default_factory=list)
    images: int = 0
    last_image: float = -math.inf
    ring: Ring | None = None
    out: SpeechTrack = field(default_factory=SpeechTrack)
    # The phone listed `call_resume`: a failed connection waits for its re-offer (resume.py).
    resumable: bool = False
    inbound: InboundAudio | None = None
    resuming: bool = False
    resume_timer: asyncio.TimerHandle | None = None
    # An audio frame arrived from the phone (not just a track announced).
    media: bool = False


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
        timeouts: CallTimeouts | None = None,
        turn_transport: str = "auto",
    ) -> None:
        self._timeouts = timeouts or CallTimeouts()
        self._turn_transport = turn_transport
        self._state = state
        self._on_unpair_request = on_unpair
        self._other_messages = other_messages
        self._on_missed = on_missed
        self._on_call_ended = on_call_ended
        self._relay = relay
        self._channel = channel
        self._make_conversation = conversation_factory
        self._transport = Transport(state, relay, channel)
        self._rings: dict[str, Ring] = {}
        self._ring_times: deque[float] = deque(maxlen=max(n for _, n in RING_LIMITS))
        self._offer_lock = asyncio.Lock()
        # Offers being set up (call id → device id) and those hung up meanwhile (no ghost calls).
        # device id → monotonic time of its last authentic message (phone context prefers the most recent)
        self._activity: dict[str, float] = {}
        self._starting: dict[str, str] = {}
        self._hung_up: set[str] = set()
        self._image_messages: dict[str, deque[float]] = {}
        self.active: ActiveCall | None = None
        self.peers = Peers()

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
            status = await asyncio.wait_for(asyncio.shield(ring.outcome), self._timeout("ring", RING_TIMEOUT))
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
            self._activity[device.id] = time.monotonic()
            if self._other_messages is not None and (
                body["type"] in OTHER_TYPES or (body["type"] == "approval" and "call_id" not in body)
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
                "hello": self._on_hello,
                "unsupported": self._on_unsupported,
            }.get(body["type"])
            if handler is None:
                log.info("unknown message type from device %s; answered unsupported", device.id[:6])
                await self._send(device.id, unsupported_body(body["type"]))
                return
            await handler(device, body)
        except ProtocolError as exc:
            log.warning("rejected message from device %s: %s", device.id[:6], exc)

    async def _on_hello(self, device: Device, body: dict) -> None:
        self.peers.on_hello(device.id, body)
        await self._send(device.id, hello_body())

    async def _on_unsupported(self, device: Device, body: dict) -> None:
        """The phone did not know something the bridge sent (an older app); never answered in turn."""
        unknown = body.get("unknown")
        log.info("phone %s does not support %s", device.id[:6], unknown if isinstance(unknown, str) else "a message")

    def last_activity(self, device_id: str) -> float:
        """Monotonic time of the phone's last authentic message (-inf: none since start)."""
        return self._activity.get(device_id, -math.inf)

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
        call_id = body.get("call_id")
        mine = isinstance(call_id, str) and call_id not in self._starting
        if mine:
            self._starting[call_id] = device.id
        try:
            async with self._offer_lock:
                await self._accept_offer(device, body)
        finally:
            if mine:  # a second offer with the same id must not clear the first one's state
                self._starting.pop(call_id, None)
                self._hung_up.discard(call_id)

    def _cancelled(self, call_id: str) -> bool:
        return call_id in self._hung_up

    async def _accept_offer(self, device: Device, body: dict) -> None:
        call_id = valid_call_id(body.get("call_id"))
        sdp = body.get("sdp")
        if not isinstance(sdp, str) or not 0 < len(sdp) <= MAX_SDP:
            raise ProtocolError("invalid sdp")
        ring = self._rings.get(call_id)
        stale = self.active
        if stale is not None and stale.device.id == device.id and stale.call_id == call_id and stale.resumable:
            await self._resume(stale, sdp)
            return
        if stale is not None and stale.device.id == device.id and stale.call_id != call_id:
            log.info("replacing a stale call from the same device")
            await self.end(stale.call_id, notify=False)
        if self.active is not None or (self._rings and ring is None):
            await self._send(device.id, {"type": "busy", "call_id": call_id})
            return
        if ring is not None and (device.id not in ring.targets or ring.outcome.done()):
            await self._send(device.id, {"type": "cancel", "call_id": call_id, "why": "answered_elsewhere"})
            return
        if self._cancelled(call_id):
            log.info("call hung up before it was set up")
            return
        if not await self._start_call(device, call_id, sdp, ring, body.get("stt") == "device"):
            return
        if ring is not None:
            ring.outcome.set_result("answered")
            for other in ring.targets - {device.id}:
                await self._send(other, {"type": "cancel", "call_id": call_id, "why": "answered_elsewhere"})

    async def _start_call(self, device: Device, call_id: str, sdp: str, ring: Ring | None, device_stt: bool) -> bool:
        """False: the owner hung up while this was being set up (nothing was answered)."""
        turn = await self._relay.request({"t": "turn"})
        if self._cancelled(call_id):
            log.info("call hung up while fetching TURN credentials")
            return False
        resumable = self.peers.supports(device.id, RESUME_CAP)
        call = ActiveCall(call_id, device, None, device_stt=device_stt, ring=ring, resumable=resumable)
        call.inbound = InboundAudio(resumable, lambda: self._media_arrived(call))
        self.active = call
        try:
            answer = await self._connect(call, turn, sdp)
        except Exception as exc:
            await self.end(call_id, notify=False)
            raise ProtocolError("offer rejected") from exc
        if self._cancelled(call_id) or self.active is not call:
            await self.end(call_id, notify=False)
            log.info("call hung up while it was being set up")
            return False
        await self._send(device.id, {"type": "answer", "call_id": call_id, "sdp": answer})
        media = self._timeout("media", MEDIA_TIMEOUT)
        call.timers.append(asyncio.get_running_loop().call_later(media, self._check_media, call, media))
        log.info("call started (%s) with device %s", "outbound" if ring else "inbound", device.id[:6])
        METRICS.calls.inc("outbound" if ring else "inbound")
        return True

    async def _connect(self, call: ActiveCall, turn: dict, sdp: str) -> str:
        """A peer connection for the call (the first, or a new one after a network change); returns the answer."""
        pc = peer_connection(turn, self._turn_transport)
        call.pc = pc
        pc.addTrack(ForwardTrack(call.out))

        @pc.on("track")
        def on_track(track: Any) -> None:
            if track.kind != "audio" or call.pc is not pc or call.inbound is None:
                return
            call.inbound.attach(track)  # announced, not yet audio: `_media_arrived` on its first frame
            if call.task is None:
                self._begin_conversation(call)

        @pc.on("connectionstatechange")
        async def on_state() -> None:
            if call.pc is not pc or self.active is not call:
                return  # a replaced connection closing
            if pc.connectionState == "failed" and call.resumable:
                self._await_resume(call)
            elif pc.connectionState in ("failed", "closed"):
                await self.end(call.call_id, notify=pc.connectionState == "failed")

        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
        await pc.setLocalDescription(await pc.createAnswer())
        return prefer_constant_bitrate(pc.localDescription.sdp)

    def _begin_conversation(self, call: ActiveCall) -> None:
        call.conversation = self._make_conversation(
            call.out,
            lambda req: self._ask_approval(call, req),
            call.ring,
            lambda role, text: self._caption(call, role, text),
            call.device.id,
        )
        if call.device_stt:
            call.conversation.use_device_stt()
        first = call.ring.first_message if call.ring else ""
        call.task = asyncio.ensure_future(self._run_conversation(call, call.inbound.blocks(), first))

    # ---- network handover: the phone re-offers for the same call (resume.py) -------------

    async def _resume(self, call: ActiveCall, sdp: str) -> None:
        turn = await self._relay.request({"t": "turn"})
        if self.active is not call:
            return
        self._await_resume(call)  # also covers a re-offer whose media never arrives
        old, call.pc = call.pc, None
        if old is not None:
            await old.close()  # first, so two connections never read the speech track at once
        if self.active is not call:
            return  # hung up (or given up) while the old connection closed: no new one
        try:
            answer = await self._connect(call, turn, sdp)
        except Exception as exc:
            await self._close_if_ended(call)
            raise ProtocolError("re-offer rejected") from exc
        if await self._close_if_ended(call):
            return
        await self._send(call.device.id, {"type": "answer", "call_id": call.call_id, "sdp": answer})
        log.info("call moving to a new connection (network change)")

    async def _close_if_ended(self, call: ActiveCall) -> bool:
        """True when the call ended while its new connection was being built; that connection is closed
        here (`end()` may have run before it existed), so its sockets and TURN allocation do not leak."""
        if self.active is call:
            return False
        if call.pc is not None:
            await call.pc.close()
        return True

    def _await_resume(self, call: ActiveCall) -> None:
        if call.resume_timer is not None:
            return
        log.info("call media lost; waiting up to %.0f s for the phone to reconnect", resume.RESUME_WINDOW)
        call.resuming = True
        call.resume_timer = asyncio.get_running_loop().call_later(resume.RESUME_WINDOW, self._give_up, call)

    def _media_arrived(self, call: ActiveCall) -> None:
        """The first audio frame of a connection's track: the call has media (again)."""
        call.media = True
        self._resumed(call)

    def _resumed(self, call: ActiveCall) -> None:
        if call.resume_timer is not None:
            call.resume_timer.cancel()
            call.resume_timer = None
            log.info("call media is back")
        call.resuming = False

    def _give_up(self, call: ActiveCall) -> None:
        if self.active is call:
            log.warning("the phone did not reconnect within %.0f s; ending the call", resume.RESUME_WINDOW)
            asyncio.ensure_future(self.end(call.call_id, why=CONNECTION_LOST))

    async def _run_conversation(self, call: ActiveCall, inbound: Any, first_message: str) -> None:
        level = {"seconds": 0.0, "peak": 0.0}
        limit = self._timeout("max_call", MAX_CALL_SECONDS)
        warning = self._timeout("warning", CALL_WARNING_SECONDS)
        if 0 < warning < limit:
            loop = asyncio.get_running_loop()
            call.timers.append(loop.call_later(limit - warning, self._warn_ending, call))
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(call.conversation.run(_metered(inbound, level), first_message), limit)
        peak_db = 20 * math.log10(level["peak"]) if level["peak"] > 0 else -120.0
        log.info("inbound audio: %.1f s, peak %.0f dBFS", level["seconds"], peak_db)
        await self.end(call.call_id)

    async def _on_hangup(self, device: Device, body: dict) -> None:
        call_id = body.get("call_id")
        if isinstance(call_id, str) and self._starting.get(call_id) == device.id:
            self._hung_up.add(call_id)
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
        body = {"type": "caption", "call_id": call.call_id, "role": role, "text": text}
        if not await self._send(call.device.id, body):
            log.warning("caption (%s, %d chars) not sent; kept for a relay reconnect", role, len(text))
            call.unsent_captions.append(body)

    # ---- timeouts and relay reconnects during a call ----------------------

    def _timeout(self, name: str, default: float) -> float:
        value = getattr(self._timeouts, name)
        return default if value is None else value

    def _warn_ending(self, call: ActiveCall) -> None:
        if self.active is call and call.conversation is not None:
            log.info("call reaches its time limit soon; telling the owner")
            call.conversation.announce(CALL_ENDING_LINE)

    def _check_media(self, call: ActiveCall, waited: float) -> None:
        if self.active is call and not call.media:
            log.warning("no audio from the phone %.0f s after answering; ending the call", waited)
            asyncio.ensure_future(self.end(call.call_id))

    async def on_relay_ready(self) -> None:
        """The relay came back mid-call: what the phone may have missed goes again."""
        call = self.active
        if call is None:
            return
        for body in list(call.pending_approvals.values()):
            await self._send(call.device.id, body)
        while call.unsent_captions and self.active is call:
            if not await self._send(call.device.id, call.unsent_captions[0]):
                return
            call.unsent_captions.popleft()

    async def end(self, call_id: str, notify: bool = True, why: str | None = None) -> None:
        """`why`: sent in the `hangup` (e.g. `connection_lost`), for the phone to show."""
        call = self.active
        if call is None or call.call_id != call_id:
            return
        self.active = None
        for timer in (*call.timers, call.resume_timer):
            if timer is not None:
                timer.cancel()
        if call.inbound is not None:
            call.inbound.close()
        for future in call.approvals.values():
            if not future.done():
                future.set_result("deny")
        if call.task is not None and call.task is not asyncio.current_task():
            call.task.cancel()
        if call.pc is not None:
            await call.pc.close()
        if self._on_call_ended is not None and call.conversation is not None:
            self._on_call_ended(list(call.conversation.transcript))
        if notify:
            hangup = {"type": "hangup", "call_id": call_id}
            await self._send(call.device.id, {**hangup, "why": why} if why else hangup)
        log.info("call ended after %.0f s", time.monotonic() - call.started)

    async def _on_unpair(self, device: Device, body: dict) -> None:
        if self._on_unpair_request is not None:
            await self._on_unpair_request(device.id)

    async def forget_device(self, device_id: str) -> None:
        """A revoked device loses any ring slot and its active call immediately."""
        self.peers.forget(device_id)
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
        body = {
            "type": "approval_request",
            "call_id": call.call_id,
            "request_id": key,
            "command": request.command,
            "description": request.description,
            "choices": list(APPROVAL_CHOICES),
        }
        call.pending_approvals[key] = body
        await self._send(call.device.id, body)
        try:
            return await asyncio.wait_for(future, self._timeout("approval", APPROVAL_TIMEOUT))
        except TimeoutError:
            return "deny"
        finally:
            call.approvals.pop(key, None)
            call.pending_approvals.pop(key, None)

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

    async def _send(self, device_id: str, body: dict[str, Any]) -> bool:
        return await self._transport.live(device_id, body)
