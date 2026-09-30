"""Relay backup and restore: one tar.gz (mode 600) with a consistent database copy and the config.

    hermescall-relay backup /root/relay-backup.tar.gz [--include /etc/caddy/hermescall]
    hermescall-relay restore /root/relay-backup.tar.gz        (relay stopped)

The database is copied with SQLite's online backup API, so a running relay is fine. The archive
holds the relay's secrets (TURN secret, push gateway key, APNs key, TLS key with --include): keep
it like a password. Restore writes only the files the archive lists, only below the directories
they came from, and never follows links.
"""

import io
import json
import os
import sqlite3
import tarfile
import tempfile
import time
from pathlib import Path, PurePosixPath

from . import schema
from .config import Config
from .version import VERSION

MANIFEST = "manifest.json"
DATABASE = "relay.db"
FILES = "files"
MAX_FILE_BYTES = 1024 * 1024
MAX_DATABASE_BYTES = 8 * 1024 * 1024 * 1024
FORMAT = 1


class BackupError(Exception):
    pass


def _add_bytes(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    info.mtime = int(time.time())
    tar.addfile(info, io.BytesIO(data))


def _config_files(config: Config, config_path: Path, include: list[Path]) -> list[Path]:
    """Regular files directly in the secrets directory, the config file and any --include directories."""
    roots = [config.secrets_dir, *include]
    files: list[Path] = [config_path.resolve()]
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.iterdir()):
            if path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_FILE_BYTES:
                files.append(path.resolve())
    return sorted(set(files))


def create(config: Config, config_path: Path, target: Path, include: list[Path] | None = None) -> list[str]:
    """Writes the archive atomically with mode 600; returns the member names."""
    include = include or []
    target = target.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if not config.db_path.is_file():
        raise BackupError(f"no database at {config.db_path}")
    source = sqlite3.connect(str(config.db_path))
    with tempfile.TemporaryDirectory(dir=target.parent) as work:
        copy = Path(work) / DATABASE
        destination = sqlite3.connect(str(copy))
        try:
            source.backup(destination)
            version = schema.version(destination)
        finally:
            destination.close()
            source.close()
        files = _config_files(config, config_path, include)
        manifest = {
            "format": FORMAT,
            "relay": VERSION,
            "schema": version,
            "created": int(time.time()),
            "db_path": str(config.db_path),
            "files": [str(path) for path in files],
        }
        partial = Path(work) / "backup.tar.gz"
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as raw, tarfile.open(fileobj=raw, mode="w:gz") as tar:
            _add_bytes(tar, MANIFEST, json.dumps(manifest, indent=1).encode())
            _add_bytes(tar, DATABASE, copy.read_bytes())
            for path in files:
                _add_bytes(tar, f"{FILES}{path}", path.read_bytes())
        os.replace(partial, target)
    os.chmod(target, 0o600)
    return [MANIFEST, DATABASE, *(f"{FILES}{path}" for path in files)]


def _read(tar: tarfile.TarFile, name: str, limit: int = MAX_FILE_BYTES) -> bytes:
    try:
        member = tar.getmember(name)
    except KeyError as exc:
        raise BackupError(f"{name} missing from the backup") from exc
    if not member.isfile() or member.size > limit:
        raise BackupError(f"{name}: not a regular file")
    handle = tar.extractfile(member)
    if handle is None:
        raise BackupError(f"{name}: unreadable")
    return handle.read()


def _write(path: Path, data: bytes) -> None:
    """Atomically, mode 600, owned like the file it replaces (or like its directory): a restore
    run as root must leave the service user's keys and database readable by that user."""
    path.parent.mkdir(parents=True, exist_ok=True)
    reference = path if path.exists() else path.parent
    owner = reference.stat()
    partial = path.with_name(f".{path.name}.restore")
    partial.unlink(missing_ok=True)
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    if os.geteuid() == 0:
        os.chown(partial, owner.st_uid, owner.st_gid)
    os.replace(partial, path)


def _allowed(path: str, roots: list[Path]) -> Path:
    pure = PurePosixPath(path)
    if not pure.is_absolute() or ".." in pure.parts:
        raise BackupError(f"refusing path {path}")
    resolved = Path(pure)
    if not any(resolved.parent == root or root in resolved.parents for root in roots):
        raise BackupError(f"refusing path outside the relay's directories: {path}")
    return resolved


def restore(archive: Path, db_path: Path, roots: list[Path]) -> dict:
    """Restores the database to `db_path` and the archived files that lie directly in (or below) `roots`.

    Returns the manifest. The relay must be stopped: its open database would be replaced under it.
    """
    with tarfile.open(archive, mode="r:gz") as tar:
        manifest = json.loads(_read(tar, MANIFEST))
        if manifest.get("format") != FORMAT:
            raise BackupError("unknown backup format")
        if int(manifest.get("schema", 0)) > schema.LATEST:
            raise BackupError(f"backup is from a newer relay ({manifest.get('relay')}); update this relay first")
        files = [str(item) for item in manifest.get("files", [])]
        planned = [(_allowed(item, roots), _read(tar, f"{FILES}{item}")) for item in files]
        database = _read(tar, DATABASE, MAX_DATABASE_BYTES)
    _check_database(database)
    if db_path.exists():
        # The database being replaced stays next to it until the next restore.
        _write(db_path.with_name(f"{db_path.name}.pre-restore"), db_path.read_bytes())
    for path, data in planned:
        _write(path, data)
    for suffix in ("-wal", "-shm"):
        Path(f"{db_path}{suffix}").unlink(missing_ok=True)
    _write(db_path, database)
    return manifest


def _check_database(data: bytes) -> None:
    if not data.startswith(b"SQLite format 3\x00"):
        raise BackupError("backup database is not an SQLite file")
    with tempfile.TemporaryDirectory() as work:
        probe = Path(work) / "probe.db"
        probe.write_bytes(data)
        db = sqlite3.connect(str(probe))
        try:
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise BackupError("backup database failed its integrity check")
            if schema.version(db) > schema.LATEST and schema.min_reader(db) > schema.LATEST:
                raise BackupError("backup database is from a newer relay; update this relay first")
        except sqlite3.DatabaseError as exc:
            raise BackupError(f"backup database is unreadable: {exc}") from exc
        finally:
            db.close()
