# SPDX-License-Identifier: MIT
"""The last messages of the shared chat, for a phone paired later (D4).

The bridge keeps the newest `HISTORY_LIMIT` owner and agent messages in chat.db (0600, the same file
and trust as the inbox) with their spooled attachments (files.py). A phone whose bridge lists the
`history` cap asks once after pairing (`history_request`) and gets `history_page`s, newest first; it
stores what it does not have yet (by message id). Deleting a message on a phone stays local to it.

Attachments in a page cost a relay upload each (the relay allows 20 blobs / 50 MiB per phone), so a
phone gets at most `SYNC_FILES` of them per hour; older ones arrive as a `[kind: name]` line.
"""

import contextlib
import json
import logging
import time
from collections import deque
from typing import Any

from hermescall_common.client import RelaySession
from hermescall_common.errors import ProtocolError

from .chatstore import AsyncStore, StoredFile
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
# An attachment reference's blob id (16 bytes) and key (32 bytes) in base64url, for sizing before the upload.
_REF_PLACEHOLDER = {"blob_id": "A" * 22, "key": "A" * 43}


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
        """One `history_page` for this phone: as many messages as fit, newest first. Each message is sized
        (as `Channel.seal` measures it) before its attachments are uploaded, so a message that waits for
        the next page costs no upload; one too large for a page is cut down, never sent whole."""
        start = before if isinstance(before, int) and not isinstance(before, bool) and before > 0 else None
        count = limit if isinstance(limit, int) and not isinstance(limit, bool) and 0 < limit <= PAGE_LIMIT else PAGE_LIMIT
        rows = await self._db.call(self._db.store.history_before, start, count + 1)
        messages: list[dict[str, Any]] = []
        used, last, consumed = 0, start, 0
        for seq, item in rows[:count]:
            files = [file for file in [await self._spool.get(file_id) for file_id in item.get("files", [])] if file]
            message = _fit(_base(item), files)
            if message is None:
                log.warning("history message %s skipped: too large for a page", str(item.get("id", ""))[:6])
            else:
                size = _bound(message, files) + 1  # the comma between messages
                if messages and used + size > PAGE_BYTES:
                    break
                messages.append(await self._attach(device_id, message, files))
                used += size
            last, consumed = seq, consumed + 1
        more = consumed < len(rows)
        return {"type": "history_page", "messages": messages, "more": more, "next": last if more else None}

    async def _attach(self, device_id: str, message: dict[str, Any], files: list[StoredFile]) -> dict[str, Any]:
        """Uploads the message's files for this phone (within its budget); the rest become `[kind: name]` lines."""
        refs, labels = [], []
        for file in files:
            ref = await self._send_file(device_id, file)
            if ref is None:
                labels.append(_label(file))
            else:
                refs.append(ref)
        if refs:
            message = {**message, "attachments": refs}
        if labels:
            message = {**message, "text": "\n".join(part for part in (message["text"], *labels) if part)}
        return message

    async def _send_file(self, device_id: str, file: StoredFile) -> dict[str, Any] | None:
        slot = self._reserve(device_id, file.size)
        if slot is None:
            return None
        ref = await self._upload(device_id, file)
        if ref is None:  # a failed upload costs no budget
            with contextlib.suppress(ValueError):
                self._sent_files[device_id].remove(slot)
        return ref

    def _reserve(self, device_id: str, size: int) -> tuple[float, int] | None:
        now = time.monotonic()
        sent = self._sent_files.setdefault(device_id, deque())
        while sent and now - sent[0][0] > SYNC_WINDOW:
            sent.popleft()
        if len(sent) >= SYNC_FILES or sum(n for _, n in sent) + size > SYNC_FILE_BYTES:
            return None
        slot = (now, size)
        sent.append(slot)
        return slot

    async def _upload(self, device_id: str, file: StoredFile) -> dict[str, Any] | None:
        try:
            return await self._spool.upload(self._relay, file, device_id)
        except (ProtocolError, OSError, TimeoutError) as exc:
            log.warning("history attachment for %s not uploaded: %s", device_id[:6], exc.__class__.__name__)
            return None


def _size(value: Any) -> int:
    """Characters in the compact JSON, as `Channel.seal` counts them (non-ASCII as \\u escapes)."""
    return len(json.dumps(value, separators=(",", ":")))


def _clip(text: str, budget: int) -> str:
    """The longest prefix of `text` whose JSON-escaped form takes at most `budget` characters."""
    if _size(text) - 2 <= budget:
        return text
    used = 0
    for index, char in enumerate(text):
        used += _size(char) - 2
        if used > budget:
            return text[:index]
    return text


def _label(file: StoredFile) -> str:
    return f"[{file.kind}: {file.name}]"


def _base(item: dict[str, Any]) -> dict[str, Any]:
    message = {key: item[key] for key in (*KEPT, "ts") if key in item}
    message["text"] = str(message.get("text", ""))[:MAX_ENTRY_TEXT]
    if "transcript" in message:
        message["transcript"] = str(message["transcript"])[:MAX_ENTRY_TEXT]
    return message


def _bound(message: dict[str, Any], files: list[StoredFile]) -> int:
    """The size the message can reach once its files are attached or listed (each could become either)."""
    worst = {**message, "text": "\n".join((message["text"], *(_label(f) for f in files)))}
    if files:
        worst["attachments"] = [{**f.meta(), **_REF_PLACEHOLDER} for f in files]
    return _size(worst)


def _fit(message: dict[str, Any], files: list[StoredFile]) -> dict[str, Any] | None:
    """The message cut down to at most PAGE_BYTES: a card deck without its cards, then text and transcript
    shortened. None: not even its attachment lines fit."""
    if _bound(message, files) <= PAGE_BYTES:
        return message
    if "presentation" in message:  # a very large card deck: its text only
        message = {k: v for k, v in message.items() if k != "presentation"} | {"kind": "text"}
        if _bound(message, files) <= PAGE_BYTES:
            return message
    transcript = message.get("transcript")
    empty = {**message, "text": ""} | ({"transcript": ""} if transcript is not None else {})
    room = PAGE_BYTES - _bound(empty, files)
    if room < 0:
        return None
    text_size = _size(message["text"]) - 2
    clipped = _clip(transcript, max(room // 2, room - text_size)) if transcript is not None else None
    used = _size(clipped) - 2 if clipped is not None else 0
    fitted = {**empty, "text": _clip(message["text"], room - used)}
    return fitted | ({"transcript": clipped} if clipped is not None else {})
