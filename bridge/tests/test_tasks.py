"""M9 §1: agent task progress → E2E `task` messages, final state by mail, Live Activity pushes for offline phones."""

import asyncio
import json

import pytest

from hermescall_bridge import tasks as tasks_mod
from hermescall_bridge.tasks import label_for, parse_progress
from hermescall_common.client import RelaySession
from hermescall_relay.ratelimit import RateLimiter

from .test_bridge_flows import api, connect, h, pair_device  # noqa: F401 - h is a fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401 - fixtures

LA_TOKEN = "ab" * 32
START_TOKEN = "cd" * 32


def started(tool: str, index: int, turn_id: str = "turn-1", **extra) -> dict:
    return {"turn_id": turn_id, "tool": tool, "index": index, "state": "started", **extra}


async def progress(h, body: dict) -> int:
    status, _ = await hermes_api(h, "POST", "/v1/chat/progress", body)
    return status


async def drain(device, seconds: float = 0.3) -> list[dict]:
    got = []
    try:
        while True:
            got.append(await asyncio.wait_for(device.inbox.get(), seconds))
    except TimeoutError:
        return got


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"tool": "web_search", "index": 0, "state": "started", "extra": 1},
        {"tool": "", "index": 0, "state": "started"},
        {"tool": "x" * 65, "index": 0, "state": "started"},
        {"tool": "web search", "index": 0, "state": "started"},
        {"tool": "web_search", "index": -1, "state": "started"},
        {"tool": "web_search", "index": True, "state": "started"},
        {"tool": "web_search", "index": 0, "state": "paused"},
        {"tool": "web_search", "index": 0, "state": "finished", "ok": "yes"},
        {"tool": "web_search", "index": 0, "state": "finished", "duration": -1},
        {"tool": "web_search", "index": 0, "state": "started", "preview": "x" * 201},
        {"tool": "web_search", "index": 0, "state": "started", "turn_id": "t" * 65},
        {"tool": "web_search", "index": 0, "state": "started", "turn_id": 5},
    ],
)
async def test_progress_is_validated(h, body) -> None:  # noqa: F811
    assert await progress(h, body) == 400


def test_parse_and_labels() -> None:
    event = parse_progress({"tool": "terminal", "index": 3, "state": "finished", "ok": False, "duration": 1.5})
    assert event.turn_id == "chat" and event.tool == "terminal" and event.ok is False and event.duration == 1.5
    assert parse_progress({"state": "done", "turn_id": "abc"}).tool == ""
    assert label_for("web_search") == "Searching the web"
    assert label_for("terminal") == "Running a command"
    assert label_for("patch") == label_for("read_file") == "Working on files"
    assert label_for("browser_click") == "Browsing"
    assert label_for("vision_analyze") == "Looking at an image"
    assert label_for("x" * 64) == ("Using " + "x" * 64)[:60]


async def test_online_phone_gets_live_progress_and_the_end_by_mail(h) -> None:  # noqa: F811
    device = await online_device(h)
    assert await progress(h, started("web_search", 0, preview="weather munich")) == 204
    first = await next_of(device, "task")
    assert first["turn_id"] == "turn-1" and first["step"] == 1 and first["total"] is None
    assert first["tool"] == "web_search" and first["label"] == "Searching the web" and first["state"] == "running"
    assert first["preview"] == "weather munich" and isinstance(first["started_at"], int)
    assert "mid" not in first  # live, not mail
    assert await progress(h, {"turn_id": "turn-1", "tool": "web_search", "index": 0, "state": "finished", "ok": True}) == 204
    assert await progress(h, started("terminal", 1)) == 204
    second = await next_of(device, "task")
    assert second["step"] == 2 and second["label"] == "Running a command" and second["started_at"] == first["started_at"]
    assert await progress(h, {"turn_id": "turn-1", "state": "done"}) == 204
    finals = [m for m in await drain(device, 0.5) if m["type"] == "task"]
    assert [m["state"] for m in finals] == ["done", "done"]
    assert sum("mid" in m for m in finals) == 1  # one of them came by mail
    assert h.push.live == []  # online phones update their Live Activity themselves


async def test_updates_are_coalesced_but_the_last_state_arrives(h) -> None:  # noqa: F811
    device = await online_device(h)
    for index in range(10):
        assert await progress(h, started("terminal", index)) == 204
    messages = [m for m in await drain(device, 1.0) if m["type"] == "task"]
    assert 1 <= len(messages) <= 3
    assert messages[-1]["step"] == 10


async def test_a_new_turn_replaces_the_old_one(h) -> None:  # noqa: F811
    device = await online_device(h)
    await progress(h, started("web_search", 0, turn_id="old"))
    assert (await next_of(device, "task"))["turn_id"] == "old"
    await progress(h, started("terminal", 0, turn_id="new"))
    assert (await next_of(device, "task"))["turn_id"] == "new"
    await progress(h, started("patch", 1, turn_id="old"))
    await progress(h, {"turn_id": "old", "state": "done"})
    assert [m for m in await drain(device, 0.8) if m["type"] == "task"] == []


async def test_turn_without_tools_sends_nothing(h) -> None:  # noqa: F811
    device = await online_device(h)
    assert await progress(h, {"turn_id": "quiet", "state": "done"}) == 204
    assert await progress(h, {"turn_id": "quiet", "tool": "x", "index": 0, "state": "finished"}) == 204
    assert [m for m in await drain(device, 0.5) if m["type"] == "task"] == []


async def test_repeated_start_of_the_same_tool_counts_once(h) -> None:  # noqa: F811
    device = await online_device(h)
    await progress(h, started("terminal", 0))
    await asyncio.sleep(0.6)
    await progress(h, started("terminal", 0))
    await asyncio.sleep(0.6)
    steps = [m["step"] for m in await drain(device, 0.3) if m["type"] == "task"]
    assert steps == [1]


async def offline_device_with_tokens(h):  # noqa: F811
    device = await pair_device(h)
    task = await connect(device)
    for kind, token in (("liveactivity", LA_TOKEN), ("liveactivity_start", START_TOKEN)):
        await device.session.request({"t": "register_push", "token": token, "env": "sandbox", "kind": kind})
    device.session.stop()
    task.cancel()
    await asyncio.sleep(0.3)
    device.session = RelaySession(
        device.session.endpoint, "device", device.state["device_id"], device.session._sign_sk, device.on_event
    )
    return device


async def test_offline_phone_gets_live_activity_pushes(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(tasks_mod, "PUSH_INTERVAL", 0.3)
    h.relay.live_rate = RateLimiter(limit=100, window=1)
    await offline_device_with_tokens(h)
    await progress(h, started("web_search", 0, preview="secret query"))
    await asyncio.sleep(0.3)
    await progress(h, started("terminal", 1, preview="rm -rf secrets"))
    await asyncio.sleep(0.6)
    await progress(h, {"turn_id": "turn-1", "state": "failed"})
    await asyncio.sleep(0.3)
    events = [(token, event) for token, event, _ in h.push.live]
    assert events == [(START_TOKEN, "start"), (LA_TOKEN, "update"), (LA_TOKEN, "end")]
    states = [state for _, _, state in h.push.live]
    assert [s["step"] for s in states] == [1, 2, 2] and [s["state"] for s in states] == ["running", "running", "failed"]
    assert {s["label"] for s in states} == {"Working…"}
    assert all(set(s) == {"step", "total", "label", "state", "startedAt"} for s in states)
    assert "secret" not in json.dumps(states) and "rm -rf" not in json.dumps(states)
    assert states[0]["startedAt"] == states[2]["startedAt"] and states[0]["total"] is None


async def test_details_preference_shows_the_label(h) -> None:  # noqa: F811
    device = await offline_device_with_tokens(h)
    task = await connect(device)
    await device.send({"type": "task_prefs", "details": True}, mail=True)
    await asyncio.sleep(0.3)
    device.session.stop()
    task.cancel()
    await asyncio.sleep(0.3)
    await progress(h, started("web_search", 0, preview="secret query"))
    await asyncio.sleep(0.3)
    ((_, event, state),) = h.push.live
    assert event == "start" and state["label"] == "Searching the web"
    saved = json.loads((h.bridge.devices._store.path.parent / "task_prefs.json").read_text())
    assert saved == {device.state["device_id"]: True}


async def test_bad_task_prefs_are_ignored(h) -> None:  # noqa: F811
    device = await online_device(h)
    await device.send({"type": "task_prefs", "details": "yes"})
    await asyncio.sleep(0.2)
    assert h.bridge.tasks.details(device.state["device_id"]) is False
    await device.send({"type": "task_prefs", "details": True})
    await asyncio.sleep(0.2)
    assert h.bridge.tasks.details(device.state["device_id"]) is True


async def test_a_flood_of_new_turns_gets_no_live_activity_pushes(h, monkeypatch) -> None:  # noqa: F811
    await offline_device_with_tokens(h)
    await progress(h, started("web_search", 0, turn_id="a"))
    await progress(h, started("web_search", 0, turn_id="b"))  # within 2 s of the last pushing turn
    await asyncio.sleep(0.4)
    assert [event for _, event, _ in h.push.live] == ["start"]
    assert h.bridge.tasks._turn.turn_id == "b" and h.bridge.tasks._turn.pushes is False
    monkeypatch.setattr(tasks_mod, "PUSH_TURN_LIMITS", ((0.0, 1), (3600.0, 1)))
    assert h.bridge.tasks._may_push() is False  # hourly budget used up by turn "a"


async def test_a_turn_without_an_end_times_out(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(tasks_mod, "IDLE_TIMEOUT", 0.4)
    device = await online_device(h)
    await progress(h, started("terminal", 0))
    assert (await next_of(device, "task"))["state"] == "running"
    ended = await next_of(device, "task", timeout=3)
    assert ended["state"] == "done" and ended["step"] == 1


async def test_the_default_turn_id_can_run_again_after_being_replaced(h) -> None:  # noqa: F811
    device = await online_device(h)
    await progress(h, {"tool": "terminal", "index": 0, "state": "started"})  # turn_id "chat"
    assert (await next_of(device, "task"))["turn_id"] == "chat"
    await progress(h, started("web_search", 0, turn_id="x"))
    await progress(h, {"tool": "patch", "index": 1, "state": "started"})  # late event of the replaced turn
    await progress(h, {"turn_id": "x", "state": "done"})
    states = [(m["turn_id"], m["state"]) for m in await drain(device, 1.0) if m["type"] == "task"]
    assert ("chat", "running") not in states and states[-1] == ("x", "done")
    await progress(h, {"tool": "terminal", "index": 0, "state": "started"})  # a new "chat" turn
    task = await next_of(device, "task")
    assert task["turn_id"] == "chat" and task["step"] == 1 and task["state"] == "running"
