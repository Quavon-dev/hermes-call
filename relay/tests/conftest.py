from dataclasses import dataclass, field
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient

from hermescall_common import auth, codes, pairing, sodium, wire
from hermescall_relay.config import Config
from hermescall_relay.push import PushResult
from hermescall_relay.server import Relay
from hermescall_relay.store import Store

HOST = "relay.test"


@dataclass
class FakePush:
    sent: list[tuple[str, str, str]] = field(default_factory=list)
    alerts: list[tuple[str, str, str | None]] = field(default_factory=list)
    invalid: set[str] = field(default_factory=set)
    live: list[tuple[str, str, str, dict]] = field(default_factory=list)

    async def send_voip(self, token: str, env: str, call_id: str) -> PushResult:
        self.sent.append((token, env, call_id))
        return PushResult.INVALID_TOKEN if token in self.invalid else PushResult.OK

    async def send_alert(self, token: str, env: str, ciphertext: str | None) -> PushResult:
        self.alerts.append((token, env, ciphertext))
        return PushResult.INVALID_TOKEN if token in self.invalid else PushResult.OK

    async def send_live_activity(self, token: str, env: str, event: str, content_state: dict) -> PushResult:
        self.live.append((token, env, event, content_state))
        return PushResult.INVALID_TOKEN if token in self.invalid else PushResult.OK

    async def close(self) -> None:
        pass


def make_config(tmp_path: Path) -> Config:
    return Config(
        host=HOST,
        port=443,
        tls_pin="",
        listen_host="127.0.0.1",
        listen_port=0,
        db_path=tmp_path / "relay.db",
        trust_proxy=True,
        turn_urls=("turn:relay.test:3478?transport=udp",),
        turn_ttl=600,
        apns=None,
    )


@pytest.fixture
def push() -> FakePush:
    return FakePush()


@pytest.fixture
def relay(tmp_path: Path, push: FakePush) -> Relay:
    config = make_config(tmp_path)
    return Relay(config, Store(config.db_path), push, b"turn-secret")


@pytest.fixture
async def client(aiohttp_client, relay: Relay) -> TestClient:
    return await aiohttp_client(relay.app())


@dataclass
class Identity:
    id: str
    sign_pk: bytes
    sign_sk: bytes


async def recv(ws) -> dict:
    return wire.decode((await ws.receive(timeout=5)).data)


async def recv_type(ws, kind: str) -> dict:
    while True:
        message = await recv(ws)
        if message["t"] == kind:
            return message


async def send(ws, message: dict) -> None:
    await ws.send_str(wire.encode(message))


async def pair_bridge(client: TestClient, code: codes.Code, host: str = HOST) -> Identity:
    pk, sk = sodium.sign_keypair()
    ctx = pairing.Context("relay", host, 443, "")
    state, public = pairing.start(ctx, code.secret)
    async with client.ws_connect("/v1/pair") as ws:
        await send(ws, {"t": "join", "slot": code.slot, "msg": wire.b64e(public)})
        reply = await recv(ws)
        if reply["t"] != "cpace":
            raise RuntimeError(reply)
        keys = pairing.finish(state, wire.b64d(reply["msg"]))
        await send(ws, {"t": "confirm", "data": wire.b64e(pairing.seal_initiator(keys, {"sign_pk": wire.b64e(pk)}))})
        reply = await recv(ws)
        if reply["t"] != "paired":
            raise RuntimeError(reply)
        payload = pairing.open_responder(keys, wire.b64d(reply["data"]))
    return Identity(payload["bridge_id"], pk, sk)


async def connect(client: TestClient, role: str, ident: Identity):
    ws = await client.ws_connect("/v1/ws")
    challenge = await recv(ws)
    sig = auth.sign_auth(ident.sign_sk, HOST, role, ident.id, wire.b64d(challenge["nonce"]))
    await send(ws, {"t": "auth", "role": role, "id": ident.id, "sig": wire.b64e(sig)})
    reply = await recv(ws)
    if reply["t"] != "ready":
        await ws.close()
        raise RuntimeError(reply)
    return ws


async def request(ws, message: dict) -> dict:
    await send(ws, message)
    while True:
        reply = await recv(ws)
        if reply["t"] != "presence":
            return reply


async def pair_device(client: TestClient, bridge_ws, secret: str = "Q4M9P", device_secret: str | None = None) -> Identity:
    """Runs both sides of device pairing: the test plays bridge and iPhone."""
    slot = (await request(bridge_ws, {"t": "open_slot"}))["slot"]
    ctx = pairing.Context("device", HOST, 443, "")
    pk, sk = sodium.sign_keypair()
    state, public = pairing.start(ctx, device_secret or secret)
    async with client.ws_connect("/v1/pair") as dev:
        await send(dev, {"t": "join", "slot": slot, "msg": wire.b64e(public)})
        join = await recv_type(bridge_ws, "pair_join")
        response, bridge_keys = pairing.respond(ctx, secret, wire.b64d(join["msg"]))
        await send(bridge_ws, {"t": "pair_msg", "conn": join["conn"], "data": wire.b64e(response)})
        device_keys = pairing.finish(state, wire.b64d((await recv(dev))["data"]))
        await send(dev, {"t": "pair_msg", "data": wire.b64e(pairing.seal_initiator(device_keys, {"sign_pk": wire.b64e(pk)}))})
        confirm = await recv_type(bridge_ws, "pair_msg")
        try:
            payload = pairing.open_initiator(bridge_keys, wire.b64d(confirm["data"]))
        except Exception:
            await send(bridge_ws, {"t": "pair_done", "conn": join["conn"], "ok": False})
            raise
        registered = await request(bridge_ws, {"t": "pair_done", "conn": join["conn"], "ok": True, "sign_pk": payload["sign_pk"]})
        sealed = pairing.seal_responder(bridge_keys, {"device_id": registered["device_id"]})
        await request(bridge_ws, {"t": "pair_final", "conn": join["conn"], "data": wire.b64e(sealed)})
        final = await recv(dev)
        assert pairing.open_responder(device_keys, wire.b64d(final["data"]))["device_id"] == final["device_id"]
    return Identity(final["device_id"], pk, sk)
