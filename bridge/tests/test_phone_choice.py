"""E10: with several phones the most recently active one answers; write capabilities go to one phone."""

import asyncio
import json

import pytest

from hermescall_bridge import phone as phone_mod
from hermescall_bridge.phone import PhoneService, parse_params
from hermescall_bridge.state import State, new_device
from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .test_chat_durable import JsonChannel, MailRelay


def phones(activity: dict[str, float]) -> tuple[PhoneService, MailRelay, dict]:
    devices = {
        name: new_device(wire.b64e(name.encode() * 16), name, wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
        for name in ("a", "b")
    }
    relay = MailRelay()
    service = PhoneService(State(keys={}, devices={d.id: d for d in devices.values()}), relay, JsonChannel())
    service.recent_activity = lambda device_id: activity.get(device_id, float("-inf"))
    return service, relay, devices


async def asked(relay: MailRelay) -> dict:
    while not relay.mailed:
        await asyncio.sleep(0.01)
    return json.loads(relay.mailed[-1]["data"])


def answer(query: dict, status: str = "ok", data: dict | None = None) -> dict:
    body = {"type": "phone_answer", "mid": "m", "query_id": query["query_id"], "status": status}
    return {**body, "data": data} if data is not None else body


async def test_ok_from_the_phone_in_use_wins_over_a_faster_idle_phone(monkeypatch) -> None:
    monkeypatch.setattr(phone_mod, "PREFER_WAIT", 5.0)
    service, relay, devices = phones({})
    a, b = devices["a"], devices["b"]
    service.recent_activity = lambda device_id: {b.id: 10.0, a.id: 1.0}.get(device_id, float("-inf"))
    task = asyncio.ensure_future(service.query("battery", "check"))
    query = await asked(relay)
    await service.on_answer(a, answer(query, data={"level": 0.2}))  # the idle phone is faster
    await asyncio.sleep(0.05)
    assert not task.done(), "the idle phone's answer waits for the phone in use"
    await service.on_answer(b, answer(query, data={"level": 0.9}))
    assert (await task)["data"] == {"level": 0.9}


async def test_idle_phone_answer_is_used_when_the_active_one_declines_or_is_slow(monkeypatch) -> None:
    monkeypatch.setattr(phone_mod, "PREFER_WAIT", 0.1)
    service, relay, devices = phones({})
    a, b = devices["a"], devices["b"]
    service.recent_activity = lambda device_id: {b.id: 10.0}.get(device_id, float("-inf"))
    task = asyncio.ensure_future(service.query("battery", "check"))
    query = await asked(relay)
    await service.on_answer(a, answer(query, data={"level": 0.2}))
    assert (await asyncio.wait_for(task, 2))["data"] == {"level": 0.2}  # b never answered
    task = asyncio.ensure_future(service.query("battery", "again"))
    relay.mailed.clear()
    query = await asked(relay)
    await service.on_answer(b, answer(query, "denied"))
    await service.on_answer(a, answer(query, data={"level": 0.3}))
    assert (await asyncio.wait_for(task, 1))["data"] == {"level": 0.3}


async def test_without_activity_the_first_ok_wins_at_once() -> None:
    service, relay, devices = phones({})
    task = asyncio.ensure_future(service.query("battery", "check"))
    query = await asked(relay)
    await service.on_answer(devices["a"], answer(query, data={"level": 0.5}))
    assert (await asyncio.wait_for(task, 1))["status"] == "ok"


async def test_write_goes_to_the_most_recent_phone_only() -> None:
    service, relay, devices = phones({})
    b = devices["b"]
    service.recent_activity = lambda device_id: 5.0 if device_id == b.id else float("-inf")
    params = {"title": "Buy milk", "due": "2026-10-01T09:00:00+02:00"}
    task = asyncio.ensure_future(service.query("reminder_create", "you asked me to", params))
    query = await asked(relay)
    assert [m["to"] for m in relay.mailed] == [b.id]
    assert query["params"] == {"title": "Buy milk", "due": "2026-10-01T09:00:00+02:00"}
    await service.on_answer(b, answer(query, data={"ok": True, "id": "x-1"}))
    assert await asyncio.wait_for(task, 1) == {"status": "ok", "data": {"ok": True, "id": "x-1"}}


@pytest.mark.parametrize(
    ("capability", "params"),
    [
        ("reminder_create", {}),
        ("reminder_create", {"title": "x" * 201}),
        ("reminder_create", {"title": "x", "due": "tomorrow"}),
        ("reminder_create", {"title": "x", "due": "2026-10-01T09:00:00"}),  # no offset
        ("reminder_create", {"title": "x", "list": "Groceries"}),
        ("calendar_create", {"title": "x", "start": "2026-10-01T09:00:00+00:00"}),
        ("calendar_create", {"title": "x", "start": "2026-10-01T09:00:00+00:00", "end": "2026-10-01T08:00:00+00:00"}),
        ("calendar_create", {"title": "x", "start": "2026-10-01T09:00:00+00:00", "end": "2026-10-16T09:00:00+00:00"}),
        ("calendar_create", {"title": "x", "start": "2026-10-01T09:00:00Z", "end": "2026-10-01T10:00:00Z", "notes": "n" * 1001}),
    ],
)
def test_write_params_are_validated(capability, params) -> None:
    with pytest.raises(ValueError):
        parse_params(capability, params)


def test_calendar_params_ok() -> None:
    params = {"title": " Dentist ", "start": "2026-10-01T09:00:00Z", "end": "2026-10-01T10:00:00Z", "location": "Main St"}
    assert parse_params("calendar_create", params) == {
        "title": "Dentist",
        "start": "2026-10-01T09:00:00+00:00",
        "end": "2026-10-01T10:00:00+00:00",
        "location": "Main St",
    }


@pytest.mark.parametrize(
    "data", [{"ok": True}, {"ok": False, "id": "x"}, {"ok": True, "id": ""}, {"ok": True, "id": "x", "extra": 1}]
)
def test_write_answers_carry_only_ok_and_id(data) -> None:
    with pytest.raises(ProtocolError):
        phone_mod.check_data("reminder_create", {}, data)
