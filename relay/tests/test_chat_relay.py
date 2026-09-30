"""Mailbox, alert pushes and encrypted attachments (M6 chat)."""

import asyncio
import dataclasses

import pytest

from hermescall_common import sodium, wire
from hermescall_relay.push import MAX_ALERT_CIPHERTEXT, alert_payload
from hermescall_relay.store import MAIL_MAX_MESSAGES

from .conftest import connect, pair_bridge, pair_device, recv, recv_type, request, send

ALERT_TOKEN = "cd" * 32


def mid() -> str:
    return wire.b64e(sodium.random_bytes(16))


@pytest.fixture(autouse=True)
def fast_grace(relay) -> None:
    relay.limits = dataclasses.replace(relay.limits, mail_ack_grace=0.05)


async def setup_pair(client, relay):
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    return bridge, bridge_ws, device


async def test_mail_to_offline_device_is_stored_pushed_and_fetched(client, relay, push) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    device_ws = await connect(client, "device", device)
    reply = await request(device_ws, {"t": "register_push", "token": ALERT_TOKEN, "env": "sandbox", "kind": "alert"})
    assert reply["kind"] == "alert"
    await device_ws.close()
    await asyncio.sleep(0.05)

    first, second = mid(), mid()
    for mail_id in (first, second):
        reply = await request(bridge_ws, {"t": "mail", "to": device.id, "id": mail_id, "data": wire.b64e(b"x"), "alert": True})
        assert reply == {"t": "mailed", "id": mail_id}
    await asyncio.sleep(0.05)
    assert [a[0] for a in push.alerts] == [ALERT_TOKEN, ALERT_TOKEN]
    assert push.alerts[0][2] == wire.b64e(b"x")
    assert push.sent == []  # never a VoIP push for messages

    device_ws = await connect(client, "device", device)
    await send(device_ws, {"t": "mail_fetch", "rid": 1})
    got = [await recv(device_ws) for _ in range(3)]
    assert [m["id"] for m in got[:2]] == [first, second]
    assert got[2] == {"t": "mail_done", "more": False, "rid": 1}
    assert (await request(device_ws, {"t": "mail_ack", "ids": [first, second]}))["t"] == "mail_acked"
    assert relay.store.pending_mail(device.id) == []


async def test_mail_to_online_device_acked_in_time_is_not_pushed(client, relay, push) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    device_ws = await connect(client, "device", device)
    await request(device_ws, {"t": "register_push", "token": ALERT_TOKEN, "env": "sandbox", "kind": "alert"})
    mail_id = mid()
    await send(bridge_ws, {"t": "mail", "to": device.id, "id": mail_id, "data": wire.b64e(b"hi"), "alert": True})
    delivered = await recv_type(device_ws, "mail")
    assert delivered == {"t": "mail", "id": mail_id, "data": wire.b64e(b"hi")}
    await request(device_ws, {"t": "mail_ack", "ids": [mail_id]})
    await asyncio.sleep(0.1)
    assert push.alerts == []


async def test_unacked_mail_to_online_device_is_pushed(client, relay, push) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    device_ws = await connect(client, "device", device)
    await request(device_ws, {"t": "register_push", "token": ALERT_TOKEN, "env": "sandbox", "kind": "alert"})
    await request(bridge_ws, {"t": "mail", "to": device.id, "id": mid(), "data": wire.b64e(b"hi"), "alert": True})
    await asyncio.sleep(0.15)
    assert len(push.alerts) == 1


async def test_mail_duplicates_bounds_and_ownership(client, relay, monkeypatch) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    mail_id = mid()
    for _ in range(2):
        assert (await request(bridge_ws, {"t": "mail", "to": device.id, "id": mail_id, "data": "eA"}))["t"] == "mailed"
    assert len(relay.store.pending_mail(device.id)) == 1

    other = await pair_bridge(client, relay.store.create_relay_code())
    other_ws = await connect(client, "bridge", other)
    reply = await request(other_ws, {"t": "mail", "to": device.id, "id": mid(), "data": "eA"})
    assert reply["code"] == "unknown_device"

    for _ in range(MAIL_MAX_MESSAGES - 1):
        relay.store.add_mail(mid(), device.id, "eA")
    assert (await request(bridge_ws, {"t": "mail", "to": device.id, "id": mid(), "data": "eA"}))["code"] == "mailbox_full"


async def test_device_cannot_ack_or_fetch_foreign_mail(client, relay) -> None:
    bridge, bridge_ws, device = await setup_pair(client, relay)
    second = await pair_device(client, bridge_ws, secret="Z7K2M")
    mail_id = mid()
    await request(bridge_ws, {"t": "mail", "to": device.id, "id": mail_id, "data": "eA"})
    second_ws = await connect(client, "device", second)
    await request(second_ws, {"t": "mail_ack", "ids": [mail_id]})
    assert relay.store.has_mail(device.id, mail_id)
    assert (await request(second_ws, {"t": "mail_fetch"})) == {"t": "mail_done", "more": False}


async def test_revoked_device_loses_its_mailbox(client, relay) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    await request(bridge_ws, {"t": "mail", "to": device.id, "id": mid(), "data": "eA"})
    await request(bridge_ws, {"t": "revoke_device", "device_id": device.id})
    assert relay.store.pending_mail(device.id) == []


async def test_blob_roundtrip_bridge_to_device(client, relay) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    device_ws = await connect(client, "device", device)
    payload = sodium.random_bytes(200_000)
    ticket = await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": len(payload)})
    assert ticket["t"] == "blob_ticket"
    blob_id, token = ticket["blob_id"], ticket["token"]

    # Unfinished blobs cannot be fetched; tickets are bound to one blob and one method.
    assert (await request(device_ws, {"t": "blob_get", "blob_id": blob_id}))["code"] == "unknown_blob"
    response = await client.get(f"/v1/blobs/{blob_id}", headers={"Authorization": f"Bearer {token}"})
    assert response.status == 403
    response = await client.put(f"/v1/blobs/{blob_id}", data=payload, headers={"Authorization": f"Bearer {token}"})
    assert response.status == 200
    response = await client.put(f"/v1/blobs/{blob_id}", data=payload, headers={"Authorization": f"Bearer {token}"})
    assert response.status == 403  # upload tickets are single use

    # Only the recipient may download.
    assert (await request(bridge_ws, {"t": "blob_get", "blob_id": blob_id}))["code"] == "unknown_blob"
    get = await request(device_ws, {"t": "blob_get", "blob_id": blob_id})
    response = await client.get(f"/v1/blobs/{blob_id}", headers={"Authorization": f"Bearer {get['token']}"})
    assert response.status == 200
    assert await response.read() == payload

    assert (await request(device_ws, {"t": "blob_delete", "blob_id": blob_id}))["t"] == "blob_deleted"
    assert relay.store.blob(blob_id) is None
    assert not (relay.blob_dir / blob_id).exists()


async def test_blob_device_to_bridge_and_size_mismatch(client, relay) -> None:
    _, bridge_ws, device = await setup_pair(client, relay)
    device_ws = await connect(client, "device", device)
    ticket = await request(device_ws, {"t": "blob_put", "size": 10})
    response = await client.put(
        f"/v1/blobs/{ticket['blob_id']}", data=b"x" * 11, headers={"Authorization": f"Bearer {ticket['token']}"}
    )
    assert response.status == 400
    assert relay.store.blob(ticket["blob_id"]) is None

    ticket = await request(device_ws, {"t": "blob_put", "size": 3})
    await client.put(f"/v1/blobs/{ticket['blob_id']}", data=b"abc", headers={"Authorization": f"Bearer {ticket['token']}"})
    get = await request(bridge_ws, {"t": "blob_get", "blob_id": ticket["blob_id"]})
    assert get["t"] == "blob_ticket"


async def test_blob_limits(client, relay) -> None:
    bridge, bridge_ws, device = await setup_pair(client, relay)
    reply = await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 11 * 1024 * 1024})
    assert reply == {"t": "error", "code": "protocol_error"}  # oversized: the connection is closed
    bridge_ws = await connect(client, "bridge", bridge)
    for _ in range(20):
        assert (await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 1}))["t"] == "blob_ticket"
    assert (await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 1}))["code"] == "quota_exceeded"


async def test_bad_blob_tickets_count_as_failures(client, relay) -> None:
    for _ in range(10):
        response = await client.get(f"/v1/blobs/{'A' * 22}", headers={"Authorization": "Bearer nope"})
        assert response.status == 403
    assert (await client.get(f"/v1/blobs/{'A' * 22}")).status == 429


def test_alert_payload_is_generic_and_bounded() -> None:
    import json

    small = json.loads(alert_payload("abc"))
    assert small["e"] == "abc" and small["aps"]["mutable-content"] == 1
    assert "e" not in json.loads(alert_payload("x" * (MAX_ALERT_CIPHERTEXT + 1)))
    assert len(alert_payload("x" * MAX_ALERT_CIPHERTEXT)) < 4096
