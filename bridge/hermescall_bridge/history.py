# SPDX-License-Identifier: MIT
"""The last messages of the shared chat, for a phone paired later (D4).

The bridge keeps the newest `HISTORY_LIMIT` owner and agent messages in chat.db (0600, the same file
and trust as the inbox) with their spooled attachments (files.py). A phone whose bridge lists the
`history` cap asks once after pairing (`history_request`) and gets `history_page`s, newest first; it
stores what it does not have yet (by message id). Deleting a message on a phone stays local to it.

Attachments in a page cost a relay upload each (the relay allows 20 blobs / 50 MiB per phone), so a
phone gets at most `SYNC_FILES` of them per hour; older ones arrive as a `[kind: name]` line.
"""

import json
import logging
import time
from collections import deque
from typing import Any

from hermescall_common.client import RelaySession
from hermescall_common.errors import ProtocolError

from .chatstore import AsyncStore
from .files import FileSpool

log = logging.getLogger(__name__)

HISTORY_LIMIT = 200
CAP = "history"
PAGE_LIMIT = 50
# Plaintext budget of one page (the E2E envelope allows 40 KiB).
PAGE_BYTES = 30 * 1024
MAX_ENTRY_TEXT = 8000
SYNC_FILES = 10
SYNC_FILE_BYTES = 30 * 1024 * 1024
SYNC_WINDOW = 3600.0
# history_request per phone: (window seconds, count)
REQUEST_LIMIT = (600.0, 20)
KEPT = ("id", "role", "kind", "text", "reply_to", "transcript", "presentation")


def entry(body: dict[str, Any], file_ids: list[str], ts: int | None = None) -> dict[str, Any]:
    """What history keeps of a chat message: no blob ids or keys (those are per phone), card images dropped."""
    kept = {key: body[key] for key in KEPT if body.get(key) not in (None, "")}
    if isinstance(kept.get("presentation"), dict):
        presentation = kept["presentation"]
        items = [{k: v for k, v in item.items() if k != "image"} for item in presentation.get("items", [])]
        kept["presentation"] = {**presentation, "items": items}
    return {**kept, "files": file_ids, "ts": ts if ts is not None else int(time.time() * 1000)}


class ChatHistory:
    def __init__(self, db: AsyncStore, spool: FileSpool, relay: RelaySession) -> None:
        self._db = db
        self._spool = spool
        self._relay = relay
        self._sent_files: dict[str, deque[tuple[float, int]]] = {}
        self._requests: dict[str, deque[float]] = {}

    async def record(self, body: dict[str, Any], file_ids: list[str], keep: int) -> None:
        item = entry(body, file_ids)
        await self._db.call(self._db.store.add_history, str(body["id"]), item, item["ts"], keep)
        await self._spool.collect()

    def allowed(self, device_id: str) -> bool:
        window, limit = REQUEST_LIMIT
        now = time.monotonic()
        times = self._requests.setdefault(device_id, deque(maxlen=limit))
        if len(times) == limit and now - times[0] < window:
            return False
        times.append(now)
        return True

    async def page(self, device_id: str, before: object, limit: object) -> dict[str, Any]:
        """One `history_page` for this phone: as many messages as fit, newest first."""
        start = before if isinstance(before, int) and not isinstance(before, bool) and before > 0 else None
        count = limit if isinstance(limit, int) and not isinstance(limit, bool) and 0 < limit <= PAGE_LIMIT else PAGE_LIMIT
        rows = await self._db.call(self._db.store.history_before, start, count + 1)
        messages: list[dict[str, Any]] = []
        used, last = 0, start
        for seq, item in rows[:count]:
            message = await self._message(device_id, item)
            size = len(json.dumps(message, separators=(",", ":")).encode())
            if size > PAGE_BYTES and "presentation" in message:  # a very large card deck: its text only
                message = {k: v for k, v in message.items() if k != "presentation"} | {"kind": "text"}
                size = len(json.dumps(message, separators=(",", ":")).encode())
            if messages and used + size > PAGE_BYTES:
                break
            messages.append(message)
            used += size
            last = seq
        more = len(messages) < len(rows)
        return {"type": "history_page", "messages": messages, "more": more, "next": last if more else None}

    async def _message(self, device_id: str, item: dict[str, Any]) -> dict[str, Any]:
        message = {key: item[key] for key in (*KEPT, "ts") if key in item}
        message["text"] = str(message.get("text", ""))[:MAX_ENTRY_TEXT]
        refs, labels = [], []
        for file_id in item.get("files", []):
            file = await self._spool.get(file_id)
            if file is None:
                continue
            ref = await self._upload(device_id, file) if self._budget(device_id, file.size) else None
            if ref is None:
                labels.append(f"[{file.kind}: {file.name}]")
            else:
                refs.append(ref)
        if refs:
            message["attachments"] = refs
        if labels:
            message["text"] = "\n".join(part for part in (message["text"], *labels) if part)
        return message

    def _budget(self, device_id: str, size: int) -> bool:
        now = time.monotonic()
        sent = self._sent_files.setdefault(device_id, deque())
        while sent and now - sent[0][0] > SYNC_WINDOW:
            sent.popleft()
        if len(sent) >= SYNC_FILES or sum(n for _, n in sent) + size > SYNC_FILE_BYTES:
            return False
        sent.append((now, size))
        return True

    async def _upload(self, device_id: str, file: Any) -> dict[str, Any] | None:
        try:
            return await self._spool.upload(self._relay, file, device_id)
        except (ProtocolError, OSError, TimeoutError) as exc:
            log.warning("history attachment for %s not uploaded: %s", device_id[:6], exc.__class__.__name__)
            return None
