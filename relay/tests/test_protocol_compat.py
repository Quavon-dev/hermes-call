"""Rolling upgrades: newer clients talk to older relays and the other way round."""

from .conftest import connect, pair_bridge, pair_device, recv, request, send


async def test_unknown_message_type_is_answered_and_the_session_stays(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    reply = await request(ws, {"t": "future_feature", "rid": 7, "x": 1})
    assert reply == {"t": "error", "code": "unsupported", "type": "future_feature", "rid": 7}
    assert (await request(ws, {"t": "list_devices"}))["t"] == "devices"


async def test_unknown_message_type_from_a_device(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    ws = await connect(client, "device", device)
    await send(ws, {"t": "x" * 200})
    reply = await recv(ws)
    assert reply["code"] == "unsupported" and "type" not in reply
    assert (await request(ws, {"t": "turn"}))["t"] == "turn"


async def test_healthz_reports_the_version(client) -> None:
    from hermescall_relay.version import VERSION

    response = await client.get("/healthz")
    assert response.status == 200
    body = await response.json()
    assert body["status"] == "ok"
    assert body["version"] == VERSION
