"""common/blobs.py: a relay answering 503 (busy) is retried with the same ticket."""

import pytest
from aiohttp import web

from hermescall_common import blobs
from hermescall_common.errors import ProtocolError


async def test_blob_transfers_retry_a_busy_relay(monkeypatch, aiohttp_server) -> None:
    hits = {"get": 0, "put": 0}

    async def get(request: web.Request) -> web.Response:
        hits["get"] += 1
        return web.Response(status=503) if hits["get"] < 3 else web.Response(body=b"sealed")

    async def put(request: web.Request) -> web.Response:
        hits["put"] += 1
        return web.Response(status=503) if hits["put"] < 2 else web.Response()

    app = web.Application()
    app.router.add_get("/v1/blobs/{blob_id}", get)
    app.router.add_put("/v1/blobs/{blob_id}", put)
    server = await aiohttp_server(app)

    class Relay:
        endpoint = type("E", (), {"pin": "", "authority": f"127.0.0.1:{server.port}"})()

        async def request(self, message: dict) -> dict:
            return {"blob_id": "A" * 22, "token": "t"}

    monkeypatch.setattr(blobs, "BUSY_RETRIES", (0.0, 0.0))
    monkeypatch.setattr(blobs, "_url", lambda endpoint, blob_id: f"http://{endpoint.authority}/v1/blobs/{blob_id}")
    assert await blobs.download(Relay(), "A" * 22) == b"sealed" and hits["get"] == 3
    assert await blobs.upload(Relay(), b"x") == "A" * 22 and hits["put"] == 2
    hits["get"] = -5  # busy for longer than the retries: an error, not a hang
    with pytest.raises(ProtocolError):
        await blobs.download(Relay(), "A" * 22)
    hits["put"] = -5
    with pytest.raises(ProtocolError):
        await blobs.upload(Relay(), b"x")
