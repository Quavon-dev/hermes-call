"""Encrypted attachments: sealed with a random key that travels only inside the
E2E message, stored by the relay as opaque bytes (`PUT/GET /v1/blobs/<id>`)."""

import asyncio

import aiohttp

from . import sodium, wire
from .client import RelayEndpoint, RelaySession
from .errors import ProtocolError

AD = b"hermescall/v1/blob"
MAX_PLAINTEXT = 10 * 1024 * 1024
TRANSFER_TIMEOUT = aiohttp.ClientTimeout(total=300, sock_connect=15)
# HTTP 503 = the relay is busy (too many transfers): retry with the same ticket after these delays
# (a download ticket is good for 3 uses, an upload ticket until it succeeds).
BUSY_RETRIES = (0.5, 1.5)


def seal(data: bytes) -> tuple[bytes, bytes]:
    """Returns (key, nonce || ciphertext)."""
    if len(data) > MAX_PLAINTEXT:
        raise ProtocolError("attachment too large")
    key = sodium.random_bytes(32)
    return key, sodium.aead_encrypt(key, data, AD)


def open_sealed(key: bytes, sealed: bytes) -> bytes:
    return sodium.aead_decrypt(key, sealed, AD)


def _ssl(relay: RelaySession) -> aiohttp.Fingerprint | bool:
    """A pinned relay must present the certificate already verified on the session's WebSocket."""
    if not relay.endpoint.pin:
        return True
    if relay.cert_fingerprint is None:
        raise ProtocolError("not connected to relay")
    return aiohttp.Fingerprint(relay.cert_fingerprint)


def _url(endpoint: RelayEndpoint, blob_id: str) -> str:
    return f"https://{endpoint.authority}/v1/blobs/{blob_id}"


async def upload(relay: RelaySession, sealed: bytes, to: str | None = None) -> str:
    """Stores `sealed` for `to` (a device id; a device always sends to its bridge). Returns the blob id."""
    request = {"t": "blob_put", "size": len(sealed)}
    if to is not None:
        request["to"] = to
    ticket = await relay.request(request)
    blob_id = ticket["blob_id"]
    wire.b64d(blob_id, length=16)
    headers = {"Authorization": f"Bearer {ticket['token']}", "Content-Type": "application/octet-stream"}
    async with aiohttp.ClientSession(timeout=TRANSFER_TIMEOUT) as session:
        for delay in (*BUSY_RETRIES, None):
            async with session.put(_url(relay.endpoint, blob_id), data=sealed, headers=headers, ssl=_ssl(relay)) as response:
                if response.status == 200:
                    return blob_id
                if response.status != 503 or delay is None:
                    raise ProtocolError(f"blob upload failed: HTTP {response.status}")
            await asyncio.sleep(delay)
    raise ProtocolError("blob upload failed: relay busy")  # pragma: no cover - the loop always returns or raises


async def download(relay: RelaySession, blob_id: str, max_size: int = MAX_PLAINTEXT + 64) -> bytes:
    wire.b64d(blob_id, length=16)
    ticket = await relay.request({"t": "blob_get", "blob_id": blob_id})
    headers = {"Authorization": f"Bearer {ticket['token']}"}
    async with aiohttp.ClientSession(timeout=TRANSFER_TIMEOUT) as session:
        for delay in (*BUSY_RETRIES, None):
            async with session.get(_url(relay.endpoint, blob_id), headers=headers, ssl=_ssl(relay)) as response:
                if response.status == 200:
                    return await _read_limited(response, max_size)
                if response.status != 503 or delay is None:
                    raise ProtocolError(f"blob download failed: HTTP {response.status}")
            await asyncio.sleep(delay)
    raise ProtocolError("blob download failed: relay busy")  # pragma: no cover


async def _read_limited(response: aiohttp.ClientResponse, max_size: int) -> bytes:
    data = bytearray()
    async for chunk in response.content.iter_chunked(64 * 1024):
        data += chunk
        if len(data) > max_size:
            raise ProtocolError("attachment too large")
    return bytes(data)


async def delete(relay: RelaySession, blob_id: str) -> None:
    await relay.request({"t": "blob_delete", "blob_id": blob_id})
