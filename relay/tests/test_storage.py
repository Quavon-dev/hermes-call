"""Schema migrations, expiry, disk budget and backups of the relay database."""

import dataclasses
import os
import sqlite3
import tarfile
import time
from pathlib import Path

import pytest

from hermescall_relay import backup, schema
from hermescall_relay.limits import Limits
from hermescall_relay.store import Store

# The schema relay 0.6.2 and older created, verbatim, with no user_version.
SCHEMA_0_6_2 = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS bridges(id TEXT PRIMARY KEY, sign_pk BLOB NOT NULL, created INTEGER NOT NULL);
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
    id TEXT PRIMARY KEY, owner TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL,
    size INTEGER NOT NULL, complete INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS blobs_recipient ON blobs(recipient);
CREATE TABLE IF NOT EXISTS relay_codes(
    slot TEXT PRIMARY KEY, secret TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
);
"""
BRIDGE = "B" * 22
DEVICE = "D" * 22


def _old_database(path: Path, with_late_columns: bool = True) -> None:
    db = sqlite3.connect(str(path))
    db.executescript(SCHEMA_0_6_2)
    if with_late_columns:
        for column in ("alert_token", "alert_env", "la_token", "la_env", "la_start_token", "la_start_env"):
            db.execute(f"ALTER TABLE devices ADD COLUMN {column} TEXT")
    db.execute("INSERT INTO bridges VALUES(?, ?, ?)", (BRIDGE, b"k" * 32, 1))
    db.execute("INSERT INTO devices(id, bridge_id, sign_pk, push_token, push_env, created) VALUES(?, ?, ?, ?, ?, ?)",
               (DEVICE, BRIDGE, b"p" * 32, "ab" * 32, "production", 2))  # fmt: skip
    db.execute("INSERT INTO mail VALUES(?, ?, ?, ?, ?)", ("M" * 22, DEVICE, "data", 4, int(time.time())))
    db.commit()
    db.close()


@pytest.mark.parametrize("late_columns", [True, False], ids=["0.6.2", "0.4"])
def test_migrates_an_old_database_and_keeps_its_data(tmp_path: Path, late_columns: bool) -> None:
    path = tmp_path / "relay.db"
    _old_database(path, late_columns)
    store = Store(path)
    assert store.schema_version == schema.LATEST
    device = store.device(DEVICE)
    assert device is not None and device.push_token == "ab" * 32 and device.alert_token is None
    assert store.pending_mail(DEVICE) == [("M" * 22, "data")]
    indexes = {row[0] for row in store._db.execute("SELECT name FROM sqlite_master WHERE type = 'index'")}
    assert {"mail_created", "blobs_created", "mail_device"} <= indexes
    store.close()
    # Opening again runs nothing twice.
    assert Store(path).schema_version == schema.LATEST


def test_new_database_uses_incremental_vacuum(tmp_path: Path) -> None:
    store = Store(tmp_path / "relay.db")
    assert schema.auto_vacuum_mode(store._db) == 2
    assert store.schema_version == schema.LATEST


def test_newer_database_runs_when_compatible_and_is_refused_when_not(tmp_path: Path) -> None:
    path = tmp_path / "relay.db"
    Store(path).close()
    db = sqlite3.connect(str(path))
    db.execute(f"PRAGMA user_version = {schema.LATEST + 1}")
    db.commit()
    db.close()
    assert Store(path).schema_version == schema.LATEST + 1  # e.g. after install.sh rollback
    db = sqlite3.connect(str(path))
    db.execute("UPDATE meta SET value = ? WHERE key = 'min_reader'", (schema.LATEST + 1,))
    db.commit()
    db.close()
    with pytest.raises(schema.SchemaError):
        Store(path)


def test_failed_migration_rolls_back(tmp_path: Path, monkeypatch) -> None:
    path = tmp_path / "relay.db"
    _old_database(path)

    def broken(db):
        db.execute("CREATE INDEX half_done ON mail(size)")
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(schema, "MIGRATIONS", (schema.MIGRATIONS[0], broken))
    monkeypatch.setattr(schema, "LATEST", 2)
    with pytest.raises(sqlite3.OperationalError):
        Store(path)
    db = sqlite3.connect(str(path))
    assert db.execute("PRAGMA user_version").fetchone()[0] == 1
    assert not db.execute("SELECT 1 FROM sqlite_master WHERE name = 'half_done'").fetchone()


def test_expire_removes_old_mail_without_new_traffic(tmp_path: Path) -> None:
    store = Store(tmp_path / "relay.db")
    bridge = store.add_bridge(b"k" * 32)
    device = store.add_device(bridge, b"p" * 32)
    long_ago = time.time() - store.limits.mail_ttl_seconds - 10
    assert store.add_mail("C" * 22, device, "new") == "ok"
    assert store.add_mail("A" * 22, device, "old", now=long_ago) == "ok"
    assert store.expire() == 1
    assert [mail_id for mail_id, _ in store.pending_mail(device)] == ["C" * 22]


def test_global_storage_cap_and_free_space_floor(tmp_path: Path, monkeypatch) -> None:
    store = Store(tmp_path / "relay.db", Limits(storage_max_bytes=100))
    bridge = store.add_bridge(b"k" * 32)
    device = store.add_device(bridge, b"p" * 32)
    assert store.add_mail("A" * 22, device, "x" * 60) == "ok"
    assert store.add_mail("C" * 22, device, "x" * 60) == "full"
    # The retry of a mail that is already stored is not "full".
    assert store.add_mail("A" * 22, device, "x" * 60) == "duplicate"
    assert not store.add_blob("E" * 22, bridge, bridge, device, 50)
    assert store.add_blob("F" * 22, bridge, bridge, device, 40)
    roomy = Store(tmp_path / "other.db", Limits(min_free_bytes=10**6))
    monkeypatch.setattr(Store, "free_bytes_at", staticmethod(lambda path: 10**6 + 10))
    assert roomy.has_room(10) and not roomy.has_room(11)


def test_vacuum_step_returns_space(tmp_path: Path) -> None:
    store = Store(tmp_path / "relay.db")
    bridge = store.add_bridge(b"k" * 32)
    device = store.add_device(bridge, b"p" * 32)
    for n in range(40):
        store.add_mail(f"{n:022d}", device, "x" * 40_000)
    store._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    big = store.path.stat().st_size
    store.ack_mail(device, [f"{n:022d}" for n in range(40)])
    assert store.vacuum_step() > 0
    store._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    assert store.path.stat().st_size < big / 2


def test_old_database_is_converted_when_mostly_empty(tmp_path: Path) -> None:
    path = tmp_path / "relay.db"
    _old_database(path)
    store = Store(path)
    assert schema.auto_vacuum_mode(store._db) == 0
    for n in range(20):
        store.add_mail(f"{n:022d}", DEVICE, "x" * 40_000)
    store.ack_mail(DEVICE, [f"{n:022d}" for n in range(20)])
    store.vacuum_step()
    assert schema.auto_vacuum_mode(store._db) == 2


def _config(tmp_path: Path):
    from .conftest import make_config

    secrets = tmp_path / "etc"
    secrets.mkdir()
    (secrets / "turn_secret").write_text("t0ps3cret\n")
    (secrets / "relay.toml").write_text('authority = "relay.test"\n')
    return dataclasses.replace(make_config(tmp_path), secrets_dir=secrets), secrets / "relay.toml"


def test_backup_and_restore_roundtrip(tmp_path: Path) -> None:
    config, config_path = _config(tmp_path)
    store = Store(config.db_path)
    bridge = store.add_bridge(b"k" * 32)
    archive = tmp_path / "out" / "backup.tar.gz"
    backup.create(config, config_path, archive)
    assert os.stat(archive).st_mode & 0o777 == 0o600
    with tarfile.open(archive) as tar:
        names = tar.getnames()
    assert "relay.db" in names and f"files{config.secrets_dir.resolve()}/turn_secret" in names
    # Disaster: the database and a secret are gone.
    store.delete_bridge(bridge)
    store.close()
    for suffix in ("", "-wal", "-shm"):
        Path(f"{config.db_path}{suffix}").unlink(missing_ok=True)
    (config.secrets_dir / "turn_secret").unlink()
    backup.restore(archive, config.db_path, [config.secrets_dir.resolve()])
    assert Store(config.db_path).bridge_key(bridge) == b"k" * 32
    assert (config.secrets_dir / "turn_secret").read_text() == "t0ps3cret\n"
    assert os.stat(config.secrets_dir / "turn_secret").st_mode & 0o777 == 0o600


def test_restore_refuses_files_outside_the_relay_directories(tmp_path: Path) -> None:
    config, config_path = _config(tmp_path)
    Store(config.db_path).close()
    archive = tmp_path / "backup.tar.gz"
    backup.create(config, config_path, archive)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    with pytest.raises(backup.BackupError):
        backup.restore(archive, config.db_path, [elsewhere])


def test_restore_refuses_a_corrupt_database(tmp_path: Path) -> None:
    config, config_path = _config(tmp_path)
    Store(config.db_path).close()
    archive = tmp_path / "backup.tar.gz"
    backup.create(config, config_path, archive)
    with tarfile.open(archive) as tar:
        members = {m.name: tar.extractfile(m).read() for m in tar.getmembers()}
    members["relay.db"] = b"not a database"
    with tarfile.open(archive, "w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            import io

            tar.addfile(info, io.BytesIO(data))
    with pytest.raises(backup.BackupError):
        backup.restore(archive, config.db_path, [config.secrets_dir.resolve()])
