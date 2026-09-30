"""M9 §1: the plugin's tool hooks report hermes_call chat turns to the bridge (no chat bubbles)."""

import asyncio
import importlib
import json

from .conftest import CALL_TOKEN
from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_hermes_plugin import plugin

progress = importlib.import_module(f"{plugin.__name__}.progress")


def reporter() -> tuple[object, list[dict]]:
    posted: list[dict] = []
    return progress.ProgressReporter(posted.append), posted


def test_reporter_numbers_tools_per_turn_and_reports_the_end() -> None:
    rep, posted = reporter()
    rep.tool_started("m1", "web_search", "c1", {"query": "weather"})
    rep.tool_started("m1", "web_search", "c1", {"query": "weather"})  # the same call once
    rep.tool_started("m1", "terminal", "c2", {"command": "ls"})
    rep.tool_finished("m1", "web_search", "c1", 1500, json.dumps({"results": []}))
    rep.tool_finished("m1", "terminal", "c2", 20, json.dumps({"error": "boom"}))
    rep.tool_finished("m1", "patch", "unknown", 5, "")
    rep.turn_ended("m1", failed=False)
    rep.turn_ended("m1", failed=False)  # once
    rep.turn_ended("quiet", failed=True)  # a turn without tools reports nothing
    assert rep.flush()
    assert [(b["tool"] if "tool" in b else None, b.get("index"), b["state"]) for b in posted] == [
        ("web_search", 0, "started"),
        ("terminal", 1, "started"),
        ("web_search", 0, "finished"),
        ("terminal", 1, "finished"),
        (None, None, "done"),
    ]
    assert posted[2]["ok"] is True and posted[2]["duration"] == 1.5 and posted[3]["ok"] is False
    assert all(b["turn_id"] == "m1" for b in posted)


def test_failed_turn_and_post_errors_are_swallowed() -> None:
    def broken(body: dict) -> None:
        raise OSError("bridge down")

    rep = progress.ProgressReporter(broken)
    rep.tool_started("m2", "terminal", "", None)
    rep.turn_ended("m2", failed=True)
    assert rep.flush()


def test_hooks_only_act_for_hermes_call_sessions(monkeypatch) -> None:
    rep, posted = reporter()
    monkeypatch.setattr(progress, "REPORTER", rep)
    monkeypatch.setattr(progress, "current_turn", lambda: None)
    progress.on_pre_tool_call(tool_name="terminal", args={}, tool_call_id="c1")
    monkeypatch.setattr(progress, "current_turn", lambda: "m3")
    progress.on_pre_tool_call(tool_name="_thinking", args={}, tool_call_id="c0")
    progress.on_pre_tool_call(tool_name="terminal", args={"command": "ls"}, tool_call_id="c1", task_id="t", session_id="s")
    progress.on_post_tool_call(tool_name="terminal", tool_call_id="c1", duration_ms=12, result="{}", args={})
    assert rep.flush()
    assert [b["state"] for b in posted] == ["started", "finished"]
    assert posted[0]["turn_id"] == "m3" and posted[0]["tool"] == "terminal"


def test_current_turn_outside_the_gateway_is_none() -> None:
    assert progress.current_turn() is None  # no Hermes gateway in this process


async def test_progress_reaches_the_phone(h, monkeypatch) -> None:  # noqa: F811
    device = await online_device(h)
    monkeypatch.setenv("HERMES_CALL_TOKEN", CALL_TOKEN)
    monkeypatch.setenv("HERMES_CALL_URL", f"http://127.0.0.1:{h.api_port}")
    rep = progress.ProgressReporter(progress.post_to_bridge)
    rep.tool_started("owner-message-1", "web_search", "c1", {"query": "weather in Munich"})
    task = await next_of(device, "task")
    assert task["turn_id"] == "owner-message-1" and task["label"] == "Searching the web" and task["step"] == 1
    rep.turn_ended("owner-message-1", failed=False)
    assert (await next_of(device, "task"))["state"] == "done"
    await asyncio.to_thread(rep.flush)


def test_the_end_of_a_turn_is_never_dropped() -> None:
    import threading

    release = threading.Event()
    posted: list[dict] = []

    def slow(body: dict) -> None:
        release.wait(5)
        posted.append(body)

    rep = progress.ProgressReporter(slow)
    for index in range(progress.MAX_QUEUE + 20):
        rep.tool_started("m4", "terminal", f"c{index}", None)
    rep.turn_ended("m4", failed=False)
    release.set()
    assert rep.flush()
    assert posted[-1] == {"turn_id": "m4", "state": "done"}
    assert len(posted) <= progress.MAX_QUEUE + 2
