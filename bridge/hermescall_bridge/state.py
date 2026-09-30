"""Persistent bridge state: identity keys, relay pairing and paired devices."""

import json
import logging
import os
import tempfile
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from pathlib import Path

from hermescall_common.client import RelayEndpoint, new_identity_keys
from hermescall_common.wire import b64d

log = logging.getLogger(__name__)

MAX_DEVICE_NAME = 64


def _v0_to_v1(raw: dict) -> dict:
    """Files before 0.7 had no schema field; nothing else changed."""
    return raw


# MIGRATIONS[n] turns a state.json of schema n into schema n + 1 (on the raw JSON, before parsing).
MIGRATIONS: tuple[Callable[[dict], dict], ...] = (_v0_to_v1,)
SCHEMA = len(MIGRATIONS)


@dataclass(frozen=True)
class Device:
    id: str
    name: str
    sign_pk: str
    box_pk: str
    created: int

    @property
    def box_key(self) -> bytes:
        return b64d(self.box_pk, length=32)


@dataclass
class State:
    keys: dict[str, str]
    relay: dict | None = None
    devices: dict[str, Device] = field(default_factory=dict)

    @property
    def paired(self) -> bool:
        return self.relay is not None

    @property
    def bridge_id(self) -> str:
        if self.relay is None:
            raise RuntimeError("bridge is not paired with a relay")
        return self.relay["bridge_id"]

    @property
    def endpoint(self) -> RelayEndpoint:
        if self.relay is None:
            raise RuntimeError("bridge is not paired with a relay")
        return RelayEndpoint(self.relay["host"], self.relay["port"], self.relay["pin"])

    def key(self, name: str) -> bytes:
        return b64d(self.keys[name])


class StateStore:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.path = directory / "state.json"
        self.seen_path = directory / "e2e_seen.json"
        self.seen_mail_path = directory / "e2e_seen_mail.json"
        self.task_prefs_path = directory / "task_prefs.json"

    def load(self) -> State:
        if not self.path.exists():
            state = State(keys=new_identity_keys())
            self.save(state)
            return state
        raw = json.loads(self.path.read_text())
        schema = raw.get("schema", 0) if isinstance(raw.get("schema", 0), int) else 0
        if schema > SCHEMA:
            log.warning(
                "state.json has schema %d, newer than this bridge's %d (a downgrade?); reading what it can", schema, SCHEMA
            )
        for migrate in MIGRATIONS[schema:]:
            raw = migrate(raw)
        devices = {d["id"]: Device(**d) for d in raw.get("devices", [])}
        state = State(keys=raw["keys"], relay=raw.get("relay"), devices=devices)
        if schema < SCHEMA:
            log.info("state.json migrated from schema %d to %d", schema, SCHEMA)
            self.save(state)
        return state

    def save(self, state: State) -> None:
        devices = [asdict(d) for d in state.devices.values()]
        self._write(self.path, {"schema": SCHEMA, "keys": state.keys, "relay": state.relay, "devices": devices})

    def load_seen(self) -> dict[str, int]:
        return self._load_counts(self.seen_path)

    def save_seen(self, seen: dict[str, int]) -> None:
        self._write(self.seen_path, seen)

    def load_seen_mail(self) -> dict[str, int]:
        return self._load_counts(self.seen_mail_path)

    def save_seen_mail(self, seen: dict[str, int]) -> None:
        self._write(self.seen_mail_path, seen)

    def load_task_prefs(self) -> dict[str, bool]:
        """Per phone: whether tool names may appear in Live Activity pushes (M9)."""
        try:
            raw = json.loads(self.task_prefs_path.read_text())
        except (OSError, ValueError):
            return {}
        return {k: v for k, v in raw.items() if isinstance(k, str) and isinstance(v, bool)} if isinstance(raw, dict) else {}

    def save_task_prefs(self, prefs: dict[str, bool]) -> None:
        self._write(self.task_prefs_path, prefs)

    def load_revocations(self) -> list[str]:
        """Revoked device ids the relay has not confirmed yet (it was unreachable)."""
        try:
            raw = json.loads((self.directory / "revocations.json").read_text())
        except (OSError, ValueError):
            return []
        return [d for d in raw if isinstance(d, str)] if isinstance(raw, list) else []

    def save_revocations(self, device_ids: list[str]) -> None:
        self._write(self.directory / "revocations.json", device_ids)

    @staticmethod
    def _load_counts(path: Path) -> dict[str, int]:
        try:
            raw = json.loads(path.read_text())
        except (OSError, ValueError):
            return {}
        return {k: v for k, v in raw.items() if isinstance(k, str) and isinstance(v, int)} if isinstance(raw, dict) else {}

    def _write(self, path: Path, data: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".state.")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(data, handle, indent=1)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise


def new_device(device_id: str, name: str, sign_pk: str, box_pk: str) -> Device:
    b64d(sign_pk, length=32)
    b64d(box_pk, length=32)
    clean = "".join(ch for ch in name if ch.isprintable())[:MAX_DEVICE_NAME].strip() or "iPhone"
    return Device(device_id, clean, sign_pk, box_pk, int(time.time()))
