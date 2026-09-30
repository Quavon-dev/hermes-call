"""Attachment transfers: tickets survive a busy relay, uploads have a deadline, downloads are capped."""

import asyncio
import dataclasses

from .conftest import connect, pair_bridge, pair_device, request


async def _paired(client, relay):
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    return bridge_ws, device, device_ws


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def test_busy_relay_keeps_the_upload_ticket(client, relay) -> None:
    bridge_ws, device, _ = await _paired(client, relay)
    ticket = await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 3})
    relay.blob_transfers = relay.limits.max_blob_transfers
    response = await client.put(f"/v1/blobs/{ticket['blob_id']}", data=b"abc", headers=_auth(ticket["token"]))
    assert response.status == 503
    relay.blob_transfers = 0
    response = await client.put(f"/v1/blobs/{ticket['blob_id']}", data=b"abc", headers=_auth(ticket["token"]))
    assert response.status == 200
    assert relay.store.blob(ticket["blob_id"])[4] is True


async def test_upload_has_an_overall_deadline(client, relay) -> None:
    bridge_ws, device, _ = await _paired(client, relay)
    relay.limits = dataclasses.replace(relay.limits, blob_upload_seconds=0.3)
    ticket = await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 4})

    async def trickle():
        for _ in range(4):
            await asyncio.sleep(0.15)
            yield b"x"

    try:
        response = await client.put(f"/v1/blobs/{ticket['blob_id']}", data=trickle(), headers=_auth(ticket["token"]))
        assert response.status == 400
    except Exception:  # noqa: S110 - the relay may close the connection before the client finishes sending
        pass
    await asyncio.sleep(0.05)
    assert relay.store.blob(ticket["blob_id"]) is None
    assert relay.blob_transfers == 0


async def test_download_tickets_are_capped(client, relay) -> None:
    bridge_ws, device, device_ws = await _paired(client, relay)
    ticket = await request(bridge_ws, {"t": "blob_put", "to": device.id, "size": 3})
    await client.put(f"/v1/blobs/{ticket['blob_id']}", data=b"abc", headers=_auth(ticket["token"]))
    get = await request(device_ws, {"t": "blob_get", "blob_id": ticket["blob_id"]})
    url = f"/v1/blobs/{ticket['blob_id']}"
    # A full relay answers 503 without using up the ticket.
    relay.blob_downloads = relay.limits.max_blob_downloads
    assert (await client.get(url, headers=_auth(get["token"]))).status == 503
    relay.blob_downloads = 0
    # A retry after a dropped connection works, endless reuse does not.
    for _ in range(relay.limits.blob_download_uses):
        response = await client.get(url, headers=_auth(get["token"]))
        assert response.status == 200
        assert await response.read() == b"abc"
    assert (await client.get(url, headers=_auth(get["token"]))).status == 403
    assert relay.blob_downloads == 0
