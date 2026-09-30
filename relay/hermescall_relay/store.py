import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from hermescall_common import codes, sodium
from hermescall_common.wire import b64e

MAX_CODE_ATTEMPTS = 3
CODE_TTL_SECONDS = 600
PUSH_ENVS = ("sandbox", "production")
# Mailbox for chat messages to offline phones: ciphertext only, bounded per device.
MAIL_MAX_MESSAGES = 500
MAIL_MAX_BYTES = 20 * 1024 * 1024
MAIL_TTL_SECONDS = 7 * 86_400
# Encrypted attachments (random key inside the E2E message), bounded per recipient.
BLOB_MAX_BYTES = 10 * 1024 * 1024 + 64
BLOB_MAX_PER_RECIPIENT = 20
BLOB_QUOTA_BYTES = 50 * 1024 * 1024
BLOB_TTL_SECONDS = 7 * 86_400
# Columns added after v0.4: the alert-push token (chat notifications) and, since M9, the
# Live Activity tokens (one for the running activity, one for push-to-start).
_DEVICE_COLUMNS = ("alert_token", "alert_env", "la_token", "la_env", "la_start_token", "la_start_env")
_DEVICE_SELECT = (
    "SELECT id, bridge_id, sign_pk, push_token, push_env, created, alert_token, alert_env,"
    " la_token, la_env, la_start_token, la_start_env FROM devices"
)
LIVE_KINDS = {"liveactivity": ("la_token", "la_env"), "liveactivity_start": ("la_start_token", "la_start_env")}

_SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS bridges(
    id TEXT PRIMARY KEY,
    sign_pk BLOB NOT NULL,
    created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices(
    id TEXT PRIMARY KEY,
    bridge_id TEXT NOT NULL REFERENCES bridges(id) ON DELETE CASCADE,
    sign_pk BLOB NOT NULL,
    push_token TEXT,
    push_env TEXT,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_bridge ON devices(bridge_id);
CREATE TABLE IF NOT EXISTS mail(
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    data TEXT NOT NULL,
    size INTEGER NOT NULL,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS mail_device ON mail(device_id, created);
CREATE TABLE IF NOT EXISTS blobs(
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    sender TEXT NOT NULL,
    recipient TEXT NOT NULL,
    size INTEGER NOT NULL,
    complete INTEGER NOT NULL DEFAULT 0,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS blobs_recipient ON blobs(recipient);
CREATE TABLE IF NOT EXISTS relay_codes(
    slot TEXT PRIMARY KEY,
    secret TEXT NOT NULL,
    expires INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0
);
"""


@dataclass(frozen=True)
class Device:
    id: str
    bridge_id: str
    sign_pk: bytes
    push_token: str | None
    push_env: str | None
    created: int
    alert_token: str | None = None
    alert_env: str | None = None
    la_token: str | None = None
    la_env: str | None = None
    la_start_token: str | None = None
    la_start_env: str | None = None


def new_id() -> str:
    return b64e(sodium.random_bytes(16))


class Store:
    def __init__(self, path: Path | str) -> None:
        self._db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.execute("PRAGMA busy_timeout=2000")
        self._db.executescript(_SCHEMA)
        columns = {row[1] for row in self._db.execute("PRAGMA table_info(devices)")}
        for column in _DEVICE_COLUMNS:
            if column not in columns:
                self._db.execute(f"ALTER TABLE devices ADD COLUMN {column} TEXT")

    def close(self) -> None:
        self._db.close()

    def create_relay_code(self, now: float | None = None) -> codes.Code:
        now = int(time.time() if now is None else now)
        self._db.execute("DELETE FROM relay_codes WHERE expires <= ?", (now,))
        taken = {row[0] for row in self._db.execute("SELECT slot FROM relay_codes")}
        code = codes.new_code(codes.new_relay_slot())
        while code.slot in taken:
            code = codes.new_code(codes.new_relay_slot())
        self._db.execute(
            "INSERT INTO relay_codes(slot, secret, expires) VALUES(?, ?, ?)",
            (code.slot, code.secret, now + CODE_TTL_SECONDS),
        )
        return code

    def consume_relay_code_attempt(self, slot: str) -> str | None:
        row = self._db.execute(
            "UPDATE relay_codes SET attempts = attempts + 1 WHERE slot = ? AND expires > ? AND attempts < ? RETURNING secret",
            (slot, int(time.time()), MAX_CODE_ATTEMPTS),
        ).fetchone()
        return row[0] if row else None

    def delete_relay_code(self, slot: str) -> None:
        self._db.execute("DELETE FROM relay_codes WHERE slot = ?", (slot,))

    def add_bridge(self, sign_pk: bytes) -> str:
        bridge_id = new_id()
        self._db.execute("INSERT INTO bridges(id, sign_pk, created) VALUES(?, ?, ?)", (bridge_id, sign_pk, int(time.time())))
        return bridge_id

    def bridge_key(self, bridge_id: str) -> bytes | None:
        row = self._db.execute("SELECT sign_pk FROM bridges WHERE id = ?", (bridge_id,)).fetchone()
        return row[0] if row else None

    def list_bridges(self) -> list[tuple[str, int, int]]:
        return self._db.execute(
            "SELECT b.id, b.created, COUNT(d.id) FROM bridges b LEFT JOIN devices d ON d.bridge_id = b.id"
            " GROUP BY b.id ORDER BY b.created"
        ).fetchall()

    def delete_bridge(self, bridge_id: str) -> bool:
        return self._db.execute("DELETE FROM bridges WHERE id = ?", (bridge_id,)).rowcount > 0

    def add_device(self, bridge_id: str, sign_pk: bytes) -> str:
        device_id = new_id()
        self._db.execute(
            "INSERT INTO devices(id, bridge_id, sign_pk, created) VALUES(?, ?, ?, ?)",
            (device_id, bridge_id, sign_pk, int(time.time())),
        )
        return device_id

    def device(self, device_id: str) -> Device | None:
        row = self._db.execute(f"{_DEVICE_SELECT} WHERE id = ?", (device_id,)).fetchone()  # noqa: S608
        return Device(*row) if row else None

    def devices_of(self, bridge_id: str) -> list[Device]:
        rows = self._db.execute(f"{_DEVICE_SELECT} WHERE bridge_id = ? ORDER BY created", (bridge_id,)).fetchall()  # noqa: S608
        return [Device(*row) for row in rows]

    def delete_device(self, bridge_id: str, device_id: str) -> bool:
        return self._db.execute("DELETE FROM devices WHERE id = ? AND bridge_id = ?", (device_id, bridge_id)).rowcount > 0

    def set_push_token(self, device_id: str, token: str | None, env: str | None) -> None:
        self._db.execute("UPDATE devices SET push_token = ?, push_env = ? WHERE id = ?", (token, env, device_id))

    def set_alert_token(self, device_id: str, token: str | None, env: str | None) -> None:
        self._db.execute("UPDATE devices SET alert_token = ?, alert_env = ? WHERE id = ?", (token, env, device_id))

    def set_live_token(self, device_id: str, kind: str, token: str | None, env: str | None) -> None:
        """`kind`: liveactivity (the running activity's token) or liveactivity_start (push-to-start)."""
        token_column, env_column = LIVE_KINDS[kind]
        self._db.execute(f"UPDATE devices SET {token_column} = ?, {env_column} = ? WHERE id = ?", (token, env, device_id))  # noqa: S608

    # ---- mailbox -------------------------------------------------------

    def add_mail(self, mail_id: str, device_id: str, data: str, now: float | None = None) -> str:
        """Returns "ok", "duplicate" or "full"."""
        now = int(time.time() if now is None else now)
        self._db.execute("DELETE FROM mail WHERE created <= ?", (now - MAIL_TTL_SECONDS,))
        count, size = self._db.execute(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM mail WHERE device_id = ?", (device_id,)
        ).fetchone()
        if count >= MAIL_MAX_MESSAGES or size + len(data) > MAIL_MAX_BYTES:
            return "full"
        cursor = self._db.execute(
            "INSERT OR IGNORE INTO mail(id, device_id, data, size, created) VALUES(?, ?, ?, ?, ?)",
            (mail_id, device_id, data, len(data), now),
        )
        return "ok" if cursor.rowcount else "duplicate"

    def pending_mail(self, device_id: str, limit: int = 100, now: float | None = None) -> list[tuple[str, str]]:
        now = int(time.time() if now is None else now)
        return self._db.execute(
            "SELECT id, data FROM mail WHERE device_id = ? AND created > ? ORDER BY created, rowid LIMIT ?",
            (device_id, now - MAIL_TTL_SECONDS, limit),
        ).fetchall()

    def has_mail(self, device_id: str, mail_id: str) -> bool:
        return self._db.execute("SELECT 1 FROM mail WHERE id = ? AND device_id = ?", (mail_id, device_id)).fetchone() is not None

    def ack_mail(self, device_id: str, mail_ids: list[str]) -> int:
        marks = ",".join("?" * len(mail_ids))
        return self._db.execute(f"DELETE FROM mail WHERE device_id = ? AND id IN ({marks})", (device_id, *mail_ids)).rowcount  # noqa: S608

    # ---- blobs ---------------------------------------------------------

    def add_blob(self, blob_id: str, owner: str, sender: str, recipient: str, size: int, now: float | None = None) -> bool:
        """Reserves space for an upload; False when the recipient's quota is used up."""
        now = int(time.time() if now is None else now)
        count, used = self._db.execute(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM blobs WHERE recipient = ? AND created > ?",
            (recipient, now - BLOB_TTL_SECONDS),
        ).fetchone()
        if count >= BLOB_MAX_PER_RECIPIENT or used + size > BLOB_QUOTA_BYTES:
            return False
        self._db.execute(
            "INSERT INTO blobs(id, owner, sender, recipient, size, created) VALUES(?, ?, ?, ?, ?, ?)",
            (blob_id, owner, sender, recipient, size, now),
        )
        return True

    def blob(self, blob_id: str) -> tuple[str, str, str, int, bool] | None:
        """(owner bridge, sender, recipient, size, complete)"""
        row = self._db.execute("SELECT owner, sender, recipient, size, complete FROM blobs WHERE id = ?", (blob_id,)).fetchone()
        return (row[0], row[1], row[2], row[3], bool(row[4])) if row else None

    def complete_blob(self, blob_id: str, size: int) -> None:
        self._db.execute("UPDATE blobs SET complete = 1, size = ? WHERE id = ?", (size, blob_id))

    def delete_blob(self, blob_id: str) -> None:
        self._db.execute("DELETE FROM blobs WHERE id = ?", (blob_id,))

    def expired_blobs(self, now: float | None = None, incomplete_after: int = 900) -> list[str]:
        """Blobs past their TTL, uploads never finished, and blobs whose owner bridge is gone."""
        now = int(time.time() if now is None else now)
        rows = self._db.execute(
            "SELECT id FROM blobs WHERE created <= ? OR (complete = 0 AND created <= ?) OR owner NOT IN (SELECT id FROM bridges)",
            (now - BLOB_TTL_SECONDS, now - incomplete_after),
        ).fetchall()
        return [row[0] for row in rows]

    def blob_ids(self) -> set[str]:
        return {row[0] for row in self._db.execute("SELECT id FROM blobs")}

    def identity_exists(self, role: str, identity: str) -> bool:
        query = "SELECT 1 FROM bridges WHERE id = ?" if role == "bridge" else "SELECT 1 FROM devices WHERE id = ?"
        return self._db.execute(query, (identity,)).fetchone() is not None
