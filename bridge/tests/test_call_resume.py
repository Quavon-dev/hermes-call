# SPDX-License-Identifier: MIT
"""C1: a call survives a network handover. The phone re-offers for the same call id; the bridge builds a
new peer connection and keeps the conversation. Only with phones that listed `call_resume`."""

import asyncio

import av
import numpy as np
import pytest
from aiortc.mediastreams import MediaStreamError

from hermescall_bridge import calls as calls_mod
from hermescall_bridge import resume as resume_mod
from hermescall_bridge.audio import SpeechTrack
from hermescall_bridge.calls import CallManager, CallTimeouts, new_call_id
from hermescall_bridge.resume import ForwardTrack, InboundAudio
from hermescall_bridge.state import State, new_device
from hermescall_common import wire

from .test_regressions import FakePc, PlainChannel


class Relay:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def request(self, message: dict, timeout: float = 15) -> dict:
        if message["t"] == "turn":
            return {"t": "turn", "urls": ["turn:127.0.0.1:3478?transport=udp"], "username": "u", "credential": "c"}
        return {"t": "ok"}

    async def send(self, message: dict) -> None:
        self.sent.append(message)

    def bodies(self, kind: str) -> list[dict]:
        return [m["data"] for m in self.sent if isinstance(m.get("data"), dict) and m["data"].get("type") == kind]


class FakeConversation:
    def __init__(self) -> None:
        self.blocks = 0
        self.transcript: list[tuple[str, str]] = []

    def use_device_stt(self) -> None:
        pass

    async def run(self, inbound, first_message: str = "") -> None:
        async for _ in inbound:
            self.blocks += 1


class FakeTrack:
    kind = "audio"

    def __init__(self) -> None:
        self.frames: asyncio.Queue = asyncio.Queue()

    async def recv(self):
        frame = await self.frames.get()
        if frame is None:
            raise MediaStreamError
        return frame


def frame() -> av.AudioFrame:
    pcm = np.zeros((1, 960), dtype=np.int16)
    out = av.AudioFrame.from_ndarray(pcm, format="s16", layout="mono")
    out.sample_rate = 48_000
    return out


class AiortcPc(FakePc):
    """Like aiortc: the remote track is announced inside `setRemoteDescription`, long before (or without)
    any audio arriving on it."""

    def __init__(self) -> None:
        super().__init__()
        self.track = FakeTrack()

    async def setRemoteDescription(self, description) -> None:
        self.handlers["track"](self.track)

    async def close(self) -> None:
        await super().close()
        await self.track.frames.put(None)  # aiortc ends the remote track with its connection


async def audio_flows(pc: AiortcPc) -> None:
    await pc.track.frames.put(frame())
    for _ in range(20):
        await asyncio.sleep(0)


@pytest.fixture
def setup(monkeypatch):
    pcs: list[AiortcPc] = []
    monkeypatch.setattr(calls_mod, "peer_connection", lambda turn, *_: pcs.append(AiortcPc()) or pcs[-1])
    conversations: list[FakeConversation] = []

    def factory(*args, **kwargs):
        conversations.append(FakeConversation())
        return conversations[-1]

    relay = Relay()
    device = new_device(wire.b64e(b"d" * 16), "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    other = new_device(wire.b64e(b"e" * 16), "ipad", wire.b64e(bytes(32)), wire.b64e(b"\x02" * 32))
    manager = CallManager(State(keys={}, devices={device.id: device, other.id: other}), relay, PlainChannel(), factory)
    return manager, relay, device, other, pcs, conversations


async def start(manager, device, pcs) -> str:
    call_id = new_call_id()
    await manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    await audio_flows(pcs[-1])
    return call_id


async def test_reoffer_for_the_active_call_swaps_the_peer_connection(setup) -> None:
    manager, relay, device, _, pcs, conversations = setup
    manager.peers.on_hello(device.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    call = manager.active
    await manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    assert manager.active is call, "the call (and its conversation) must survive the re-offer"
    assert len(pcs) == 2 and pcs[0].closed and not pcs[1].closed and call.pc is pcs[1]
    assert len(relay.bodies("answer")) == 2 and not relay.bodies("busy")
    assert len(conversations) == 1
    # A late state change of the old connection does not end the call.
    await pcs[0].handlers["connectionstatechange"]()
    pcs[0].connectionState = "closed"
    await pcs[0].handlers["connectionstatechange"]()
    assert manager.active is call


async def test_media_from_the_new_connection_feeds_the_same_conversation(setup) -> None:
    manager, relay, device, _, pcs, conversations = setup
    manager.peers.on_hello(device.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    assert manager.active.resuming is False
    pcs[0].connectionState = "failed"
    await pcs[0].handlers["connectionstatechange"]()
    assert manager.active is not None and manager.active.resuming
    await manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    assert manager.active.resuming, "a new connection is not media: the wait continues until audio arrives"
    await audio_flows(pcs[1])
    assert manager.active is not None and not manager.active.resuming
    assert len(conversations) == 1


async def test_without_the_cap_a_reoffer_is_busy_and_a_failure_ends_the_call(setup) -> None:
    manager, relay, device, _, pcs, _ = setup
    call_id = await start(manager, device, pcs)
    await manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    assert relay.bodies("busy") and len(pcs) == 1
    pcs[0].connectionState = "failed"
    await pcs[0].handlers["connectionstatechange"]()
    assert manager.active is None


async def test_no_reoffer_within_the_window_ends_the_call_with_a_reason(setup, monkeypatch) -> None:
    monkeypatch.setattr(resume_mod, "RESUME_WINDOW", 0.1)
    manager, relay, device, _, pcs, _ = setup
    manager.peers.on_hello(device.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    pcs[0].connectionState = "failed"
    await pcs[0].handlers["connectionstatechange"]()
    await asyncio.sleep(0.3)
    assert manager.active is None
    assert relay.bodies("hangup") == [{"type": "hangup", "call_id": call_id, "why": "connection_lost"}]


async def test_a_reoffer_that_never_brings_audio_also_gives_up(setup, monkeypatch) -> None:
    monkeypatch.setattr(resume_mod, "RESUME_WINDOW", 0.1)
    manager, relay, device, _, pcs, _ = setup
    manager.peers.on_hello(device.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    await manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    await asyncio.sleep(0.3)
    assert manager.active is None and relay.bodies("hangup")[0]["why"] == "connection_lost"


class SlowClosePc(AiortcPc):
    async def close(self) -> None:
        await asyncio.sleep(0.05)
        await super().close()


async def test_a_hangup_while_the_old_connection_closes_leaves_no_new_connection_open(setup, monkeypatch) -> None:
    manager, relay, device, _, pcs, _ = setup
    monkeypatch.setattr(calls_mod, "peer_connection", lambda turn, *_: pcs.append(SlowClosePc()) or pcs[-1])
    manager.peers.on_hello(device.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    reoffer = asyncio.ensure_future(manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"}))
    await asyncio.sleep(0.01)  # the old connection is closing
    await manager.on_e2e(device.id, {"type": "hangup", "call_id": call_id})
    await reoffer
    assert manager.active is None
    assert all(pc.closed for pc in pcs), [pc.closed for pc in pcs]
    assert len(relay.bodies("answer")) == 1, "no answer for a call that has ended"


async def test_a_track_without_audio_ends_the_call_after_the_media_timeout(setup) -> None:
    manager, relay, device, _, pcs, _ = setup
    manager._timeouts = CallTimeouts(media=0.1)
    await manager.on_e2e(device.id, {"type": "offer", "call_id": new_call_id(), "sdp": "v=0\r\n"})
    assert manager.active is not None
    await asyncio.sleep(0.3)
    assert manager.active is None and relay.bodies("hangup")


async def test_only_the_calling_phone_can_resume(setup) -> None:
    manager, relay, device, other, pcs, _ = setup
    for phone in (device, other):
        manager.peers.on_hello(phone.id, {"type": "hello", "v": 1, "caps": ["call_resume"]})
    call_id = await start(manager, device, pcs)
    call = manager.active
    await manager.on_e2e(other.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"})
    assert manager.active is call and call.pc is pcs[0] and len(pcs) == 1
    assert relay.bodies("busy")


async def test_inbound_audio_continues_on_the_next_track() -> None:
    inbound = InboundAudio(resumable=True)
    first, second = FakeTrack(), FakeTrack()
    inbound.attach(first)
    blocks = inbound.blocks()
    await first.frames.put(frame())
    assert len(await anext(blocks)) > 0
    await first.frames.put(None)  # the old connection closed
    waiting = asyncio.ensure_future(anext(blocks))
    await asyncio.sleep(0.05)
    assert not waiting.done(), "the conversation must wait for the next connection, not end"
    inbound.attach(second)
    await second.frames.put(frame())
    assert len(await asyncio.wait_for(waiting, 2)) > 0
    inbound.close()
    await second.frames.put(None)
    with pytest.raises(StopAsyncIteration):
        await anext(blocks)


async def test_inbound_audio_without_resume_ends_with_its_track() -> None:
    inbound = InboundAudio(resumable=False)
    track = FakeTrack()
    inbound.attach(track)
    await track.frames.put(None)
    with pytest.raises(StopAsyncIteration):
        await anext(inbound.blocks())


async def test_forward_track_leaves_the_speech_track_alive() -> None:
    speech = SpeechTrack()
    forward = ForwardTrack(speech)
    frame = await forward.recv()
    assert frame.samples == 960
    forward.stop()
    assert speech.readyState == "live"
    again = ForwardTrack(speech)
    assert (await again.recv()).pts == 960
