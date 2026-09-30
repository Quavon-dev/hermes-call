import asyncio
import json
import stat

import pytest
from aiohttp import ClientSession

from hermescall_bridge.calls import new_call_id
from hermescall_common import codes, wire
from hermescall_common.errors import ProtocolError
from hermescall_testclient import cli as testclient

from .conftest import API_TOKEN


async def api(h, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    app_runner_port = h.api_port
    async with ClientSession() as session:
        async with session.request(
            method, f"http://127.0.0.1:{app_runner_port}{path}", json=body, headers={"Authorization": f"Bearer {API_TOKEN}"}
        ) as response:
            return response.status, await response.json(content_type=None)


@pytest.fixture
async def h(harness, tmp_path, monkeypatch):
    from aiohttp import web

    runner = web.AppRunner(harness.bridge.app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    harness.api_port = site._server.sockets[0].getsockname()[1]
    monkeypatch.setattr(testclient, "STATE", tmp_path / "client" / "state.json")
    yield harness
    await runner.cleanup()


async def pair_device(h, name: str = "Test phone") -> testclient.Device:
    status, offer = await api(h, "POST", "/v1/devices/pairing", {"name": name})
    assert status == 200 and len(offer["code"]) == 9
    host = f"127.0.0.1:{h.port}"
    await testclient.pair([host, offer["code"]], name, trust_self_signed=True)
    return testclient.Device(testclient.load_state(), approve="deny")


async def connect(device: testclient.Device) -> asyncio.Task:
    task = asyncio.ensure_future(device.session.run())
    await asyncio.wait_for(device.session.connected.wait(), 10)
    return task


async def test_api_requires_token(h) -> None:
    async with ClientSession() as session:
        async with session.get(f"http://127.0.0.1:{h.api_port}/v1/status") as response:
            assert response.status == 401
        async with session.get(f"http://127.0.0.1:{h.api_port}/v1/status", headers={"Authorization": "Bearer wrong"}) as response:
            assert response.status == 401


async def test_device_pairing_with_typed_code_and_tofu_pin(h) -> None:
    device = await pair_device(h)
    state = testclient.load_state()
    assert state["relay"]["pin"] == h.relay.config.tls_pin
    assert state["bridge"]["bridge_name"] == "Hermes"
    assert stat.S_IMODE(testclient.STATE.stat().st_mode) == 0o600
    _, listed = await api(h, "GET", "/v1/devices")
    assert [d["id"] for d in listed["devices"]] == [device.state["device_id"]]
    assert h.relay.store.device(device.state["device_id"]).bridge_id == h.bridge.relay.identity


async def test_self_signed_relay_is_never_trusted_silently(h) -> None:
    from hermescall_common.errors import SelfSignedRelay

    _, offer = await api(h, "POST", "/v1/devices/pairing", {"name": "x"})
    with pytest.raises(SelfSignedRelay) as refused:
        await testclient.pair([f"127.0.0.1:{h.port}", offer["code"]], "phone")
    assert refused.value.pin == h.relay.config.tls_pin
    _, listed = await api(h, "GET", "/v1/devices")
    assert listed["devices"] == []


async def test_wrong_code_does_not_pair(h) -> None:
    _, offer = await api(h, "POST", "/v1/devices/pairing", {"name": "x"})
    wrong = offer["code"][:4] + ("A" if offer["code"][4] != "A" else "B") + offer["code"][5:]
    with pytest.raises(ProtocolError):
        await testclient.pair([f"127.0.0.1:{h.port}", wrong], "attacker", trust_self_signed=True)
    _, listed = await api(h, "GET", "/v1/devices")
    assert listed["devices"] == []


async def test_ring_push_invite_and_decline(h) -> None:
    device = await pair_device(h)
    task = await connect(device)
    try:
        ring = asyncio.ensure_future(api(h, "POST", "/v1/calls", {"reason": "backup done", "first_message": "Hi, Hermes here."}))
        invite = await asyncio.wait_for(device.inbox.get(), 10)
        assert invite["type"] == "invite" and invite["reason"] == "backup done"
        await device.send({"type": "invite_query", "call_id": invite["call_id"]})
        assert (await asyncio.wait_for(device.inbox.get(), 10))["type"] == "invite"
        await device.send({"type": "decline", "call_id": invite["call_id"]})
        status, result = await asyncio.wait_for(ring, 10)
        assert status == 200 and result == {"status": "declined", "call_id": invite["call_id"], "messaged": True}
    finally:
        device.session.stop()
        task.cancel()


async def test_invite_query_for_unknown_call_is_cancelled(h) -> None:
    device = await pair_device(h)
    task = await connect(device)
    try:
        call_id = new_call_id()
        await device.send({"type": "invite_query", "call_id": call_id})
        reply = await asyncio.wait_for(device.inbox.get(), 10)
        assert reply == {**reply, "type": "cancel", "call_id": call_id, "why": "unknown_call"}
    finally:
        device.session.stop()
        task.cancel()


async def test_ring_validation(h) -> None:
    status, _ = await api(h, "POST", "/v1/calls", {"reason": "x", "first_message": ""})
    assert status == 400
    status, _ = await api(h, "POST", "/v1/calls", {"reason": "x" * 501, "first_message": "hi"})
    assert status == 400
    status, result = await api(h, "POST", "/v1/calls", {"reason": "x", "first_message": "hi"})
    assert result == {"status": "no_devices"}


async def test_revoke_removes_device_everywhere(h) -> None:
    device = await pair_device(h)
    device_id = device.state["device_id"]
    status, _ = await api(h, "DELETE", f"/v1/devices/{device_id}")
    assert status == 200
    assert h.relay.store.device(device_id) is None
    assert device_id not in h.bridge.devices._state.devices
    stored = json.loads((h.bridge.devices._store.path).read_text())
    assert stored["devices"] == []


async def test_forged_message_from_other_device_is_ignored(h) -> None:
    alice = await pair_device(h, "alice")
    alice_state = testclient.load_state()
    mallory = await pair_device(h, "mallory")
    task = await connect(mallory)
    try:
        ring = asyncio.ensure_future(api(h, "POST", "/v1/calls", {"first_message": "hi", "device": alice_state["device_id"]}))
        await asyncio.sleep(0.5)
        call_id = next(iter(h.bridge.calls._rings))
        await mallory.send({"type": "decline", "call_id": call_id})
        await asyncio.sleep(0.3)
        assert not ring.done()
        h.bridge.calls._rings[call_id].outcome.set_result("declined")
        await ring
    finally:
        mallory.session.stop()
        task.cancel()
    assert alice is not None


def test_pairing_link_kinds_are_enforced() -> None:
    invite = codes.PairingInvite("device", "relay.example.com", 443, "", codes.new_code("ABC")).to_uri()
    from hermescall_bridge.cli import _parse_invite

    with pytest.raises(ProtocolError):
        _parse_invite([invite])


async def test_revoking_a_ringing_device_ends_the_ring(h) -> None:
    device = await pair_device(h)
    task = await connect(device)
    try:
        ring = asyncio.ensure_future(api(h, "POST", "/v1/calls", {"first_message": "hi"}))
        await asyncio.wait_for(device.inbox.get(), 10)
        await api(h, "DELETE", f"/v1/devices/{device.state['device_id']}")
        _, result = await asyncio.wait_for(ring, 10)
        assert result["status"] == "declined"
    finally:
        device.session.stop()
        task.cancel()


async def test_revoking_the_device_in_a_call_hangs_up() -> None:
    from hermescall_bridge.calls import ActiveCall, CallManager
    from hermescall_bridge.state import State, new_device

    class FakePc:
        closed = False

        async def close(self) -> None:
            self.closed = True

    device = new_device("dev1", "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    manager = CallManager(State(keys={}, devices={"dev1": device}), relay=None, channel=None, conversation_factory=None)
    manager.active = ActiveCall("call1", device, FakePc())
    pc = manager.active.pc
    await manager.forget_device("dev1")
    assert manager.active is None and pc.closed


async def test_bad_offer_from_one_device_does_not_cancel_the_ring_for_others(h) -> None:
    alice = await pair_device(h, "alice")
    bob = await pair_device(h, "bob")
    tasks = [await connect(alice), await connect(bob)]
    try:
        ring = asyncio.ensure_future(api(h, "POST", "/v1/calls", {"first_message": "hi"}))
        invite = await asyncio.wait_for(alice.inbox.get(), 10)
        await asyncio.wait_for(bob.inbox.get(), 10)
        await alice.send({"type": "offer", "call_id": invite["call_id"], "sdp": "v=0\r\ngarbage"})
        await asyncio.sleep(1.0)
        assert not ring.done() and h.bridge.calls.active is None
        assert bob.inbox.empty()
        for device in (alice, bob):
            await device.send({"type": "decline", "call_id": invite["call_id"]})
        _, result = await asyncio.wait_for(ring, 10)
        assert result["status"] == "declined"
    finally:
        for device, task in zip((alice, bob), tasks, strict=True):
            device.session.stop()
            task.cancel()


async def test_device_can_unpair_itself(h) -> None:
    device = await pair_device(h)
    device_id = device.state["device_id"]
    task = await connect(device)
    try:
        await device.send({"type": "unpair"})
        for _ in range(50):
            if device_id not in h.bridge.devices._state.devices:
                break
            await asyncio.sleep(0.1)
        assert device_id not in h.bridge.devices._state.devices
        assert h.relay.store.device(device_id) is None
    finally:
        device.session.stop()
        task.cancel()


async def test_new_offer_from_same_device_replaces_stale_call() -> None:
    from hermescall_bridge.calls import ActiveCall, CallManager
    from hermescall_bridge.state import State, new_device

    class FakePc:
        closed = False

        async def close(self) -> None:
            self.closed = True

    device = new_device("dev1", "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    manager = CallManager(State(keys={}, devices={"dev1": device}), relay=None, channel=None, conversation_factory=None)
    stale = ActiveCall("old-call", device, FakePc())
    manager.active = stale
    started = []

    async def fake_start(device, call_id, sdp, ring, device_stt):
        started.append(call_id)

    manager._start_call = fake_start
    await manager._on_offer(device, {"call_id": wire.b64e(bytes(16)), "sdp": "v=0"})
    assert stale.pc.closed and started == [wire.b64e(bytes(16))]


async def test_interrupt_only_from_the_call_device_with_matching_call_id(h) -> None:
    from hermescall_bridge.calls import ActiveCall

    alice = await pair_device(h, "alice")
    alice_id = alice.state["device_id"]
    mallory = await pair_device(h, "mallory")

    class FakeConversation:
        interrupts = 0

        def interrupt(self) -> None:
            self.interrupts += 1

    call_id = new_call_id()
    conversation = FakeConversation()
    h.bridge.calls.active = ActiveCall(call_id, h.bridge.calls._state.devices[alice_id], pc=None, conversation=conversation)
    tasks = [await connect(alice), await connect(mallory)]
    try:
        await mallory.send({"type": "interrupt", "call_id": call_id})
        await alice.send({"type": "interrupt", "call_id": new_call_id()})
        await alice.send({"type": "interrupt"})
        await asyncio.sleep(0.5)
        assert conversation.interrupts == 0
        await alice.send({"type": "interrupt", "call_id": call_id})
        for _ in range(50):
            if conversation.interrupts:
                break
            await asyncio.sleep(0.1)
        assert conversation.interrupts == 1
    finally:
        h.bridge.calls.active = None
        for device, task in zip((alice, mallory), tasks, strict=True):
            device.session.stop()
            task.cancel()
