"""Persistent E2E replay marks without rewriting a file per message.

Every accepted message appends one short line (`peer|mail <key> <ts>`) to the current log
segment, so a crash never reopens the replay window. Every `COMPACT_EVERY` marks the segment is
rotated and a snapshot (`e2e_seen.json`, `e2e_seen_mail.json`) is written off the event loop;
the old segments are deleted only after the snapshot is on disk. Loading merges the snapshots
with whatever segments exist (merging is idempotent: newest timestamp wins).
"""

import asyncio
import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import IO

from hermescall_common.e2e import MAIL_WINDOW_MS

log = logging.getLogger(__name__)

COMPACT_EVERY = 1000
KINDS = ("peer", "mail")
_SNAPSHOTS = {"peer": "e2e_seen.json", "mail": "e2e_seen_mail.json"}
_SEGMENT = "e2e_seen.{}.log"


def _read_counts(path: Path) -> dict[str, int]:
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(raw, dict):
        return {}
    return {k: v for k, v in raw.items() if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool)}


def _write_json(path: Path, data: dict[str, int]) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".seen.")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _segment_number(path: Path) -> int:
    try:
        return int(path.name.split(".")[1])
    except (IndexError, ValueError):
        return -1


class SeenLog:
    def __init__(self, directory: Path, compact_every: int = COMPACT_EVERY) -> None:
        self._dir = directory
        self._compact_every = compact_every
        self._marks = {kind: {} for kind in KINDS}
        self._file: IO[str] | None = None
        self._segment = 0
        self._count = 0
        self._compacting: asyncio.Future | None = None

    def load(self) -> tuple[dict[str, int], dict[str, int]]:
        """(peer → newest timestamp, mail id → timestamp), merged from snapshots and log segments."""
        self._dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._marks = {kind: _read_counts(self._dir / name) for kind, name in _SNAPSHOTS.items()}
        segments = sorted(self._segments(), key=_segment_number)
        for path in segments:
            self._replay(path)
        self._segment = max((_segment_number(p) for p in segments), default=-1) + 1
        self._prune_mail()
        return dict(self._marks["peer"]), dict(self._marks["mail"])

    def mark(self, kind: str, key: str, ts: int) -> None:
        if kind not in KINDS or any(ch.isspace() for ch in key):
            return
        self._merge(kind, key, ts)
        if self._file is None:
            self._file = self._open_segment()
        self._file.write(f"{kind} {key} {ts}\n")
        self._file.flush()
        self._count += 1
        if self._count >= self._compact_every:
            self.compact()

    def compact(self) -> None:
        """Rotates the segment now; the snapshot is written in a worker thread when a loop runs."""
        if self._compacting is not None and not self._compacting.done():
            return
        self._close_file()
        done = [p for p in self._segments() if _segment_number(p) < self._segment]
        self._prune_mail()
        snapshot = {kind: dict(marks) for kind, marks in self._marks.items()}
        self._count = 0
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            self._write_snapshot(snapshot, done)
            return
        self._compacting = loop.run_in_executor(None, self._write_snapshot, snapshot, done)
        self._compacting.add_done_callback(self._compaction_done)

    def close(self) -> None:
        """Clean shutdown: everything into the snapshots, no segments left."""
        self._close_file()
        self._prune_mail()
        self._write_snapshot({kind: dict(marks) for kind, marks in self._marks.items()}, list(self._segments()))

    # ---- internals ---------------------------------------------------------

    def _merge(self, kind: str, key: str, ts: int) -> None:
        marks = self._marks[kind]
        marks[key] = max(ts, marks.get(key, ts))

    def _replay(self, path: Path) -> None:
        try:
            lines = path.read_text().splitlines()
        except OSError as exc:
            log.warning("replay log %s unreadable: %s", path.name, exc.__class__.__name__)
            return
        for line in lines:
            parts = line.split(" ")
            if len(parts) == 3 and parts[0] in KINDS and parts[2].isdigit():
                self._merge(parts[0], parts[1], int(parts[2]))

    def _prune_mail(self) -> None:
        oldest = int(time.time() * 1000) - MAIL_WINDOW_MS
        self._marks["mail"] = {k: v for k, v in self._marks["mail"].items() if k == "" or v > oldest}

    def _segments(self) -> list[Path]:
        return [p for p in self._dir.glob("e2e_seen.*.log") if _segment_number(p) >= 0]

    def _open_segment(self) -> IO[str]:
        path = self._dir / _SEGMENT.format(self._segment)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        return os.fdopen(fd, "a")

    def _close_file(self) -> None:
        if self._file is not None:
            self._file.close()
            self._file = None
            self._segment += 1

    def _write_snapshot(self, snapshot: dict[str, dict[str, int]], done: list[Path]) -> None:
        for kind, name in _SNAPSHOTS.items():
            _write_json(self._dir / name, snapshot[kind])
        for path in done:
            path.unlink(missing_ok=True)

    @staticmethod
    def _compaction_done(future: asyncio.Future) -> None:
        if not future.cancelled() and future.exception() is not None:
            log.warning("replay marks not compacted: %s (the log segments are kept)", future.exception())
