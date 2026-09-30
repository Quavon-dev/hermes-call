"""Encrypted attachments: tickets over the WebSocket, bytes over plain HTTP PUT/GET.

The relay stores ciphertext it cannot open (the key travels inside the E2E message). A ticket is
bound to one blob and one method. An upload ticket is spent when the upload starts; a busy relay
answers 503 and keeps it, so the client can retry. A download ticket works a few times (a retry
after a dropped connection), then never. Every transfer has an overall deadline and a slot in a
global cap, so slow clients cannot pile up.
"""

import asyncio
import contextlib
import dataclasses
import logging
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

from aiohttp import web

from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .store import BLOB_MAX_BYTES, new_id

log = logging.getLogger(__name__)

BLOB_CHUNK = 64 * 1024
CHUNK_TIMEOUT = 60.0
STALE_TMP_SECONDS = 3600


@dataclass(frozen=True)
class BlobTicket:
    blob_id: str
    method: str
    expires: float
    uses: int = 0


def _refuse_upload(status: int) -> web.Response:
    """The body was not (fully) read: close the connection, or the unread rest would be parsed as the
    next request on it (older aiohttp does not drain it; behind Caddy that request may be someone else's)."""
    response = web.Response(status=status)
    response.force_close()
    return response


class AttachmentsMixin:
    """Part of `Relay` (server.py); uses its store, limits, rate limiters and lockouts."""

    blob_tickets: dict[str, BlobTicket]
    blob_transfers: int
    blob_downloads: int

    @property
    def blob_dir(self) -> Path:
        return self.config.db_path.parent / "blobs"

    def _peer_of(self, identity: str, message: dict) -> tuple[str, str] | None:
        """(owner bridge, recipient) for an upload by `identity`; a device always sends to its bridge."""
        if identity in self.bridges:
            device = self.store.device(self._valid_id(message.get("to")))
            return (identity, device.id) if device and device.bridge_id == identity else None
        device = self.store.device(identity)
        return (device.bridge_id, device.bridge_id) if device else None

    def _ticket(self, blob_id: str, method: str) -> dict:
        now = time.monotonic()
        self.blob_tickets = {k: t for k, t in self.blob_tickets.items() if t.expires > now}
        token = wire.b64e(secrets.token_bytes(32))
        seconds = self.limits.blob_ticket_seconds
        self.blob_tickets[token] = BlobTicket(blob_id, method, now + seconds)
        return {"t": "blob_ticket", "blob_id": blob_id, "token": token, "ttl": int(seconds)}

    async def x_blob_put(self, identity: str, message: dict) -> dict:
        size = message.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= BLOB_MAX_BYTES:
            raise ProtocolError("invalid blob size")
        peer = self._peer_of(identity, message)
        if peer is None:
            return {"t": "error", "code": "unknown_device"}
        if not self._allow(self.blob_upload_rate, identity, "blob_uploads"):
            return {"t": "error", "code": "rate_limited"}
        blob_id = new_id()
        if not self.store.add_blob(blob_id, peer[0], identity, peer[1], size):
            return {"t": "error", "code": "quota_exceeded"}
        return self._ticket(blob_id, "PUT")

    async def x_blob_get(self, identity: str, message: dict) -> dict:
        blob_id = self._valid_id(message.get("blob_id"))
        blob = self.store.blob(blob_id)
        if blob is None or blob[2] != identity or not blob[4]:
            return {"t": "error", "code": "unknown_blob"}
        if not self._allow(self.blob_ticket_rate, identity, "blob_tickets"):
            return {"t": "error", "code": "rate_limited"}
        return self._ticket(blob_id, "GET")

    async def x_blob_delete(self, identity: str, message: dict) -> dict:
        blob_id = self._valid_id(message.get("blob_id"))
        blob = self.store.blob(blob_id)
        if blob is not None and identity in (blob[1], blob[2]):
            self._remove_blob(blob_id)
        return {"t": "blob_deleted", "blob_id": blob_id}

    def _blob_path(self, blob_id: str) -> Path:
        return self.blob_dir / self._valid_id(blob_id)

    def _remove_blob(self, blob_id: str) -> None:
        self.store.delete_blob(blob_id)
        self._blob_path(blob_id).unlink(missing_ok=True)

    def _sweep_blobs(self) -> int:
        """Expired and unfinished blobs, and files nobody knows about; returns how many were removed."""
        incomplete_after = int(self.limits.blob_ticket_seconds + self.limits.blob_upload_seconds)
        expired = self.store.expired_blobs(incomplete_after=incomplete_after)
        for blob_id in expired:
            self._remove_blob(blob_id)
        known = self.store.blob_ids()
        cutoff = time.time() - STALE_TMP_SECONDS
        with contextlib.suppress(OSError):
            for path in self.blob_dir.iterdir():
                stale_tmp = path.name.startswith(".") and path.stat().st_mtime < cutoff
                if stale_tmp or (not path.name.startswith(".") and path.name not in known):
                    path.unlink(missing_ok=True)
        return len(expired)

    def _find_ticket(self, request: web.Request, method: str) -> tuple[str, BlobTicket] | None:
        token = request.headers.get("Authorization", "").removeprefix("Bearer ")
        ticket = self.blob_tickets.get(token)
        if ticket is None or ticket.method != method or ticket.expires <= time.monotonic():
            return None
        if ticket.blob_id != request.match_info["blob_id"]:
            return None
        return token, ticket

    def _use_ticket(self, token: str, ticket: BlobTicket) -> None:
        uses = ticket.uses + 1
        if ticket.method == "PUT" or uses >= self.limits.blob_download_uses:
            self.blob_tickets.pop(token, None)
        else:
            self.blob_tickets[token] = dataclasses.replace(ticket, uses=uses)

    async def blob_upload(self, request: web.Request) -> web.Response:
        ip = self.client_ip(request)
        if self._locked_out(ip):
            return _refuse_upload(429)
        found = self._find_ticket(request, "PUT")
        if found is None:
            self._fail(ip)
            return _refuse_upload(403)
        token, ticket = found
        blob = self.store.blob(ticket.blob_id)
        if blob is None or blob[4]:
            self.blob_tickets.pop(token, None)
            return _refuse_upload(409 if blob else 404)
        if self.blob_transfers >= self.limits.max_blob_transfers:
            # Busy, not wrong: the ticket and the reservation stay, the client may retry.
            self._count_limit("blob_transfers")
            return _refuse_upload(503)
        self._use_ticket(token, ticket)
        return await self._store_upload(request, ticket.blob_id, blob[3])

    async def _store_upload(self, request: web.Request, blob_id: str, expected: int) -> web.Response:
        self.blob_transfers += 1
        tmp = self.blob_dir / f".{blob_id}.{secrets.token_hex(4)}"
        try:
            size = await asyncio.wait_for(self._receive_blob(request, tmp, expected), self.limits.blob_upload_seconds)
            if size != expected:
                raise ProtocolError("size mismatch")
            os.replace(tmp, self._blob_path(blob_id))
            self.store.complete_blob(blob_id, size)
        except (ProtocolError, OSError, ConnectionError, TimeoutError) as exc:
            tmp.unlink(missing_ok=True)
            self._remove_blob(blob_id)
            log.info("blob upload failed: %s", exc.__class__.__name__)
            self.transfers_total.inc(direction="upload", result="failed")
            return _refuse_upload(400)
        finally:
            self.blob_transfers -= 1
        self.transfers_total.inc(direction="upload", result="ok")
        return web.json_response({"blob_id": blob_id, "size": size})

    @staticmethod
    async def _receive_blob(request: web.Request, path: Path, limit: int) -> int:
        size = 0
        with open(path, "xb") as handle:  # noqa: ASYNC230 - small chunks to local disk
            os.chmod(path, 0o600)
            while chunk := await asyncio.wait_for(request.content.read(BLOB_CHUNK), CHUNK_TIMEOUT):
                size += len(chunk)
                if size > limit:
                    raise ProtocolError("blob too large")
                handle.write(chunk)
        return size

    async def blob_download(self, request: web.Request) -> web.StreamResponse:
        ip = self.client_ip(request)
        if self._locked_out(ip):
            return web.Response(status=429)
        found = self._find_ticket(request, "GET")
        if found is None:
            self._fail(ip)
            return web.Response(status=403)
        token, ticket = found
        path = self._blob_path(ticket.blob_id)
        if not path.exists():
            return web.Response(status=404)
        if self.blob_downloads >= self.limits.max_blob_downloads:
            self._count_limit("blob_downloads")
            return web.Response(status=503)
        self._use_ticket(token, ticket)
        return await self._send_blob(request, path)

    async def _send_blob(self, request: web.Request, path: Path) -> web.StreamResponse:
        self.blob_downloads += 1
        response = web.StreamResponse(headers={"Content-Type": "application/octet-stream", "Cache-Control": "no-store"})
        try:
            await asyncio.wait_for(self._stream_file(request, response, path), self.limits.blob_download_seconds)
        except (TimeoutError, ConnectionError, OSError) as exc:
            log.info("blob download aborted: %s", exc.__class__.__name__)
            self.transfers_total.inc(direction="download", result="failed")
            if request.transport is not None:
                request.transport.close()
            return response
        finally:
            self.blob_downloads -= 1
        self.transfers_total.inc(direction="download", result="ok")
        return response

    @staticmethod
    async def _stream_file(request: web.Request, response: web.StreamResponse, path: Path) -> None:
        with open(path, "rb") as handle:  # noqa: ASYNC230 - small chunks from local disk
            response.content_length = os.fstat(handle.fileno()).st_size
            await response.prepare(request)
            while chunk := handle.read(BLOB_CHUNK):
                await response.write(chunk)
        await response.write_eof()
