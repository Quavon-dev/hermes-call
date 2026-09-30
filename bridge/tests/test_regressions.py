"""Regression tests for bugs found in the roadmap audit (A1–A7)."""

import asyncio
import json
import socket
import threading
import time
from pathlib import Path

import httpx
import numpy as np
import pytest

from hermescall_bridge import calls as calls_mod
from hermescall_bridge import cli as cli_mod
from hermescall_bridge.audio import SpeechTrack
from hermescall_bridge.calls import CallManager, new_call_id
from hermescall_bridge.config import load
from hermescall_bridge.conversation import Conversation
from hermescall_bridge.daemon import build_bridge
from hermescall_bridge.hermes import TextDelta
from hermescall_bridge.state import State, StateStore, new_device
from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .conftest import CALL_TOKEN, FakeHermes, FakeTts
from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_units import drain

# ---- helpers -----------------------------------------------------------------


async def restart(h):
    """The bridge process restarts: same state directory, fresh in-memory services."""
    old = h.bridge
    old.relay.stop()
    store = StateStore(Path(old.devices._store.path).parent)
    state = store.load()

    async def transcribe(audio: np.ndarray) -> str:
        return "hello hermes"

    bridge = build_bridge(state, store, "t" * 43, h.hermes, h.tts, transcribe, CALL_TOKEN)
    task = asyncio.ensure_future(bridge.relay.run())
    await asyncio.wait_for(bridge.relay.connected.wait(), 10)
    h.bridge = bridge
    h.restarted = [*getattr(h, "restarted", []), task]
    return bridge


@pytest.fixture(autouse=True)
async def stop_restarted(h):
    yield
    h.bridge.relay.stop()
    for task in getattr(h, "restarted", []):
        task.cancel()


async def until(predicate, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.02)


# ---- A1: the adapter's cursor survives a bridge restart --------------------------


async def test_a1_cursor_from_before_a_restart_does_not_swallow_new_messages(h) -> None:
    device = await online_device(h)
    await device.send_chat("one")
    await next_of(device, "chat_ack")
    cursor, events = await h.bridge.chat.poll(0, 5)
    assert [e["text"] for e in events] == ["one"]
    bridge = await restart(h)
    await device.send_chat("two")
    await next_of(device, "chat_ack")
    # The adapter still holds the old cursor; the new message must not be popped as received.
    _, events = await bridge.chat.poll(cursor, 5)
    assert [e["text"] for e in events] == ["two"]


# ---- A2: hangup while the offer waits for TURN credentials ----------------------------


class FakePc:
    def __init__(self) -> None:
        self.closed = False
        self.handlers: dict = {}
        self.localDescription = None
        self.connectionState = "new"

    def addTrack(self, track) -> None:
        pass

    def on(self, name: str):
        def register(fn):
            self.handlers[name] = fn
            return fn

        return register

    async def setRemoteDescription(self, description) -> None:
        pass

    async def createAnswer(self):
        return type("Answer", (), {"sdp": "v=0\r\n", "type": "answer"})()

    async def setLocalDescription(self, description) -> None:
        self.localDescription = description

    async def close(self) -> None:
        self.closed = True


class SlowTurnRelay:
    def __init__(self) -> None:
        self.release = asyncio.Event()
        self.sent: list[dict] = []

    async def request(self, message: dict, timeout: float = 15) -> dict:
        if message["t"] == "turn":
            await self.release.wait()
            return {"t": "turn", "urls": ["turn:127.0.0.1:3478?transport=udp"], "username": "u", "credential": "c"}
        return {"t": "ok"}

    async def send(self, message: dict) -> None:
        self.sent.append(message)


class PlainChannel:
    def seal(self, device_id: str, box_key: bytes, body: dict, mid: str | None = None) -> dict:
        return body

    def open(self, device_id: str, box_key: bytes, data) -> dict:
        return data


def call_manager(relay) -> tuple[CallManager, object]:
    device = new_device(wire.b64e(b"d" * 16), "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    manager = CallManager(State(keys={}, devices={device.id: device}), relay, PlainChannel(), conversation_factory=None)
    return manager, device


async def test_a2_hangup_during_turn_fetch_ends_the_pending_call(monkeypatch) -> None:
    pcs: list[FakePc] = []
    monkeypatch.setattr(calls_mod, "peer_connection", lambda turn, *_: pcs.append(FakePc()) or pcs[-1])
    relay = SlowTurnRelay()
    manager, device = call_manager(relay)
    call_id = new_call_id()
    offer = asyncio.ensure_future(manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"}))
    await asyncio.sleep(0.05)
    await manager.on_e2e(device.id, {"type": "hangup", "call_id": call_id})
    relay.release.set()
    await asyncio.wait_for(offer, 5)
    assert manager.active is None, "the call the owner hung up on is still active (ghost call)"
    assert all(pc.closed for pc in pcs)
    assert not any(m.get("data", {}).get("type") == "answer" for m in relay.sent)


async def test_a2_hangup_for_another_call_id_does_not_cancel_the_offer(monkeypatch) -> None:
    monkeypatch.setattr(calls_mod, "peer_connection", lambda turn, *_: FakePc())
    relay = SlowTurnRelay()
    manager, device = call_manager(relay)
    call_id = new_call_id()
    offer = asyncio.ensure_future(manager.on_e2e(device.id, {"type": "offer", "call_id": call_id, "sdp": "v=0\r\n"}))
    await asyncio.sleep(0.05)
    await manager.on_e2e(device.id, {"type": "hangup", "call_id": new_call_id()})
    relay.release.set()
    await asyncio.wait_for(offer, 5)
    assert manager.active is not None and manager.active.call_id == call_id


# ---- A3: Hermes or Kokoro failing mid-turn is not silence -------------------------


class FailingHermes(FakeHermes):
    def __init__(self, after: int = 0) -> None:
        super().__init__()
        self.after = after

    async def turn(self, system: str, text: str, images=()):
        self.turns.append((system, text))
        for piece in ("Let me check. ",)[: self.after]:
            yield TextDelta(piece)
        request = httpx.Request("POST", "http://127.0.0.1:8642/v1/chat/completions")
        raise httpx.HTTPStatusError("boom", request=request, response=httpx.Response(502, request=request))


async def test_a3_hermes_error_mid_turn_speaks_a_fallback_line() -> None:
    tts, out = FakeTts(), SpeechTrack()
    conversation = Conversation(FailingHermes(), tts, None, out, None, agent_name="Atlas")
    player = drain(out)
    conversation._turn = asyncio.ensure_future(conversation._run_turn(None, time.monotonic(), "what's up?"))
    await asyncio.wait_for(asyncio.shield(conversation._turn), 5)
    player.cancel()
    assert tts.spoken == ["Sorry, I couldn't reach Atlas just now."]


class BrokenTts(FakeTts):
    async def synthesize(self, text: str):
        self.spoken.append(text)
        raise httpx.ConnectError("kokoro down")
        yield b""  # pragma: no cover


class CountingTrack(SpeechTrack):
    def __init__(self) -> None:
        super().__init__()
        self.enqueued = 0

    def enqueue_pcm(self, pcm: bytes, rate: int) -> None:
        self.enqueued += len(pcm)
        super().enqueue_pcm(pcm, rate)


async def test_a3_tts_error_is_not_silence() -> None:
    out = CountingTrack()
    tts = BrokenTts()
    conversation = Conversation(FakeHermes(), tts, None, out, None)
    player = drain(out)
    turn = asyncio.ensure_future(conversation._run_turn(None, time.monotonic(), "what's up?"))
    await asyncio.wait_for(turn, 5)
    player.cancel()
    assert out.enqueued > 0, "Kokoro failed and the owner hears nothing"
    assert len(tts.spoken) == 1, "after the first TTS failure the rest of the turn is not tried again"


# ---- A4: relay add --force while the daemon runs ----------------------------------


def test_a4_relay_add_force_refuses_while_the_daemon_runs(tmp_path, monkeypatch) -> None:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    port = listener.getsockname()[1]
    (tmp_path / "bridge.toml").write_text(f'state_dir = "{tmp_path / "state"}"\n[api]\nport = {port}\n')
    config = load(tmp_path / "bridge.toml")
    store = StateStore(config.state_dir)
    state = store.load()
    state.relay = {"host": "old.example", "port": 443, "pin": "", "bridge_id": "old"}
    store.save(state)
    paired: list = []

    async def fake_pair(*args, **kwargs):
        paired.append(args)
        return {}, {"bridge_id": "new"}, ""

    monkeypatch.setattr(cli_mod, "pair_as_initiator", fake_pair)
    try:
        code = cli_mod.relay_add(config, ["hermescall://pair?v=1&k=relay&r=new.example&c=ABC0123456789"], force=True)
    finally:
        listener.close()
    assert code != 0 and paired == []
    assert json.loads(store.path.read_text())["relay"]["bridge_id"] == "old"


def test_a4_relay_add_force_works_when_the_daemon_is_stopped(tmp_path, monkeypatch) -> None:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()  # nothing listens there any more
    (tmp_path / "bridge.toml").write_text(f'state_dir = "{tmp_path / "state"}"\n[api]\nport = {port}\n')
    config = load(tmp_path / "bridge.toml")
    store = StateStore(config.state_dir)
    state = store.load()
    state.relay = {"host": "old.example", "port": 443, "pin": "", "bridge_id": "old"}
    store.save(state)

    async def fake_pair(*args, **kwargs):
        return {}, {"bridge_id": "new"}, ""

    monkeypatch.setattr(cli_mod, "pair_as_initiator", fake_pair)
    assert cli_mod.relay_add(config, ["hermescall://pair?v=1&k=relay&r=new.example&c=ABC0123456789"], force=True) == 0
    assert json.loads(store.path.read_text())["relay"]["bridge_id"] == "new"


# ---- A5: an acknowledged owner message survives a restart ---------------------------


async def test_a5_delivered_message_survives_a_restart_before_hermes_polled(h) -> None:
    device = await online_device(h)
    message_id = await device.send_chat("remember the milk")
    ack = await next_of(device, "chat_ack")
    assert ack["id"] == message_id and ack["state"] == "delivered"
    bridge = await restart(h)
    _, events = await bridge.chat.poll(0, 5)
    assert [e["id"] for e in events] == [message_id]


async def test_a5_resent_message_after_restart_is_delivered_once(h) -> None:
    device = await online_device(h)
    body = {"type": "chat", "id": wire.b64e(b"m" * 16), "text": "once"}
    await device.send(body, mail=True)
    await next_of(device, "chat_ack")
    cursor, events = await h.bridge.chat.poll(0, 5)
    assert len(events) == 1
    await h.bridge.chat.poll(cursor, 0)  # Hermes has it: acked
    bridge = await restart(h)
    await device.send(body, mail=True)  # the phone did not see the ack and resends (new envelope, same id)
    assert (await next_of(device, "chat_ack"))["state"] == "delivered"
    _, events = await bridge.chat.poll(0, 1)
    assert events == []


# ---- A6: outbound chat while the relay is unreachable ---------------------------------


async def test_a6_agent_message_is_delivered_after_the_relay_comes_back(h, monkeypatch) -> None:
    device = await online_device(h)
    real = h.bridge.relay.request
    down = {"on": True}

    async def flaky(message: dict, timeout: float = 15.0) -> dict:
        if down["on"] and message["t"] == "mail":
            raise ProtocolError("relay disconnected")
        return await real(message, timeout)

    monkeypatch.setattr(h.bridge.relay, "request", flaky)
    await h.bridge.chat.send_text("the backup finished")
    down["on"] = False
    message = await next_of(device, "chat", timeout=15)
    assert message["text"] == "the backup finished"


# ---- A7: voice notes do not hold up live-call speech recognition ------------------------


class SlowModel:
    """Takes 10 ms per second of audio; records the order of work."""

    def __init__(self, *args, **kwargs) -> None:
        self.lock = threading.Lock()
        self.log: list[int] = []

    def transcribe(self, audio, **kwargs):
        with self.lock:
            self.log.append(len(audio))
        time.sleep(len(audio) / 16_000 * 0.01)
        return iter([type("Segment", (), {"text": "words", "no_speech_prob": 0.0})()]), None


async def test_a7_live_call_utterance_is_not_queued_behind_a_long_voice_note(monkeypatch) -> None:
    from hermescall_bridge import stt

    monkeypatch.setattr(stt, "WhisperModel", SlowModel)
    transcriber = stt.Transcriber("model", 1)
    voice_note = getattr(transcriber, "transcribe_background", transcriber.transcribe)
    long_note = asyncio.ensure_future(voice_note(np.zeros(300 * 16_000, dtype=np.float32)))
    await asyncio.sleep(0.05)
    started = time.monotonic()
    await transcriber.transcribe(np.zeros(2 * 16_000, dtype=np.float32))
    live_wait = time.monotonic() - started
    await long_note
    assert live_wait < 1.0, f"live utterance waited {live_wait:.1f} s behind a voice note"
