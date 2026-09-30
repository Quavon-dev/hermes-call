"""Tool progress of `hermes_call` chat turns → hermes-call-bridge (`POST /v1/chat/progress`).

The phone shows it as the presence's tasks ring and a Live Activity (Dynamic Island / Lock
Screen) instead of chat bubbles. Plugin hooks (`pre_tool_call` / `post_tool_call`) see every
tool call regardless of the `display.tool_progress` setting; the gateway's session context tells
whether the turn belongs to this platform and which owner message started it (the turn id).
The adapter reports the end of the turn (`on_processing_complete`).

Hooks run on the agent's worker threads: they only enqueue; one daemon thread posts in order.
Nothing here may ever raise into the agent loop.
"""

import json
import logging
import os
import queue
import re
import threading
import urllib.request
from collections import OrderedDict
from collections.abc import Callable
from typing import Any

log = logging.getLogger(__name__)

PLATFORM = "hermes_call"
DEFAULT_TURN = "chat"
MAX_TURN_ID = 64
MAX_PREVIEW = 200
MAX_QUEUE = 200
MAX_TURNS = 16
POST_TIMEOUT = 5.0
TOOLSET = re.compile(r"[a-z0-9_-]{1,64}")

Post = Callable[[dict[str, Any]], None]


def current_turn() -> str | None:
    """The turn id (the owner's chat message id) when this runs for a hermes_call session, else None."""
    try:
        from gateway.session_context import get_session_env
    except ImportError:
        return None
    if get_session_env("HERMES_SESSION_PLATFORM", "") != PLATFORM:
        return None
    return (get_session_env("HERMES_SESSION_MESSAGE_ID", "") or DEFAULT_TURN)[:MAX_TURN_ID]


def tool_preview(tool_name: str, args: object) -> str | None:
    """Hermes' own short argument preview (sent end-to-end only, never in a push)."""
    try:
        from agent.display import build_tool_preview

        preview = build_tool_preview(tool_name, args if isinstance(args, dict) else {})
    except Exception:
        return None
    return preview[:MAX_PREVIEW] if isinstance(preview, str) and preview else None


def tool_toolset(tool_name: str) -> str | None:
    """The tool's toolset from Hermes' registry (labels the phone shows for tools it does not know)."""
    try:
        from tools.registry import registry

        toolset = getattr(registry.get_entry(tool_name), "toolset", None)
    except Exception:  # an older or changed Hermes: no label hint, never an error in the agent loop
        return None
    return toolset if isinstance(toolset, str) and TOOLSET.fullmatch(toolset) else None


def _failed(result: object) -> bool:
    try:
        parsed = json.loads(result) if isinstance(result, str) else None
    except ValueError:
        return False
    return isinstance(parsed, dict) and "error" in parsed and parsed.get("success") is not True


class ProgressReporter:
    def __init__(self, post: Post) -> None:
        self._post = post
        # Unbounded queue with a bound enforced in _enqueue: tool events beyond MAX_QUEUE are dropped,
        # the end of a turn (at most one per turn) never is.
        self._queue: queue.Queue[dict[str, Any]] = queue.Queue()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        # turn id → {tool_call_id → index}, newest turns only
        self._turns: OrderedDict[str, dict[str, int]] = OrderedDict()

    # ---- hook entry points (agent worker threads) ------------------------

    def tool_started(self, turn_id: str, tool_name: str, tool_call_id: str, args: object) -> None:
        with self._lock:
            calls = self._turn(turn_id)
            key = tool_call_id or f"#{len(calls)}"
            if key in calls:
                return
            calls[key] = index = len(calls)
        body = {"turn_id": turn_id, "tool": tool_name, "index": index, "state": "started"}
        if preview := tool_preview(tool_name, args):
            body["preview"] = preview
        if toolset := tool_toolset(tool_name):
            body["toolset"] = toolset
        self._enqueue(body)

    def tool_finished(self, turn_id: str, tool_name: str, tool_call_id: str, duration_ms: object, result: object) -> None:
        with self._lock:
            index = self._turns.get(turn_id, {}).get(tool_call_id)
        if index is None:
            return
        body: dict[str, Any] = {"turn_id": turn_id, "tool": tool_name, "index": index, "state": "finished"}
        body["ok"] = not _failed(result)
        if isinstance(duration_ms, (int, float)) and not isinstance(duration_ms, bool) and duration_ms >= 0:
            body["duration"] = round(duration_ms / 1000, 3)
        self._enqueue(body)

    def turn_ended(self, turn_id: str, failed: bool) -> None:
        """From the adapter once the reply was sent; only turns that used tools are reported."""
        with self._lock:
            if self._turns.pop(turn_id, None) is None:
                return
        self._enqueue({"turn_id": turn_id, "state": "failed" if failed else "done"})

    # ---- delivery ----------------------------------------------------------

    def _turn(self, turn_id: str) -> dict[str, int]:
        calls = self._turns.setdefault(turn_id, {})
        self._turns.move_to_end(turn_id)
        while len(self._turns) > MAX_TURNS:
            self._turns.popitem(last=False)
        return calls

    def _enqueue(self, body: dict[str, Any]) -> None:
        if body["state"] not in ("done", "failed") and self._queue.qsize() >= MAX_QUEUE:
            log.debug("hermes_call: progress dropped (queue full)")
            return
        self._queue.put_nowait(body)
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="hermes-call-progress", daemon=True)
                self._thread.start()

    def _run(self) -> None:
        while True:
            body = self._queue.get()
            try:
                self._post(body)
            except Exception as exc:  # progress is best effort; the reply itself never depends on it
                log.debug("hermes_call: progress not delivered (%s)", exc.__class__.__name__)
            finally:
                self._queue.task_done()

    def flush(self, timeout: float = 5.0) -> bool:
        """Test helper: waits until everything queued was posted."""
        done = threading.Event()
        threading.Thread(target=lambda: (self._queue.join(), done.set()), daemon=True).start()
        return done.wait(timeout)


def post_to_bridge(body: dict[str, Any]) -> None:
    from . import _opener, bridge_url

    token = os.environ.get("HERMES_CALL_TOKEN", "")
    if not token:
        return
    request = urllib.request.Request(  # noqa: S310 - loopback http only (bridge_url checks it)
        f"{bridge_url()}/v1/chat/progress",
        data=json.dumps(body).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with _opener.open(request, timeout=POST_TIMEOUT) as response:
        response.read()


REPORTER = ProgressReporter(post_to_bridge)


def on_pre_tool_call(tool_name: str = "", args: object = None, tool_call_id: str = "", **_: Any) -> None:
    try:
        if (turn_id := current_turn()) and tool_name and not tool_name.startswith("_"):
            REPORTER.tool_started(turn_id, tool_name, tool_call_id or "", args)
    except Exception:
        log.debug("hermes_call: pre_tool_call progress failed", exc_info=True)


def on_post_tool_call(
    tool_name: str = "", tool_call_id: str = "", duration_ms: object = None, result: object = None, **_: Any
) -> None:
    try:
        if (turn_id := current_turn()) and tool_name:
            REPORTER.tool_finished(turn_id, tool_name, tool_call_id or "", duration_ms, result)
    except Exception:
        log.debug("hermes_call: post_tool_call progress failed", exc_info=True)
