"""Device pairing (bridge = CPace responder, the relay only forwards) and revocation."""

import asyncio
import logging
import time
from dataclasses import dataclass, field

from hermescall_common import codes, pairing, wire
from hermescall_common.client import RelaySession
from hermescall_common.cpace import SharedKeys
from hermescall_common.errors import CryptoError, ProtocolError

from .state import Device, State, StateStore, new_device

log = logging.getLogger(__name__)

# Enforced here, not only at the relay: a malicious relay must not get more guesses at the code.
MAX_ATTEMPTS = 3


@dataclass
class Invitation:
    code: codes.Code
    name: str
    expires: float
    attempts: int = 0
    result: asyncio.Future = field(default_factory=lambda: asyncio.get_running_loop().create_future())


@dataclass
class Handshake:
    slot: str
    keys: SharedKeys


class DeviceRegistry:
    def __init__(self, state: State, store: StateStore, relay: RelaySession, agent_name: str = "Hermes") -> None:
        self._agent_name = agent_name
        self._state = state
        self._store = store
        self._relay = relay
        self._invitations: dict[str, Invitation] = {}
        self._handshakes: dict[str, Handshake] = {}

    def _ctx(self) -> pairing.Context:
        e = self._state.endpoint
        return pairing.Context("device", e.host, e.port, e.pin)

    async def invite(self, name: str) -> tuple[Invitation, codes.PairingInvite]:
        opened = await self._relay.request({"t": "open_slot"})
        slot = opened["slot"]
        invitation = Invitation(codes.new_code(slot), name, time.monotonic() + opened.get("ttl", 600))
        self._invitations[slot] = invitation
        e = self._state.endpoint
        return invitation, codes.PairingInvite("device", e.host, e.port, e.pin, invitation.code)

    def invitation(self, slot: str) -> Invitation | None:
        return self._invitations.get(slot)

    async def on_pair_join(self, message: dict) -> None:
        conn, slot = message.get("conn"), message.get("slot")
        invitation = self._invitations.get(slot) if isinstance(slot, str) else None
        busy = any(h.slot == slot for h in self._handshakes.values())
        if (
            not isinstance(conn, str)
            or invitation is None
            or invitation.expires < time.monotonic()
            or invitation.attempts >= MAX_ATTEMPTS
            or busy
        ):
            await self._relay.send({"t": "pair_done", "conn": conn, "ok": False})
            return
        invitation.attempts += 1
        response, keys = pairing.respond(self._ctx(), invitation.code.secret, wire.b64d(message.get("msg"), length=48))
        self._handshakes[conn] = Handshake(slot, keys)
        await self._relay.send({"t": "pair_msg", "conn": conn, "data": wire.b64e(response)})

    async def on_pair_msg(self, message: dict) -> None:
        conn = message.get("conn")
        handshake = self._handshakes.pop(conn, None)
        if handshake is None:
            return
        invitation = self._invitations.get(handshake.slot)
        try:
            payload = pairing.open_initiator(handshake.keys, wire.b64d(message.get("data"), max_length=4096))
            sign_pk, box_pk = payload.get("sign_pk"), payload.get("box_pk")
            wire.b64d(sign_pk, length=32)
            wire.b64d(box_pk, length=32)
        except (CryptoError, ProtocolError, ValueError):
            log.warning("device pairing attempt failed (wrong code or tampering)")
            await self._relay.send({"t": "pair_done", "conn": conn, "ok": False})
            await self._retire_if_exhausted(handshake.slot)
            return
        if invitation is None:
            await self._relay.send({"t": "pair_done", "conn": conn, "ok": False})
            return
        registered = await self._relay.request({"t": "pair_done", "conn": conn, "ok": True, "sign_pk": sign_pk})
        device = new_device(registered["device_id"], str(payload.get("name") or invitation.name), sign_pk, box_pk)
        self._state.devices[device.id] = device
        self._store.save(self._state)
        e = self._state.endpoint
        final = pairing.seal_responder(
            handshake.keys,
            {
                "device_id": device.id,
                "bridge_id": self._state.bridge_id,
                "bridge_sign_pk": self._state.keys["sign_pk"],
                "bridge_box_pk": self._state.keys["box_pk"],
                "bridge_name": self._agent_name,
                "relay": {"host": e.host, "port": e.port, "pin": e.pin},
            },
        )
        await self._relay.request({"t": "pair_final", "conn": conn, "data": wire.b64e(final)})
        self._invitations.pop(handshake.slot, None)
        if not invitation.result.done():
            invitation.result.set_result(device)
        log.info("device paired: %s", device.id[:6])

    async def on_pair_abort(self, message: dict) -> None:
        conn = message.get("conn")
        handshake = self._handshakes.pop(conn, None) if isinstance(conn, str) else None
        if handshake is not None:
            await self._retire_if_exhausted(handshake.slot)

    async def _retire_if_exhausted(self, slot: str) -> None:
        invitation = self._invitations.get(slot)
        if invitation is None or invitation.attempts < MAX_ATTEMPTS:
            return
        del self._invitations[slot]
        try:
            await self._relay.request({"t": "close_slot", "slot": slot})
        except ProtocolError as exc:
            log.info("closing pairing slot failed: %s", exc)

    async def revoke(self, device_id: str) -> bool:
        if device_id not in self._state.devices:
            return False
        try:
            await self._relay.request({"t": "revoke_device", "device_id": device_id})
        except ProtocolError as exc:
            if "unknown_device" not in str(exc):
                raise
        del self._state.devices[device_id]
        self._store.save(self._state)
        log.info("device revoked: %s", device_id[:6])
        return True

    def list(self) -> list[Device]:
        return sorted(self._state.devices.values(), key=lambda d: d.created)
