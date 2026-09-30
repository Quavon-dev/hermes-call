"""Relay clients: one-shot pairing and the long-lived authenticated session."""

import asyncio
import itertools
import logging
import random
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import aiohttp

from . import auth, pairing, sodium, tls, wire
from .codes import PairingInvite, format_authority
from .errors import CryptoError, ProtocolError

log = logging.getLogger(__name__)

RECV_TIMEOUT = 20.0
REQUEST_TIMEOUT = 15.0
MAX_BACKOFF = 30.0


@dataclass(frozen=True)
class RelayEndpoint:
    host: str
    port: int
    pin: str

    @property
    def authority(self) -> str:
        return format_authority(self.host, self.port)


async def recv(ws: aiohttp.ClientWebSocketResponse, timeout: float = RECV_TIMEOUT) -> dict[str, Any]:
    msg = await ws.receive(timeout=timeout)
    if msg.type != aiohttp.WSMsgType.TEXT:
        raise ProtocolError("relay closed the connection")
    message = wire.decode(msg.data)
    if message["t"] == "error":
        raise ProtocolError(f"relay error: {message.get('code', 'unknown')}")
    return message


async def expect(ws: aiohttp.ClientWebSocketResponse, kind: str, timeout: float = RECV_TIMEOUT) -> dict[str, Any]:
    message = await recv(ws, timeout)
    if message["t"] != kind:
        raise ProtocolError(f"unexpected relay message {message['t']}")
    return message


async def send(ws: aiohttp.ClientWebSocketResponse, message: dict[str, Any]) -> None:
    await ws.send_str(wire.encode(message))


async def pair_as_initiator(
    invite: PairingInvite,
    payload: dict[str, Any],
    final_type: str,
    timeout: float = 120.0,
    allow_self_signed: bool = False,
) -> tuple[dict[str, Any], dict[str, Any], str]:
    """Run the initiator side of a pairing (bridge→relay or device→bridge).

    Returns (final relay message, decrypted responder payload, pin bound into CPace).
    """
    async with aiohttp.ClientSession() as session:
        ws, pin = await tls.connect_first_contact(session, invite.host, invite.port, invite.pin, "/v1/pair", allow_self_signed)
        try:
            ctx = pairing.Context(invite.kind, invite.host, invite.port, pin)
            state, public = pairing.start(ctx, invite.code.secret)
            await send(ws, {"t": "join", "slot": invite.code.slot, "msg": wire.b64e(public)})
            first = await expect(ws, "cpace" if invite.kind == "relay" else "pair_msg", timeout)
            keys = pairing.finish(state, wire.b64d(first.get("msg") or first.get("data")))
            confirm = wire.b64e(pairing.seal_initiator(keys, payload))
            await send(ws, {"t": "confirm", "data": confirm} if invite.kind == "relay" else {"t": "pair_msg", "data": confirm})
            final = await expect(ws, final_type, timeout)
            try:
                result = pairing.open_responder(keys, wire.b64d(final["data"]))
            except CryptoError as exc:
                raise ProtocolError("pairing failed: wrong code or man-in-the-middle") from exc
            return final, result, pin
        finally:
            await ws.close()


Handler = Callable[[dict[str, Any]], Awaitable[None]]


class RelaySession:
    """Keeps one authenticated connection to the relay alive and multiplexes
    request/response (via `rid`) with unsolicited events."""

    def __init__(self, endpoint: RelayEndpoint, role: str, identity: str, sign_sk: bytes, on_event: Handler) -> None:
        self.endpoint = endpoint
        self.role = role
        self.identity = identity
        self._sign_sk = sign_sk
        self._on_event = on_event
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._pending: dict[int, asyncio.Future] = {}
        self._rids = itertools.count(1)
        self.connected = asyncio.Event()
        self._stopped = False
        self._event_tasks: set[asyncio.Task] = set()
        self.cert_fingerprint: bytes | None = None

    async def run(self) -> None:
        backoff = 1.0
        async with aiohttp.ClientSession() as session:
            while not self._stopped:
                try:
                    await self._session_once(session)
                    backoff = 1.0
                except (aiohttp.ClientError, ProtocolError, CryptoError, TimeoutError, OSError) as exc:
                    log.warning("relay connection lost: %s", exc.__class__.__name__)
                finally:
                    self._disconnect()
                if not self._stopped:
                    await asyncio.sleep(backoff + random.uniform(0, backoff / 2))  # noqa: S311
                    backoff = min(backoff * 2, MAX_BACKOFF)

    def stop(self) -> None:
        self._stopped = True
        if self._ws is not None:
            asyncio.ensure_future(self._ws.close())

    def _disconnect(self) -> None:
        self.connected.clear()
        self._ws = None
        for future in self._pending.values():
            if not future.done():
                future.set_exception(ProtocolError("relay disconnected"))
        self._pending.clear()

    async def _session_once(self, session: aiohttp.ClientSession) -> None:
        e = self.endpoint
        ws = await tls.connect(session, e.host, e.port, e.pin, "/v1/ws")
        if e.pin:
            self.cert_fingerprint = tls.cert_fingerprint(ws)
        try:
            challenge = await expect(ws, "challenge")
            nonce = wire.b64d(challenge.get("nonce"), length=auth.NONCE_BYTES)
            sig = auth.sign_auth(self._sign_sk, e.authority, self.role, self.identity, nonce)
            await send(ws, {"t": "auth", "role": self.role, "id": self.identity, "sig": wire.b64e(sig)})
            await expect(ws, "ready")
            self._ws = ws
            self.connected.set()
            log.info("connected to relay %s", e.authority)
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    break
                self._dispatch(wire.decode(msg.data))
        finally:
            await ws.close()

    def _dispatch(self, message: dict[str, Any]) -> None:
        rid = message.get("rid")
        future = self._pending.pop(rid, None) if isinstance(rid, int) else None
        if future is not None:
            if not future.done():
                future.set_result(message)
            return
        task = asyncio.ensure_future(self._handle_event(message))
        self._event_tasks.add(task)
        task.add_done_callback(self._event_tasks.discard)

    async def _handle_event(self, message: dict[str, Any]) -> None:
        try:
            await self._on_event(message)
        except Exception:
            log.exception("relay event handler failed for %s", message.get("t"))

    async def send(self, message: dict[str, Any]) -> None:
        if self._ws is None:
            raise ProtocolError("not connected to relay")
        await send(self._ws, message)

    async def request(self, message: dict[str, Any], timeout: float = REQUEST_TIMEOUT) -> dict[str, Any]:
        await asyncio.wait_for(self.connected.wait(), timeout)
        rid = next(self._rids)
        future = asyncio.get_running_loop().create_future()
        self._pending[rid] = future
        try:
            await self.send({**message, "rid": rid})
            reply = await asyncio.wait_for(future, timeout)
        finally:
            self._pending.pop(rid, None)
        if reply["t"] == "error":
            raise ProtocolError(f"relay error: {reply.get('code', 'unknown')}")
        return reply


def new_identity_keys() -> dict[str, str]:
    sign_pk, sign_sk = sodium.sign_keypair()
    box_pk, box_sk = sodium.box_keypair()
    return {
        "sign_pk": wire.b64e(sign_pk),
        "sign_sk": wire.b64e(sign_sk),
        "box_pk": wire.b64e(box_pk),
        "box_sk": wire.b64e(box_sk),
    }
