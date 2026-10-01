# SPDX-License-Identifier: MIT
"""Chat attachments on the bridge's disk instead of in memory (D5).

Every attachment that passes the bridge is kept as one **sealed** blob (XChaCha20-Poly1305, the same
format the relay stores) in `<state dir>/files/` (directory 0700, files 0600); its key and metadata are
rows in chat.db. A phone's upload is streamed there as it was downloaded (its own key, never re-sealed);
an agent file is sealed once. The same sealed bytes then go to every other phone (the relay keeps blobs
per recipient, so each phone still gets its own upload) and to Hermes' adapter, which fetches them one
by one (`GET /v1/chat/files/<id>`) instead of as base64 inside the event queue. A file is deleted when
nothing needs it any more: Hermes has the event and the message left the history (history.py).
"""

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from hermescall_common import blobs, sodium, wire
from hermescall_common.client import RelaySession
from hermescall_common.errors import ProtocolError

from .chatstore import AsyncStore, StoredFile

log = logging.getLogger(__name__)

SEALING_OVERHEAD = sodium.AEAD_NONCEBYTES + sodium.AEAD_ABYTES
# A file on disk without a row is a download in progress, unless it is older than this.
STRAY_AFTER = 600.0


@dataclass(frozen=True)
class Incoming:
    """An attachment a phone announced (its blob at the relay, sealed with `key`)."""

    kind: str
    blob_id: str
    key: bytes
    name: str
    mime: str


class FileSpool:
    def __init__(self, directory: Path, db: AsyncStore) -> None:
        self.directory = directory
        self._db = db
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(directory, 0o700)

    def _path(self, file_id: str) -> Path:
        wire.b64d(file_id, length=16)
        return self.directory / file_id

    async def fetch(self, relay: RelaySession, message_id: str, item: Incoming) -> StoredFile:
        """Streams the phone's blob to disk (still sealed) and records it; the blob id becomes the file id."""
        size = await blobs.download_to(relay, item.blob_id, self._path(item.blob_id))
        file = StoredFile(
            item.blob_id, message_id, wire.b64e(item.key), item.kind, item.name, item.mime, max(0, size - SEALING_OVERHEAD)
        )
        await self._db.call(self._db.store.add_file, file)
        return file

    async def put(self, message_id: str, data: bytes, kind: str, name: str, mime: str) -> StoredFile:
        """An attachment from the agent: sealed once, for every phone. Only written to disk: its row is
        added together with the message's history entry (`ChatHistory.record`, one transaction), so a
        `collect()` in between cannot take it for unused (a file without a row is kept for STRAY_AFTER)."""
        key, sealed = await asyncio.get_running_loop().run_in_executor(None, blobs.seal, data)
        file_id = wire.b64e(sodium.random_bytes(16))
        await asyncio.get_running_loop().run_in_executor(None, _write, self._path(file_id), sealed)
        return StoredFile(file_id, message_id, wire.b64e(key), kind, name, mime, len(data))

    async def get(self, file_id: str) -> StoredFile | None:
        try:
            wire.b64d(file_id, length=16)
        except ProtocolError:
            return None
        return await self._db.call(self._db.store.file, file_id)

    async def read(self, file: StoredFile) -> bytes:
        """The plaintext (one attachment, ≤ 10 MiB, in memory while it is used)."""
        return await asyncio.get_running_loop().run_in_executor(None, _open, self._path(file.file_id), file.key)

    async def upload(self, relay: RelaySession, file: StoredFile, to: str) -> dict[str, Any]:
        """The same sealed bytes for one more phone; returns the attachment reference for its chat message."""
        sealed = await asyncio.get_running_loop().run_in_executor(None, self._path(file.file_id).read_bytes)
        blob_id = await blobs.upload(relay, sealed, to=to)
        return {**file.meta(), "blob_id": blob_id, "key": file.key}

    async def collect(self) -> int:
        """Deletes the files nothing needs any more (and stray ones without a row); returns how many."""
        unused = await self._db.call(self._db.store.unused_files)
        known = await self._db.call(self._db.store.file_ids)
        now = time.time()
        stray = [p.name for p in self.directory.iterdir() if p.name not in known and now - p.stat().st_mtime > STRAY_AFTER]
        for name in {*unused, *stray}:
            (self.directory / name).unlink(missing_ok=True)
        if unused:
            log.info("%d spooled attachment(s) deleted", len(unused))
        return len(unused) + len(stray)


def _write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)


def _open(path: Path, key: str) -> bytes:
    return blobs.open_sealed(wire.b64d(key, length=32), path.read_bytes())
