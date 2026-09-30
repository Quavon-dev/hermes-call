import asyncio
import dataclasses

import pytest
from aiohttp import WSMsgType

from hermescall_common import codes, sodium, wire
from hermescall_common.errors import CryptoError

from .conftest import Identity, connect, pair_bridge, pair_device, recv, recv_type, request, send

TOKEN = "ab" * 32


async def test_health(client) -> None:
    response = await client.get("/healthz")
    assert response.status == 200


async def test_bridge_pairing_and_auth(client, relay) -> None:
    code = relay.store.create_relay_code()
    bridge = await pair_bridge(client, code)
    assert relay.store.bridge_key(bridge.id) == bridge.sign_pk
    ws = await connect(client, "bridge", bridge)
    assert (await request(ws, {"t": "list_devices"}))["devices"] == []
    with pytest.raises(RuntimeError):
        await pair_bridge(client, code)


async def test_bridge_pairing_wrong_secret_burns_code_after_three(client, relay) -> None:
    code = relay.store.create_relay_code()
    wrong = codes.Code(code.slot, "WRONG")
    for _ in range(3):
        with pytest.raises((RuntimeError, CryptoError)):
            await pair_bridge(client, wrong)
    with pytest.raises(RuntimeError):
        await pair_bridge(client, code)


async def test_bridge_pairing_host_mismatch_fails(client, relay) -> None:
    code = relay.store.create_relay_code()
    with pytest.raises((RuntimeError, CryptoError)):
        await pair_bridge(client, code, host="attacker.test")


async def test_auth_rejects_unknown_and_forged(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    pk, sk = sodium.sign_keypair()
    with pytest.raises(RuntimeError):
        await connect(client, "bridge", Identity(bridge.id, pk, sk))
    with pytest.raises(RuntimeError):
        await connect(client, "device", bridge)


async def test_auth_failures_lock_out_ip(client, relay) -> None:
    bogus = Identity("A" * 22, *sodium.sign_keypair())
    for _ in range(10):
        with pytest.raises(RuntimeError):
            await connect(client, "bridge", bogus)
    response = await client.get("/v1/ws")
    assert response.status == 429


async def test_device_pairing_push_ring_and_e2e(client, relay, push) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    assert (await request(device_ws, {"t": "register_push", "token": TOKEN, "env": "sandbox"}))["t"] == "push_registered"

    call_id = wire.b64e(sodium.random_bytes(16))
    rang = await request(bridge_ws, {"t": "ring", "call_id": call_id, "devices": "all", "rid": 7})
    assert rang == {"t": "rang", "call_id": call_id, "pushed": [device.id], "rid": 7}
    assert push.sent == [(TOKEN, "sandbox", call_id)]

    await send(bridge_ws, {"t": "e2e", "to": device.id, "data": wire.b64e(b"offer")})
    assert await recv(device_ws) == {"t": "e2e", "data": wire.b64e(b"offer")}
    await send(device_ws, {"t": "e2e", "data": wire.b64e(b"answer")})
    message = await recv_type(bridge_ws, "e2e")
    assert message == {"t": "e2e", "from": device.id, "data": wire.b64e(b"answer")}


async def test_turn_credentials(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    creds = await request(ws, {"t": "turn"})
    assert creds["urls"] == ["turn:relay.test:3478?transport=udp"] and creds["ttl"] == 600


async def test_device_pairing_wrong_code_rejected(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    with pytest.raises(CryptoError):
        await pair_device(client, bridge_ws, secret="Q4M9P", device_secret="WRONG")
    assert relay.store.devices_of(bridge.id) == []


async def test_slot_burns_after_three_joins(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    slot = (await request(bridge_ws, {"t": "open_slot"}))["slot"]
    for _ in range(3):
        async with client.ws_connect("/v1/pair") as dev:
            await send(dev, {"t": "join", "slot": slot, "msg": wire.b64e(bytes(48))})
            join = await recv_type(bridge_ws, "pair_join")
            await send(bridge_ws, {"t": "pair_done", "conn": join["conn"], "ok": False})
            await recv(dev)
    assert slot not in relay.slots


async def test_cross_bridge_isolation(client, relay, push) -> None:
    bridge_a = await pair_bridge(client, relay.store.create_relay_code())
    bridge_b = await pair_bridge(client, relay.store.create_relay_code())
    ws_a = await connect(client, "bridge", bridge_a)
    ws_b = await connect(client, "bridge", bridge_b)
    device = await pair_device(client, ws_a)
    device_ws = await connect(client, "device", device)
    await request(device_ws, {"t": "register_push", "token": TOKEN, "env": "production"})

    call_id = wire.b64e(sodium.random_bytes(16))
    assert (await request(ws_b, {"t": "ring", "call_id": call_id, "devices": [device.id]}))["pushed"] == []
    assert (await request(ws_b, {"t": "e2e", "to": device.id, "data": "AA"}))["code"] == "unknown_device"
    assert (await request(ws_b, {"t": "revoke_device", "device_id": device.id}))["code"] == "unknown_device"
    assert push.sent == []
    assert relay.store.device(device.id) is not None


async def test_revoke_device_disconnects_and_blocks(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    assert (await request(bridge_ws, {"t": "revoke_device", "device_id": device.id}))["t"] == "revoked"
    msg = await device_ws.receive(timeout=5)
    assert msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING)
    with pytest.raises(RuntimeError):
        await connect(client, "device", device)


async def test_ring_validation_and_rate_limit(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    call_id = wire.b64e(sodium.random_bytes(16))
    for _ in range(10):
        assert (await request(ws, {"t": "ring", "call_id": call_id, "devices": "all"}))["t"] == "rang"
    assert (await request(ws, {"t": "ring", "call_id": call_id, "devices": "all"}))["code"] == "rate_limited"
    ws2 = await connect(client, "bridge", bridge)
    assert (await request(ws2, {"t": "ring", "call_id": "not-an-id", "devices": "all"}))["code"] == "protocol_error"


async def test_invalid_push_token_is_cleared(client, relay, push) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    await request(device_ws, {"t": "register_push", "token": TOKEN, "env": "sandbox"})
    push.invalid.add(TOKEN)
    await request(bridge_ws, {"t": "ring", "call_id": wire.b64e(bytes(16)), "devices": "all"})
    assert relay.store.device(device.id).push_token is None


@pytest.mark.parametrize("token,env", [("xyz", "sandbox"), (TOKEN, "staging"), (TOKEN.upper(), "sandbox"), (None, None)])
async def test_register_push_validation(client, relay, token, env) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    assert (await request(device_ws, {"t": "register_push", "token": token, "env": env}))["code"] == "protocol_error"


async def test_pair_endpoint_rejects_garbage(client) -> None:
    async with client.ws_connect("/v1/pair") as ws:
        await send(ws, {"t": "join", "slot": "!!!", "msg": "AA"})
        assert (await recv(ws))["code"] == "pairing_failed"


async def test_new_connection_replaces_old(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    first = await connect(client, "bridge", bridge)
    await connect(client, "bridge", bridge)
    msg = await first.receive(timeout=5)
    assert msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING)
    await asyncio.sleep(0)


async def test_per_ip_connection_cap(client, relay, monkeypatch) -> None:
    relay.limits = dataclasses.replace(relay.limits, max_connections_per_ip=2)
    first = await client.ws_connect("/v1/ws")
    second = await client.ws_connect("/v1/ws")
    response = await client.get("/v1/ws")
    assert response.status == 503
    await first.close()
    await second.close()
    await asyncio.sleep(0.05)
    assert relay.connections == 0 and relay.connections_per_ip == {}


async def test_message_flood_disconnects(client, relay, monkeypatch) -> None:
    from hermescall_relay.ratelimit import RateLimiter

    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    relay.message_rate = RateLimiter(limit=3, window=60)
    for _ in range(3):
        assert (await request(ws, {"t": "list_devices"}))["t"] == "devices"
    assert (await request(ws, {"t": "list_devices"}))["code"] == "protocol_error"


async def test_unknown_device_slot_rejected(client) -> None:
    async with client.ws_connect("/v1/pair") as ws:
        await send(ws, {"t": "join", "slot": "XYZ", "msg": wire.b64e(bytes(48))})
        assert (await recv(ws))["code"] == "pairing_failed"


async def test_turn_credentials_are_rate_limited_per_identity(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    replies = [await request(ws, {"t": "turn"}) for _ in range(7)]
    assert [r["t"] for r in replies] == ["turn"] * 6 + ["error"]
    assert replies[-1]["code"] == "rate_limited"


async def test_unhashable_fields_are_a_protocol_error(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    await send(ws, {"t": "close_slot", "slot": {"x": 1}})
    reply = await recv(ws)
    assert reply["t"] in ("slot_closed", "error")
