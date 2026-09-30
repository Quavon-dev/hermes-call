"""Relay database schema, versioned with `PRAGMA user_version`.

Each migration runs once, in its own transaction, and only adds (tables, columns, indexes), so the
previous relay version still runs on a migrated database after `install.sh rollback`. A database
from a newer relay is refused rather than guessed at.
"""

import logging
import sqlite3
from collections.abc import Callable

log = logging.getLogger(__name__)

# Version 1 is the schema every relay up to 0.6.2 created (without a user_version); it is written
# with IF NOT EXISTS, so it also adopts those databases, including ones from before the alert and
# Live Activity columns existed.
_V1_TABLES = (
    """CREATE TABLE IF NOT EXISTS bridges(
        id TEXT PRIMARY KEY,
        sign_pk BLOB NOT NULL,
        created INTEGER NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS devices(
        id TEXT PRIMARY KEY,
        bridge_id TEXT NOT NULL REFERENCES bridges(id) ON DELETE CASCADE,
        sign_pk BLOB NOT NULL,
        push_token TEXT,
        push_env TEXT,
        created INTEGER NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS devices_bridge ON devices(bridge_id)",
    """CREATE TABLE IF NOT EXISTS mail(
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        data TEXT NOT NULL,
        size INTEGER NOT NULL,
        created INTEGER NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS mail_device ON mail(device_id, created)",
    """CREATE TABLE IF NOT EXISTS blobs(
        id TEXT PRIMARY KEY,
        owner TEXT NOT NULL,
        sender TEXT NOT NULL,
        recipient TEXT NOT NULL,
        size INTEGER NOT NULL,
        complete INTEGER NOT NULL DEFAULT 0,
        created INTEGER NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS blobs_recipient ON blobs(recipient)",
    """CREATE TABLE IF NOT EXISTS relay_codes(
        slot TEXT PRIMARY KEY,
        secret TEXT NOT NULL,
        expires INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
    )""",
)
# Added after v0.4: the alert-push token (chat notifications) and, since M9, the Live Activity
# tokens (one for the running activity, one for push-to-start).
_V1_DEVICE_COLUMNS = ("alert_token", "alert_env", "la_token", "la_env", "la_start_token", "la_start_env")


def _v1(db: sqlite3.Connection) -> None:
    for statement in _V1_TABLES:
        db.execute(statement)
    columns = {row[1] for row in db.execute("PRAGMA table_info(devices)")}
    for column in _V1_DEVICE_COLUMNS:
        if column not in columns:
            db.execute(f"ALTER TABLE devices ADD COLUMN {column} TEXT")


def _v2(db: sqlite3.Connection) -> None:
    """Indexes for the background expiry sweep (mail and blobs by age)."""
    db.execute("CREATE INDEX IF NOT EXISTS mail_created ON mail(created)")
    db.execute("CREATE INDEX IF NOT EXISTS blobs_created ON blobs(created)")


MIGRATIONS: tuple[Callable[[sqlite3.Connection], None], ...] = (_v1, _v2)
LATEST = len(MIGRATIONS)


class SchemaError(Exception):
    pass


def version(db: sqlite3.Connection) -> int:
    return db.execute("PRAGMA user_version").fetchone()[0]


def migrate(db: sqlite3.Connection) -> int:
    """Brings the database to LATEST; returns the version it started at."""
    start = version(db)
    if start > LATEST:
        raise SchemaError(f"database schema {start} is newer than this relay ({LATEST}); update the relay")
    if start == 0 and not db.execute("SELECT 1 FROM sqlite_master WHERE name = 'bridges'").fetchone():
        # Only takes effect on an empty file (before WAL mode writes the header); older files are
        # converted later by Store.vacuum_step or `hermescall-relay compact`.
        db.execute("PRAGMA auto_vacuum=INCREMENTAL")
    db.execute("PRAGMA journal_mode=WAL")
    for number in range(start + 1, LATEST + 1):
        db.execute("BEGIN IMMEDIATE")
        try:
            MIGRATIONS[number - 1](db)
            db.execute(f"PRAGMA user_version = {number}")
        except BaseException:
            db.execute("ROLLBACK")
            raise
        db.execute("COMMIT")
        if start:
            log.info("database migrated to schema %s", number)
    return start


def auto_vacuum_mode(db: sqlite3.Connection) -> int:
    """0 = none, 1 = full, 2 = incremental."""
    return db.execute("PRAGMA auto_vacuum").fetchone()[0]
