"""Agent task progress on the phones (M9 §1): the tasks ring, the Dynamic Island and the Lock Screen.

Hermes (plugin hooks for chat, SSE `hermes.tool.progress` for calls) reports each tool it starts and
finishes, and the end of the turn. Phones get E2E `task` messages (live; the final state also by
mail). Phones that are offline get ActivityKit pushes through the relay instead; those are plaintext
to Apple, so they carry only step, state, start time and a generic label unless the owner allowed
tool names ("task details"). Argument previews only ever travel E2E. Logs carry ids and counts only.
"""

import asyncio
import itertools
import logging
import math
import re
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import aiohttp

from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel
from hermescall_common.errors import ProtocolError

from .state import Device, State
from .transport import Transport

log = logging.getLogger(__name__)

STATES = ("started", "finished", "done", "failed")
PROGRESS_KEYS = frozenset({"turn_id", "tool", "index", "state", "ok", "duration", "preview", "total", "toolset"})
TOOLSET = re.compile(r"[a-z0-9_-]{1,64}")
DEFAULT_TURN = "chat"
MAX_TURN_ID = 64
MAX_PREVIEW = 200
MAX_INDEX = 100_000
MAX_LABEL = 60
MAX_STEP = 999
TOOL_NAME = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
GENERIC_LABEL = "Working…"
# E2E updates per turn at most this often (the final state always goes at once).
E2E_INTERVAL = 0.5
# Live Activity pushes per phone at most this often (the relay allows one per 3 s).
PUSH_INTERVAL = 5.0
RETIRED_TURNS = 32
# New turns that may send Live Activity pushes: (window s, max turns); more turns are shown in the app only.
PUSH_TURN_LIMITS = ((2.0, 1), (3600.0, 30))
# A turn with no event for this long ends as done (its `done` got lost).
IDLE_TIMEOUT = 600.0
# Presence comes from relay events; a new turn re-checks it at most this often.
ONLINE_REFRESH = 30.0
TRANSPORT_ERRORS = (ProtocolError, TimeoutError, ConnectionError, RuntimeError, aiohttp.ClientError)
LABELS = {
    "web_search": "Searching the web",
    "web_extract": "Reading the web",
    "terminal": "Running a command",
    "read_file": "Working on files",
    "write_file": "Working on files",
    "patch": "Working on files",
    "search_files": "Working on files",
    "vision_analyze": "Looking at an image",
}


# Hermes' tool metadata (the registry's toolset) labels tools the fixed map does not know.
TOOLSET_LABELS = {
    "web": "Searching the web",
    "search": "Searching the web",
    "terminal": "Running a command",
    "code_execution": "Running code",
    "file": "Working on files",
    "browser": "Browsing",
    "vision": "Looking at an image",
    "image_gen": "Making an image",
    "memory": "Remembering",
    "skills": "Using a skill",
    "delegation": "Delegating",
    "cronjob": "Scheduling",
    "hermes_call": "Using your phone",
}


def label_for(tool: str, toolset: str | None = None) -> str:
    """A short human label for the Dynamic Island; never derived from arguments."""
    if tool in LABELS:
        return LABELS[tool]
    if tool.startswith("browser_"):
        return "Browsing"
    if toolset in TOOLSET_LABELS:
        return TOOLSET_LABELS[toolset]
    return f"Using {tool}"[:MAX_LABEL]


@dataclass(frozen=True)
class Progress:
    turn_id: str
    tool: str
    index: int
    state: str
    ok: bool | None = None
    duration: float | None = None
    preview: str | None = None
    total: int | None = None
    toolset: str | None = None


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def parse_progress(body: object) -> Progress:
    """`POST /v1/chat/progress` body → Progress. Raises ValueError (HTTP 400)."""
    if not isinstance(body, dict) or set(body) - PROGRESS_KEYS:
        raise ValueError(f"expected an object with only: {', '.join(sorted(PROGRESS_KEYS))}")
    state = body.get("state")
    if state not in STATES:
        raise ValueError("state: started, finished, done or failed")
    turn_id = body.get("turn_id", DEFAULT_TURN)
    if not isinstance(turn_id, str) or not 0 < len(turn_id) <= MAX_TURN_ID:
        raise ValueError("turn_id: 1–64 chars")
    ends_turn = state in ("done", "failed")
    tool = body.get("tool", "" if ends_turn else None)
    if not isinstance(tool, str) or not (TOOL_NAME.fullmatch(tool) or (ends_turn and not tool)):
        raise ValueError("tool: a tool name, 1–64 chars of A–Z a–z 0–9 _ . : -")
    index = body.get("index", 0 if ends_turn else None)
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index <= MAX_INDEX:
        raise ValueError("index: integer ≥ 0")
    ok, duration, preview = body.get("ok"), body.get("duration"), body.get("preview")
    if ok is not None and not isinstance(ok, bool):
        raise ValueError("ok: boolean")
    if duration is not None and not _number(duration):
        raise ValueError("duration: number ≥ 0")
    if preview is not None and (not isinstance(preview, str) or len(preview) > MAX_PREVIEW):
        raise ValueError("preview: at most 200 chars")
    total, toolset = body.get("total"), body.get("toolset")
    if total is not None and (isinstance(total, bool) or not isinstance(total, int) or not 1 <= total <= MAX_STEP):
        raise ValueError(f"total: integer 1–{MAX_STEP}")
    if toolset is not None and (not isinstance(toolset, str) or not TOOLSET.fullmatch(toolset)):
        raise ValueError("toolset: 1–64 chars of a–z 0–9 _ -")
    return Progress(turn_id, tool, index, state, ok, duration, preview or None, total, toolset)


@dataclass
class Turn:
    turn_id: str
    serial: int  # internal, unique per turn (turn ids like the default "chat" repeat)
    started_at: int  # ms since epoch of the turn's first event
    pushes: bool = True  # False: over the new-turn limit, shown in the app but no Live Activity pushes
    step: int = 0
    total: int | None = None  # tools this turn will run, when Hermes knows it (never below step)
    tool: str = ""
    label: str = ""
    preview: str | None = None
    state: str = "running"
    last_event: float = field(default_factory=time.monotonic)
    indexes: set[int] = field(default_factory=set)
    e2e_pending: bool = False
    push_pending: set[str] = field(default_factory=set)
    pushed: dict[str, float] = field(default_factory=dict)  # device → monotonic time of its last push
    informed: set[str] = field(default_factory=set)  # devices that were online for an E2E update
    timer: asyncio.Task | None = None
    watchdog: asyncio.Task | None = None


class TaskService:
    def __init__(
        self,
        state: State,
        relay: RelaySession,
        channel: Channel,
        prefs: dict[str, bool] | None = None,
        save_prefs: Callable[[dict[str, bool]], None] | None = None,
    ) -> None:
        self._state = state
        self._relay = relay
        self._channel = channel
        self._transport = Transport(state, relay, channel)
        self._prefs = dict(prefs or {})
        self._save_prefs = save_prefs
        self._turn: Turn | None = None
        self._serials = itertools.count(1)
        # turn id → serial of the turn that replaced it: late events of a replaced turn are ignored
        # while that newer turn runs.
        self._retired: dict[str, int] = {}
        self._tasks: set[asyncio.Task] = set()
        self._online: set[str] = set()
        self._online_checked = -math.inf
        # E2E sends are paced across turns too, so a flood of new turn ids cannot flood the phones.
        self._e2e_sent = -math.inf
        # New turns that may push to Apple (the Hermes token can post progress: bound what it costs).
        self._push_turns: deque[float] = deque(maxlen=max(n for _, n in PUSH_TURN_LIMITS))

    # ---- progress from Hermes ------------------------------------------

    async def progress(self, body: object) -> None:
        await self.report(parse_progress(body))

    def submit(self, event: Progress) -> None:
        """Non-blocking report (from a call's audio pipeline)."""
        self._spawn(self.report(event))

    async def report(self, event: Progress) -> None:
        """State changes happen synchronously, in call order; network I/O happens afterwards."""
        ended = self._update(event)
        if ended is not None:
            await self._deliver_end(ended)

    def _update(self, event: Progress) -> Turn | None:
        """Applies one event. Returns the turn if this event ended it (its final state still has to go out)."""
        turn = self._turn
        current = turn is not None and turn.turn_id == event.turn_id and turn.state == "running"
        if event.state in ("done", "failed"):
            if current and turn.step:
                self._end(turn, event.state)
                return turn
            return None
        if current:
            turn.last_event = time.monotonic()
        if event.state != "started":
            return None  # a finished tool changes nothing on screen
        if not current:
            replaced_by = self._retired.get(event.turn_id)
            if replaced_by is not None and turn is not None and turn.serial == replaced_by and turn.state == "running":
                return None  # a late event of a turn that a newer (still running) one replaced
            turn = self._new_turn(event.turn_id)
        elif event.index in turn.indexes:
            return None  # a repeated start counts once
        turn.indexes.add(event.index)
        turn.step += 1
        turn.tool, turn.label, turn.preview = event.tool, label_for(event.tool, event.toolset), event.preview
        if event.total is not None:
            turn.total = max(event.total, turn.total or 0)
        turn.e2e_pending = True
        turn.push_pending = set(self._state.devices) if turn.pushes else set()
        if turn.timer is None or turn.timer.done():
            turn.timer = self._spawn(self._pump(turn))
        return None

    def _new_turn(self, turn_id: str) -> Turn:
        old = self._turn
        turn = Turn(turn_id, next(self._serials), int(time.time() * 1000), pushes=self._may_push())
        if old is not None and old.state == "running":
            self._cancel(old)
            self._retired[old.turn_id] = turn.serial
        self._retired.pop(turn_id, None)
        while len(self._retired) > RETIRED_TURNS:
            del self._retired[next(iter(self._retired))]
        self._turn = turn
        turn.watchdog = self._spawn(self._watch(turn))
        if not turn.pushes:
            log.warning("task %s: too many new turns, no Live Activity pushes for it", turn_id[:6])
        return turn

    def _may_push(self) -> bool:
        now = time.monotonic()
        if any(sum(now - t < window for t in self._push_turns) >= limit for window, limit in PUSH_TURN_LIMITS):
            return False
        self._push_turns.append(now)
        return True

    def _end(self, turn: Turn, state: str) -> None:
        turn.state = state
        self._cancel(turn)
        log.info("task %s %s after %d steps", turn.turn_id[:6], state, turn.step)

    @staticmethod
    def _cancel(turn: Turn) -> None:
        for task in (turn.timer, turn.watchdog):
            if task is not None and task is not asyncio.current_task():
                task.cancel()

    def _spawn(self, coro: Any) -> asyncio.Task:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def _watch(self, turn: Turn) -> None:
        """A turn whose end never arrives (lost `done`, crashed agent) ends as done after a quiet spell."""
        while self._turn is turn and turn.state == "running":
            idle = time.monotonic() - turn.last_event
            if idle >= IDLE_TIMEOUT:
                log.info("task %s: no progress for %.0f s, ending it", turn.turn_id[:6], idle)
                if turn.step:
                    self._end(turn, "done")
                    await self._deliver_end(turn)
                else:
                    turn.state = "done"
                return
            await asyncio.sleep(IDLE_TIMEOUT - idle)

    async def _pump(self, turn: Turn) -> None:
        """Sends what is due now, then sleeps until the next E2E or push slot while anything is pending."""
        try:
            if time.monotonic() - self._online_checked > ONLINE_REFRESH:
                await self._refresh_online()
            while self._turn is turn and turn.state == "running":
                now = time.monotonic()
                due: list[float] = []
                if turn.e2e_pending:
                    if now >= self._e2e_sent + E2E_INTERVAL:
                        turn.e2e_pending, self._e2e_sent = False, now
                        await self._send_live(turn)
                    else:
                        due.append(self._e2e_sent + E2E_INTERVAL)
                for device_id in list(turn.push_pending):
                    slot = turn.pushed.get(device_id, -math.inf) + PUSH_INTERVAL
                    if now >= slot:
                        turn.push_pending.discard(device_id)
                        await self._push(turn, device_id)
                    else:
                        due.append(slot)
                if not due:
                    return
                await asyncio.sleep(max(0.0, min(due) - time.monotonic()))
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("task progress delivery failed")

    async def _deliver_end(self, turn: Turn) -> None:
        try:
            await self._send_live(turn)
            body = self._body(turn)
            for device in list(self._state.devices.values()):
                await self._mail(device, body)
            if turn.pushes:
                for device_id in sorted(set(turn.pushed) | turn.informed):
                    await self._push(turn, device_id, end=True)
        except Exception:
            log.exception("task end delivery failed")

    # ---- delivery ----------------------------------------------------------

    @staticmethod
    def _body(turn: Turn) -> dict[str, Any]:
        body = {
            "type": "task",
            "turn_id": turn.turn_id,
            "step": turn.step,
            "total": _total(turn),
            "tool": turn.tool,
            "label": turn.label,
            "state": turn.state,
            "started_at": turn.started_at,
        }
        if turn.preview:
            body["preview"] = turn.preview
        return body

    async def _send_live(self, turn: Turn) -> None:
        body = self._body(turn)
        for device in list(self._state.devices.values()):
            if device.id in self._online:
                turn.informed.add(device.id)
            await self._live(device, body)

    async def _push(self, turn: Turn, device_id: str, end: bool = False) -> None:
        """ActivityKit push for a phone that cannot update its Live Activity itself (offline)."""
        if device_id in self._online or device_id not in self._state.devices:
            return
        if end:
            event = "end"
        else:
            event = "update" if device_id in turn.pushed or device_id in turn.informed else "start"
        content_state = {
            "step": min(turn.step, MAX_STEP),
            "total": _total(turn),
            "label": turn.label if self.details(device_id) else GENERIC_LABEL,
            "state": turn.state,
            "startedAt": turn.started_at / 1000,
        }
        try:
            await self._relay.request({"t": "live_update", "to": device_id, "event": event, "content_state": content_state})
        except TRANSPORT_ERRORS as exc:
            log.info("live activity %s for %s not pushed: %s", event, device_id[:6], exc)
            return
        turn.pushed[device_id] = time.monotonic()

    async def _refresh_online(self) -> None:
        self._online_checked = time.monotonic()
        try:
            reply = await self._relay.request({"t": "list_devices"})
        except TRANSPORT_ERRORS as exc:
            log.warning("device presence unknown: %s", exc)
            return
        devices = reply.get("devices") if isinstance(reply.get("devices"), list) else []
        self._online = {d["device_id"] for d in devices if isinstance(d, dict) and d.get("online") is True}

    def on_presence(self, device_id: object, online: object) -> None:
        if isinstance(device_id, str):
            (self._online.add if online is True else self._online.discard)(device_id)

    # ---- phone preferences -------------------------------------------------

    def details(self, device_id: str) -> bool:
        """Whether this phone allows real tool labels in (plaintext) Live Activity pushes."""
        return self._prefs.get(device_id, False)

    async def on_prefs(self, device: Device, body: dict[str, Any]) -> None:
        details = body.get("details")
        if not isinstance(details, bool):
            raise ProtocolError("invalid task_prefs")
        self._prefs[device.id] = details
        self._persist()

    def forget_device(self, device_id: str) -> None:
        self._online.discard(device_id)
        if self._prefs.pop(device_id, None) is not None:
            self._persist()

    def _persist(self) -> None:
        if self._save_prefs is None:
            return
        try:
            self._save_prefs(dict(self._prefs))
        except OSError as exc:
            log.warning("task preferences not saved: %s", exc)

    # ---- transport -------------------------------------------------------

    async def _mail(self, device: Device, body: dict[str, Any]) -> None:
        await self._transport.mail(device, body, alert=False)

    async def _live(self, device: Device, body: dict[str, Any]) -> None:
        await self._transport.live(device, body)


def _total(turn: Turn) -> int | None:
    return min(max(turn.total, turn.step), MAX_STEP) if turn.total is not None else None
