"""Revocation works while the relay is unreachable; expired pairing invitations are dropped."""

import asyncio
import time

from hermescall_bridge.devices import DeviceRegistry, Invitation
from hermescall_bridge.state import StateStore, new_device
from hermescall_common import codes, wire
from hermescall_common.errors import ProtocolError


class Relay:
    def __init__(self) -> None:
        self.connected = asyncio.Event()
        self.requests: list[dict] = []
        self.error: str | None = None

    async def request(self, message: dict, timeout: float = 15.0) -> dict:
        if not self.connected.is_set():
            raise TimeoutError
        if self.error:
            raise ProtocolError(f"relay error: {self.error}")
        self.requests.append(message)
        return {"t": "ok", "slot": "ABC", "ttl": 600}


def registry(tmp_path) -> tuple[DeviceRegistry, Relay, StateStore, str]:
    store = StateStore(tmp_path)
    state = store.load()
    state.relay = {"host": "relay.example", "port": 443, "pin": "", "bridge_id": "b"}
    device = new_device(wire.b64e(b"d" * 16), "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    state.devices[device.id] = device
    store.save(state)
    relay = Relay()
    return DeviceRegistry(state, store, relay), relay, store, device.id


async def test_revoke_while_the_relay_is_offline_is_local_at_once_and_sent_later(tmp_path) -> None:
    devices, relay, store, device_id = registry(tmp_path)
    started = time.monotonic()
    assert await devices.revoke(device_id) is True
    assert time.monotonic() - started < 1, "revoking must not wait for the relay"
    assert devices.list() == [] and store.load().devices == {}
    assert store.load_revocations() == [device_id]
    relay.connected.set()
    await devices.flush_revocations()
    assert relay.requests == [{"t": "revoke_device", "device_id": device_id}]
    assert store.load_revocations() == []


async def test_revocation_the_relay_rejects_stays_pending_but_unknown_device_counts_as_done(tmp_path) -> None:
    devices, relay, store, device_id = registry(tmp_path)
    relay.connected.set()
    relay.error = "rate_limited"
    await devices.revoke(device_id)
    assert store.load_revocations() == [device_id]
    relay.error = "unknown_device"
    await devices.flush_revocations()
    assert store.load_revocations() == []
    assert await devices.revoke(device_id) is False  # already gone


async def test_expired_invitations_are_garbage_collected(tmp_path) -> None:
    devices, relay, _, _ = registry(tmp_path)
    relay.connected.set()
    stale = Invitation(codes.new_code("OLD"), "old", time.monotonic() - 1)
    devices._invitations["OLD"] = stale
    assert devices.invitation("OLD") is None and stale.result.cancelled()
    invitation, _ = await devices.invite("new")
    assert devices.invitation("ABC") is invitation
