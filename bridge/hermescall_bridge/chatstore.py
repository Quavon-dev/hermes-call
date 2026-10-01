"""Durable chat queues on the bridge (SQLite in the state directory, mode 0600).

- `inbox`: owner messages accepted from a phone (acked `delivered`) and not yet handed to Hermes;
- `events`: what the Hermes adapter polls (`/v1/chat/events`); rows go once the adapter's cursor
  passes them. `seq` never repeats (AUTOINCREMENT), so a cursor stays valid across restarts;
  `epoch` names this database, so a cursor from a lost database is recognized;
- `seen`: owner message ids already accepted (phones resend unacked messages);
- `outbox`: sealed mailbox messages for phones that the relay has not taken yet;
- `meta`: small values (epoch, call context, recent chat lines, per-phone Hermes sessions);
- `files`: attachments spooled on disk (files.py): their blob key and what still needs them;
- `history`: the last messages of the shared chat, for phones paired later (history.py).

All methods are synchronous; `ChatService` calls them through one worker thread (`AsyncStore`).
Owner message text is stored in plain text here until Hermes has it (the same machine and user
that run Hermes, whose session store keeps the conversation anyway); outbound rows are E2E sealed.
"""

import asyncio
import json
import os
import sqlite3
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TypeVar

from hermescall_common import sodium, wire

SEEN_SECONDS = 8 * 86_400
MAX_SEEN = 20_000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS seen (message_id TEXT PRIMARY KEY, at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS seen_at ON seen (at);
CREATE TABLE IF NOT EXISTS inbox (
    message_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, body TEXT NOT NULL, at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS outbox (
    row INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    mid TEXT NOT NULL,
    message_id TEXT NOT NULL,
    data TEXT NOT NULL,
    alert INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_try REAL NOT NULL,
    expires REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_next ON outbox (next_try);
CREATE TABLE IF NOT EXISTS files (
    file_id TEXT PRIMARY KEY, message_id TEXT NOT NULL, key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
    mime TEXT NOT NULL, size INTEGER NOT NULL, event_seq INTEGER, at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS files_message ON files (message_id);
CREATE TABLE IF NOT EXISTS history (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL UNIQUE, body TEXT NOT NULL, ts INTEGER NOT NULL
);
"""

T = TypeVar("T")


@dataclass(frozen=True)
class Pending:
    """An owner message accepted from a phone but not yet handed to Hermes."""

    message_id: str
    device_id: str
    body: dict[str, Any]


@dataclass(frozen=True)
class StoredFile:
    """An attachment spooled on disk (sealed with `key`), see files.py."""

    file_id: str
    message_id: str
    key: str
    kind: str
    name: str
    mime: str
    size: int

    def meta(self) -> dict[str, Any]:
        return {"kind": self.kind, "name": self.name, "mime": self.mime, "size": self.size}


@dataclass(frozen=True)
class Mail:
    row: int
    device_id: str
    mid: str
    message_id: str
    data: str
    alert: bool
    attempts: int
    expires: float


class ChatStore:
    def __init__(self, path: Path | str) -> None:
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        if str(path) != ":memory:":
            os.chmod(path, 0o600)
            self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.executescript(_SCHEMA)
        self.epoch = self.get_meta("epoch") or self._new_epoch()

    def close(self) -> None:
        self._db.close()

    def _new_epoch(self) -> str:
        epoch = wire.b64e(sodium.random_bytes(12))
        self.set_meta("epoch", epoch)
        return epoch

    # ---- meta --------------------------------------------------------------

    def get_meta(self, key: str) -> str | None:
        row = self._db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: str) -> None:
        self._db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))

    def get_json(self, key: str, default: Any) -> Any:
        raw = self.get_meta(key)
        try:
            return json.loads(raw) if raw is not None else default
        except ValueError:
            return default

    def set_json(self, key: str, value: Any) -> None:
        self.set_meta(key, json.dumps(value, separators=(",", ":")))

    # ---- inbound -------------------------------------------------------------

    def accept(self, message_id: str, device_id: str, body: dict[str, Any]) -> bool:
        """Records an owner message before it is acked. False: seen before (ack again, deliver once)."""
        now = time.time()
        with self._tx():
            if self._db.execute("SELECT 1 FROM seen WHERE message_id = ?", (message_id,)).fetchone():
                return False
            self._db.execute("INSERT INTO seen (message_id, at) VALUES (?, ?)", (message_id, now))
            self._db.execute(
                "INSERT INTO inbox (message_id, device_id, body, at) VALUES (?, ?, ?, ?)",
                (message_id, device_id, json.dumps(body), now),
            )
            self._prune_seen(now)
        return True

    def pending(self) -> list[Pending]:
        rows = self._db.execute("SELECT message_id, device_id, body FROM inbox ORDER BY at").fetchall()
        return [Pending(m, d, json.loads(b)) for m, d, b in rows]

    def hand_over(self, message_id: str, event: dict[str, Any]) -> int:
        """The processed message becomes an event for Hermes; its inbox row goes in the same transaction
        (its spooled files are then needed until Hermes has the event)."""
        with self._tx():
            self._db.execute("DELETE FROM inbox WHERE message_id = ?", (message_id,))
            seq = self._insert_event(event)
            self._db.execute("UPDATE files SET event_seq = ? WHERE message_id = ?", (seq, message_id))
            return seq

    def drop_pending(self, message_id: str) -> None:
        self._db.execute("DELETE FROM inbox WHERE message_id = ?", (message_id,))

    def inbox_depth(self) -> int:
        return self._db.execute("SELECT COUNT(*) FROM inbox").fetchone()[0]

    def _prune_seen(self, now: float) -> None:
        self._db.execute("DELETE FROM seen WHERE at < ?", (now - SEEN_SECONDS,))
        self._db.execute(
            "DELETE FROM seen WHERE message_id IN (SELECT message_id FROM seen ORDER BY at DESC LIMIT -1 OFFSET ?)", (MAX_SEEN,)
        )

    # ---- events for Hermes ------------------------------------------------------

    def add_event(self, event: dict[str, Any]) -> int:
        return self._insert_event(event)

    def _insert_event(self, event: dict[str, Any]) -> int:
        cursor = self._db.execute("INSERT INTO events (event) VALUES (?)", (json.dumps(event),))
        return int(cursor.lastrowid)

    def ack(self, cursor: int) -> None:
        self._db.execute("DELETE FROM events WHERE seq <= ?", (cursor,))

    def events_after(self, cursor: int) -> list[tuple[int, dict[str, Any]]]:
        rows = self._db.execute("SELECT seq, event FROM events WHERE seq > ? ORDER BY seq", (cursor,)).fetchall()
        return [(seq, json.loads(event)) for seq, event in rows]

    def last_seq(self) -> int:
        row = self._db.execute("SELECT seq FROM sqlite_sequence WHERE name = 'events'").fetchone()
        return int(row[0]) if row else 0

    def trim_events(self, keep: int) -> int:
        """Drops the oldest events beyond `keep` (an adapter that never polls). Returns how many."""
        cursor = self._db.execute(
            "DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq DESC LIMIT -1 OFFSET ?)", (keep,)
        )
        return cursor.rowcount

    def event_depth(self) -> int:
        return self._db.execute("SELECT COUNT(*) FROM events").fetchone()[0]

    # ---- outbox -----------------------------------------------------------------

    def queue_mail(
        self, device_id: str, mid: str, message_id: str, data: str, alert: bool, expires: float, next_try: float | None = None
    ) -> int:
        cursor = self._db.execute(
            "INSERT INTO outbox (device_id, mid, message_id, data, alert, next_try, expires) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (device_id, mid, message_id, data, int(alert), time.time() if next_try is None else next_try, expires),
        )
        return int(cursor.lastrowid)

    def due_mail(self, now: float, limit: int = 50) -> list[Mail]:
        rows = self._db.execute(
            "SELECT row, device_id, mid, message_id, data, alert, attempts, expires FROM outbox "
            "WHERE next_try <= ? ORDER BY row LIMIT ?",
            (now, limit),
        ).fetchall()
        return [Mail(r, d, m, i, data, bool(a), n, e) for r, d, m, i, data, a, n, e in rows]

    def next_mail_time(self) -> float | None:
        row = self._db.execute("SELECT MIN(next_try) FROM outbox").fetchone()
        return row[0] if row and row[0] is not None else None

    def mail_done(self, row: int) -> None:
        self._db.execute("DELETE FROM outbox WHERE row = ?", (row,))

    def mail_later(self, row: int, next_try: float) -> None:
        self._db.execute("UPDATE outbox SET attempts = attempts + 1, next_try = ? WHERE row = ?", (next_try, row))

    def forget_device(self, device_id: str) -> None:
        self._db.execute("DELETE FROM outbox WHERE device_id = ?", (device_id,))
        self._db.execute("DELETE FROM inbox WHERE device_id = ?", (device_id,))

    def outbox_depth(self) -> int:
        return self._db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]

    def queued(self, message_id: str) -> bool:
        return self._db.execute("SELECT 1 FROM outbox WHERE message_id = ? LIMIT 1", (message_id,)).fetchone() is not None

    # ---- spooled files and history ------------------------------------------------

    def add_file(self, file: StoredFile) -> None:
        self._db.execute(
            "INSERT OR REPLACE INTO files (file_id, message_id, key, kind, name, mime, size, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (file.file_id, file.message_id, file.key, file.kind, file.name, file.mime, file.size, time.time()),
        )

    def file(self, file_id: str) -> StoredFile | None:
        row = self._db.execute(
            "SELECT file_id, message_id, key, kind, name, mime, size FROM files WHERE file_id = ?", (file_id,)
        ).fetchone()
        return StoredFile(*row) if row else None

    def unused_files(self) -> list[str]:
        """Files nothing needs any more (not in history, not waiting in the inbox, event taken by Hermes);
        their rows go here, the caller deletes the files on disk."""
        with self._tx():
            rows = self._db.execute(
                "SELECT file_id FROM files WHERE message_id NOT IN (SELECT message_id FROM history) "
                "AND message_id NOT IN (SELECT message_id FROM inbox) "
                "AND (event_seq IS NULL OR event_seq NOT IN (SELECT seq FROM events))"
            ).fetchall()
            ids = [row[0] for row in rows]
            self._db.executemany("DELETE FROM files WHERE file_id = ?", [(i,) for i in ids])
        return ids

    def file_ids(self) -> set[str]:
        return {row[0] for row in self._db.execute("SELECT file_id FROM files")}

    def add_history(self, message_id: str, body: dict[str, Any], ts: int, keep: int) -> None:
        with self._tx():
            self._db.execute(
                "INSERT OR IGNORE INTO history (message_id, body, ts) VALUES (?, ?, ?)", (message_id, json.dumps(body), ts)
            )
            self._db.execute(
                "DELETE FROM history WHERE seq IN (SELECT seq FROM history ORDER BY seq DESC LIMIT -1 OFFSET ?)", (keep,)
            )

    def history_before(self, before: int | None, limit: int) -> list[tuple[int, dict[str, Any]]]:
        """Newest first: the `limit` entries older than `before` (None: the newest)."""
        rows = self._db.execute(
            "SELECT seq, body FROM history WHERE seq < ? ORDER BY seq DESC LIMIT ?", (before or 1 << 62, limit)
        ).fetchall()
        return [(seq, json.loads(body)) for seq, body in rows]

    def history_depth(self) -> int:
        return self._db.execute("SELECT COUNT(*) FROM history").fetchone()[0]

    # ---- helpers ------------------------------------------------------------------

    def _tx(self) -> "_Transaction":
        return _Transaction(self._db)


class _Transaction:
    def __init__(self, db: sqlite3.Connection) -> None:
        self._db = db

    def __enter__(self) -> None:
        self._db.execute("BEGIN IMMEDIATE")

    def __exit__(self, kind, value, traceback) -> None:
        self._db.execute("COMMIT" if kind is None else "ROLLBACK")


class AsyncStore:
    """Runs every store call on one worker thread, in submission order, off the event loop."""

    def __init__(self, store: ChatStore) -> None:
        self.store = store
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="chatdb")

    async def call(self, fn: Callable[..., T], *args: Any) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._executor, fn, *args)

    def submit(self, fn: Callable[..., Any], *args: Any) -> asyncio.Future:
        """Fire and forget, still ordered after everything submitted before."""
        return asyncio.get_running_loop().run_in_executor(self._executor, fn, *args)

    def close(self) -> None:
        self._executor.shutdown(wait=True)
        self.store.close()
