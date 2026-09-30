import shutil
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from hermescall_common import codes, sodium
from hermescall_common.wire import b64e

from . import schema
from .limits import Limits

MAX_CODE_ATTEMPTS = 3
CODE_TTL_SECONDS = 600
PUSH_ENVS = ("sandbox", "production")
# Defaults of the mailbox and attachment quotas (see limits.Limits; relay.toml can change them).
MAIL_MAX_MESSAGES = Limits.mail_max_messages
MAIL_MAX_BYTES = Limits.mail_max_bytes
MAIL_TTL_SECONDS = Limits.mail_ttl_seconds
# Encrypted attachments (random key inside the E2E message): the app's size limit, not a setting.
BLOB_MAX_BYTES = 10 * 1024 * 1024 + 64
BLOB_MAX_PER_RECIPIENT = Limits.blob_max_per_recipient
BLOB_QUOTA_BYTES = Limits.blob_quota_bytes
BLOB_TTL_SECONDS = Limits.blob_ttl_seconds
_DEVICE_SELECT = (
    "SELECT id, bridge_id, sign_pk, push_token, push_env, created, alert_token, alert_env,"
    " la_token, la_env, la_start_token, la_start_env FROM devices"
)
LIVE_KINDS = {"liveactivity": ("la_token", "la_env"), "liveactivity_start": ("la_start_token", "la_start_env")}
# Free pages reclaimed per maintenance round (4 KiB each): a few MB at a time, never a long lock.
VACUUM_PAGES = 2048
# Older databases (no incremental auto-vacuum) are converted online only up to this size.
COMPACT_ONLINE_BYTES = 64 * 1024 * 1024


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


@dataclass(frozen=True)
class Usage:
    bridges: int
    devices: int
    mail_count: int
    mail_bytes: int
    blob_count: int
    blob_bytes: int

    @property
    def stored_bytes(self) -> int:
        return self.mail_bytes + self.blob_bytes


def new_id() -> str:
    return b64e(sodium.random_bytes(16))


class Store:
    def __init__(self, path: Path | str, limits: Limits | None = None) -> None:
        self.path = Path(path)
        self.limits = limits or Limits()
        self._db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.execute("PRAGMA busy_timeout=2000")
        schema.migrate(self._db)

    @property
    def schema_version(self) -> int:
        return self._db.execute("PRAGMA user_version").fetchone()[0]

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

    def device_count(self, bridge_id: str) -> int:
        return self._db.execute("SELECT COUNT(*) FROM devices WHERE bridge_id = ?", (bridge_id,)).fetchone()[0]

    def device(self, device_id: str) -> Device | None:
        row = self._db.execute(f"{_DEVICE_SELECT} WHERE id = ?", (device_id,)).fetchone()  # noqa: S608
        return Device(*row) if row else None

    def devices_of(self, bridge_id: str) -> list[Device]:
        rows = self._db.execute(f"{_DEVICE_SELECT} WHERE bridge_id = ? ORDER BY created", (bridge_id,)).fetchall()  # noqa: S608
        return [Device(*row) for row in rows]

    def all_devices(self) -> list[Device]:
        return [Device(*row) for row in self._db.execute(f"{_DEVICE_SELECT} ORDER BY bridge_id, created")]  # noqa: S608

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

    # ---- storage -------------------------------------------------------

    def usage(self) -> Usage:
        bridges, devices = self._db.execute("SELECT (SELECT COUNT(*) FROM bridges), (SELECT COUNT(*) FROM devices)").fetchone()
        mail_count, mail_bytes = self._db.execute("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM mail").fetchone()
        blob_count, blob_bytes = self._db.execute("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM blobs").fetchone()
        return Usage(bridges, devices, mail_count, mail_bytes, blob_count, blob_bytes)

    def stored_bytes(self) -> int:
        return self._db.execute(
            "SELECT (SELECT COALESCE(SUM(size), 0) FROM mail) + (SELECT COALESCE(SUM(size), 0) FROM blobs)"
        ).fetchone()[0]

    def free_bytes(self) -> int:
        return self.free_bytes_at(self.path)

    @staticmethod
    def free_bytes_at(db_path: Path) -> int:
        return shutil.disk_usage(Path(db_path).parent).free

    def has_room(self, extra: int) -> bool:
        """Global cap for mailbox + attachments, and the free space the data volume must keep."""
        if self.stored_bytes() + extra > self.limits.storage_max_bytes:
            return False
        try:
            return self.free_bytes() - extra >= self.limits.min_free_bytes
        except OSError:
            return False

    def expire(self, now: float | None = None) -> int:
        """Deletes mail past its TTL; returns how many (blobs are expired by the relay, with their files)."""
        now = int(time.time() if now is None else now)
        return self._db.execute("DELETE FROM mail WHERE created <= ?", (now - self.limits.mail_ttl_seconds,)).rowcount

    def vacuum_step(self) -> int:
        """Returns free pages to the file system a little at a time; returns the free page count.

        New databases use auto_vacuum=INCREMENTAL. One created by relay 0.6.2 or older is converted
        by a full VACUUM once it is mostly empty space and still small; larger ones: `compact`.
        """
        free = self._db.execute("PRAGMA freelist_count").fetchone()[0]
        if not free:
            return 0
        if schema.auto_vacuum_mode(self._db) == 2:
            self._db.execute(f"PRAGMA incremental_vacuum({min(free, VACUUM_PAGES)})").fetchall()
            return free
        pages, page_size = (self._db.execute(f"PRAGMA {name}").fetchone()[0] for name in ("page_count", "page_size"))
        if free * 4 >= pages and pages * page_size <= COMPACT_ONLINE_BYTES:
            self.compact()
        return free

    def compact(self) -> None:
        """Full VACUUM, switching the file to incremental auto-vacuum (locks the database meanwhile)."""
        self._db.execute("PRAGMA auto_vacuum=INCREMENTAL")
        self._db.execute("VACUUM")

    def writable(self) -> bool:
        try:
            self._db.execute("BEGIN IMMEDIATE")
            self._db.execute("ROLLBACK")
        except sqlite3.Error:
            return False
        return True

    def backup_to(self, target: Path) -> None:
        """Consistent online copy (SQLite backup API): safe while the relay is running."""
        destination = sqlite3.connect(str(target))
        try:
            self._db.backup(destination)
        finally:
            destination.close()

    # ---- mailbox -------------------------------------------------------

    def add_mail(self, mail_id: str, device_id: str, data: str, now: float | None = None) -> str:
        """Returns "ok", "duplicate" or "full"."""
        now = int(time.time() if now is None else now)
        limits = self.limits
        self.expire(now)
        count, size = self._db.execute(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM mail WHERE device_id = ?", (device_id,)
        ).fetchone()
        if count >= limits.mail_max_messages or size + len(data) > limits.mail_max_bytes or not self.has_room(len(data)):
            return "duplicate" if self.has_mail(device_id, mail_id) else "full"
        cursor = self._db.execute(
            "INSERT OR IGNORE INTO mail(id, device_id, data, size, created) VALUES(?, ?, ?, ?, ?)",
            (mail_id, device_id, data, len(data), now),
        )
        return "ok" if cursor.rowcount else "duplicate"

    def pending_mail(self, device_id: str, limit: int = 100, now: float | None = None) -> list[tuple[str, str]]:
        now = int(time.time() if now is None else now)
        return self._db.execute(
            "SELECT id, data FROM mail WHERE device_id = ? AND created > ? ORDER BY created, rowid LIMIT ?",
            (device_id, now - self.limits.mail_ttl_seconds, limit),
        ).fetchall()

    def has_mail(self, device_id: str, mail_id: str) -> bool:
        return self._db.execute("SELECT 1 FROM mail WHERE id = ? AND device_id = ?", (mail_id, device_id)).fetchone() is not None

    def ack_mail(self, device_id: str, mail_ids: list[str]) -> int:
        marks = ",".join("?" * len(mail_ids))
        return self._db.execute(f"DELETE FROM mail WHERE device_id = ? AND id IN ({marks})", (device_id, *mail_ids)).rowcount  # noqa: S608

    # ---- blobs ---------------------------------------------------------

    def add_blob(self, blob_id: str, owner: str, sender: str, recipient: str, size: int, now: float | None = None) -> bool:
        """Reserves space for an upload; False when the recipient's quota or the relay's disk budget is used up."""
        now = int(time.time() if now is None else now)
        limits = self.limits
        count, used = self._db.execute(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM blobs WHERE recipient = ? AND created > ?",
            (recipient, now - limits.blob_ttl_seconds),
        ).fetchone()
        if count >= limits.blob_max_per_recipient or used + size > limits.blob_quota_bytes or not self.has_room(size):
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
            (now - self.limits.blob_ttl_seconds, now - incomplete_after),
        ).fetchall()
        return [row[0] for row in rows]

    def blob_ids(self) -> set[str]:
        return {row[0] for row in self._db.execute("SELECT id FROM blobs")}

    def identity_exists(self, role: str, identity: str) -> bool:
        query = "SELECT 1 FROM bridges WHERE id = ?" if role == "bridge" else "SELECT 1 FROM devices WHERE id = ?"
        return self._db.execute(query, (identity,)).fetchone() is not None
