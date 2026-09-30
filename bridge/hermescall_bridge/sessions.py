"""Hermes session ids for calls: one per phone, rolled over daily and after `MAX_TURNS` turns.

A single fixed session id (`hermes-call-phone`) grew forever and mixed all phones. Now each
phone gets `<base>-<device id prefix>-<UTC date>[-<n>]`; the chat context and the last call's
transcript still carry over between sessions (chat.py). Persisted in `sessions.json`.
"""

import json
import logging
import os
import re
import tempfile
import time
from dataclasses import asdict, dataclass, replace
from pathlib import Path

log = logging.getLogger(__name__)

MAX_TURNS = 200
_SAFE = re.compile(r"[^A-Za-z0-9_-]")


@dataclass(frozen=True)
class PhoneSession:
    day: str
    part: int = 0
    turns: int = 0


def _today() -> str:
    return time.strftime("%Y%m%d", time.gmtime())


class PhoneSessions:
    def __init__(self, base: str, path: Path | None = None, max_turns: int = MAX_TURNS) -> None:
        self._base = base
        self._path = path
        self._max_turns = max_turns
        self._sessions: dict[str, PhoneSession] = self._load()

    def session_id(self, device_id: str) -> str:
        session = self._current(device_id)
        prefix = _SAFE.sub("", device_id)[:8] or "phone"
        suffix = f"-{session.part}" if session.part else ""
        return f"{self._base}-{prefix}-{session.day}{suffix}"

    def note_turn(self, device_id: str) -> None:
        session = self._current(device_id)
        turns = session.turns + 1
        self._sessions[device_id] = (
            replace(session, part=session.part + 1, turns=0) if turns >= self._max_turns else replace(session, turns=turns)
        )
        self._save()

    def forget(self, device_id: str) -> None:
        if self._sessions.pop(device_id, None) is not None:
            self._save()

    def _current(self, device_id: str) -> PhoneSession:
        session = self._sessions.get(device_id)
        today = _today()
        if session is None or session.day != today:
            session = PhoneSession(today)
            self._sessions[device_id] = session
        return session

    def _load(self) -> dict[str, PhoneSession]:
        if self._path is None:
            return {}
        try:
            raw = json.loads(self._path.read_text())
            return {k: PhoneSession(**v) for k, v in raw.items() if isinstance(k, str) and isinstance(v, dict)}
        except (OSError, ValueError, TypeError):
            return {}

    def _save(self) -> None:
        if self._path is None:
            return
        try:
            fd, tmp = tempfile.mkstemp(dir=self._path.parent, prefix=".sessions.")
            with os.fdopen(fd, "w") as handle:
                json.dump({k: asdict(v) for k, v in self._sessions.items()}, handle)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._path)
        except OSError as exc:
            log.warning("call sessions not saved: %s", exc)
