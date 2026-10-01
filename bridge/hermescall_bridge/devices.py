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
        # revoke() and flush_revocations() read-modify-write revocations.json: one at a time
        self._revocations = asyncio.Lock()
        revoked = [d for d in store.load_revocations() if d in state.devices]
        if revoked:  # a revoke that crashed before state.json was written
            for device_id in revoked:
                del state.devices[device_id]
            store.save(state)
            log.info("%d revoked device(s) dropped from state.json", len(revoked))

    def _ctx(self) -> pairing.Context:
        e = self._state.endpoint
        return pairing.Context("device", e.host, e.port, e.pin)

    def _gc_invitations(self) -> None:
        """Expired invitations go (the relay closes their slots itself after their ttl)."""
        now = time.monotonic()
        for slot in [s for s, inv in self._invitations.items() if inv.expires < now]:
            invitation = self._invitations.pop(slot)
            if not invitation.result.done():
                invitation.result.cancel()

    async def invite(self, name: str) -> tuple[Invitation, codes.PairingInvite]:
        self._gc_invitations()
        opened = await self._relay.request({"t": "open_slot"})
        slot = opened["slot"]
        invitation = Invitation(codes.new_code(slot), name, time.monotonic() + opened.get("ttl", 600))
        self._invitations[slot] = invitation
        e = self._state.endpoint
        return invitation, codes.PairingInvite("device", e.host, e.port, e.pin, invitation.code)

    def invitation(self, slot: str) -> Invitation | None:
        self._gc_invitations()
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
        try:
            registered = await self._relay.request({"t": "pair_done", "conn": conn, "ok": True, "sign_pk": sign_pk})
        except ProtocolError as exc:
            # e.g. `too_many_devices`: the relay refused to register another phone for this bridge
            log.warning("device pairing refused by the relay: %s", exc)
            return
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
        """Local first: the phone is forgotten here at once (its messages are dropped from now on),
        the relay is told now or, if it cannot be reached, after it reconnects."""
        if device_id not in self._state.devices:
            return False
        del self._state.devices[device_id]
        async with self._revocations:
            # The pending revocation is on disk before state.json forgets the phone: a crash in between
            # still tells the relay (and the restart drops the phone, see __init__).
            self._store.save_revocations(sorted({*self._store.load_revocations(), device_id}))
        self._store.save(self._state)
        log.info("device revoked: %s", device_id[:6])
        await self.flush_revocations()
        return True

    async def flush_revocations(self) -> None:
        """Tells the relay about revocations it has not confirmed yet (also after every reconnect)."""
        async with self._revocations:
            await self._flush_revocations()

    async def _flush_revocations(self) -> None:
        pending = self._store.load_revocations()
        if pending and not self._relay.connected.is_set():
            log.info("relay offline: %d revocation(s) are sent after it reconnects", len(pending))
            return
        done: set[str] = set()
        for device_id in pending:
            try:
                await self._relay.request({"t": "revoke_device", "device_id": device_id})
            except ProtocolError as exc:
                if "unknown_device" not in str(exc):
                    log.warning("relay not told about revoked device %s yet (%s); retrying after reconnect", device_id[:6], exc)
                    continue
            except (TimeoutError, ConnectionError, RuntimeError):
                log.warning("relay unreachable; revocation of %s is sent after it reconnects", device_id[:6])
                continue
            done.add(device_id)
        if done:
            self._store.save_revocations([d for d in pending if d not in done])

    def list(self) -> list[Device]:
        return sorted(self._state.devices.values(), key=lambda d: d.created)
