"""M7 phone context: /v1/phone/queries ⇄ phone_query/phone_answer through the real relay."""

import asyncio
import time

import pytest

from hermescall_bridge.phone import check_data, parse_params
from hermescall_common import sodium, wire
from hermescall_common.errors import ProtocolError

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401 - stop_devices is a fixture

LOCATION = {"lat": 48.14, "lon": 11.58, "accuracy_m": 1000, "time": "2026-09-29T12:00:00+02:00", "place": {"locality": "Munich"}}


def answering(status: str, data: dict | None = None, seen: list | None = None):
    async def answer(query: dict) -> dict:
        if seen is not None:
            seen.append(query)
        return {"status": status, "data": data} if data is not None else {"status": status}

    return answer


async def silent(query: dict) -> None:
    return None


def ask(h, capability: str = "location", reason: str = "Find restaurants nearby", params: dict | None = None):
    body = {"capability": capability, "reason": reason, "params": params or {}}
    return asyncio.ensure_future(hermes_api(h, "POST", "/v1/phone/queries", body))


def short_timeouts(h) -> None:
    h.bridge.phone.ttl_ms, h.bridge.phone.picker_ttl_ms, h.bridge.phone.grace_ms = 400, 400, 200


async def test_location_query_answered_ok(h) -> None:
    device = await online_device(h)
    seen: list[dict] = []
    device.answer_queries = answering("ok", LOCATION, seen)
    status, result = await asyncio.wait_for(ask(h), 10)
    assert status == 200 and result == {"status": "ok", "data": LOCATION}
    (query,) = seen
    assert query["capability"] == "location" and query["params"] == {"accuracy": "approximate"}
    assert query["reason"] == "Find restaurants nearby" and query["mid"]
    assert len(wire.b64d(query["query_id"])) == 16
    assert abs(query["expires"] - (time.time() * 1000 + 60_000)) < 5_000
    assert (await next_of(device, "query_done"))["query_id"] == query["query_id"]


async def test_picker_queries_get_two_minutes(h) -> None:
    device = await online_device(h)
    seen: list[dict] = []
    device.answer_queries = answering("denied", seen=seen)
    assert (await asyncio.wait_for(ask(h, "photos"), 10))[1] == {"status": "denied"}
    assert seen[0]["params"] == {"max": 1}
    assert abs(seen[0]["expires"] - (time.time() * 1000 + 120_000)) < 5_000


@pytest.mark.parametrize(
    ("first", "second", "expected"),
    [
        ("unavailable", "denied", "denied"),
        ("timeout", "unavailable", "unavailable"),
        ("timeout", "timeout", "timeout"),
        ("denied", "ok", "ok"),
    ],
)
async def test_two_phones_precedence(h, first, second, expected) -> None:
    a = await online_device(h, "Phone A")
    b = await online_device(h, "Phone B")
    a.answer_queries = answering(first)
    b.answer_queries = silent
    query = ask(h, "battery", "Check battery")
    body = await next_of(b, "phone_query")
    await asyncio.sleep(0.3)
    assert not query.done()  # waits for every phone
    await b.answer_query(body, second, {"level": 0.5, "state": "unplugged", "low_power": False} if second == "ok" else None)
    status, result = await asyncio.wait_for(query, 10)
    assert result["status"] == expected
    assert (await next_of(a, "query_done"))["query_id"] == body["query_id"]


async def test_nobody_answers_timeout(h) -> None:
    short_timeouts(h)
    device = await online_device(h)
    device.answer_queries = silent
    started = time.monotonic()
    assert (await asyncio.wait_for(ask(h), 10))[1] == {"status": "timeout"}
    assert time.monotonic() - started < 3
    await next_of(device, "query_done")


@pytest.mark.parametrize(
    "data",
    [
        {**LOCATION, "device_id": "x"},  # extra top-level key
        {"lat": 1, "lon": 2, "place": {"name": "x" * 17_000}},  # > 16 KiB
        ["not", "a", "dict"],
    ],
)
async def test_invalid_ok_answer_counts_as_unavailable(h, data) -> None:
    device = await online_device(h)
    device.answer_queries = answering("ok", data)
    assert (await asyncio.wait_for(ask(h), 10))[1] == {"status": "unavailable"}


async def test_ignored_answers(h) -> None:
    """Wrong query id, untargeted phone, live message without mailbox envelope: all ignored."""
    device = await online_device(h, "Phone A")
    device.answer_queries = silent
    query = ask(h)
    body = await next_of(device, "phone_query")
    late = await online_device(h, "Phone B")  # paired after the query was sent
    await late.answer_query(body, "ok", LOCATION)
    await device.answer_query({**body, "query_id": wire.b64e(sodium.random_bytes(16))}, "ok", LOCATION)
    await device.send({"type": "phone_answer", "query_id": body["query_id"], "status": "ok", "data": LOCATION})
    await asyncio.sleep(0.5)
    assert not query.done()
    await device.answer_query(body, "denied")
    assert (await asyncio.wait_for(query, 10))[1] == {"status": "denied"}


async def test_second_answer_from_the_same_phone_is_ignored(h) -> None:
    a = await online_device(h, "Phone A")
    b = await online_device(h, "Phone B")
    a.answer_queries = b.answer_queries = silent
    query = ask(h)
    body = await next_of(a, "phone_query")
    await a.answer_query(body, "denied")
    await a.answer_query(body, "ok", LOCATION)
    await asyncio.sleep(0.3)
    assert not query.done()
    await b.answer_query(body, "unavailable")
    assert (await asyncio.wait_for(query, 10))[1] == {"status": "denied"}


async def test_busy_rate_limited_and_no_devices(h) -> None:
    assert (await asyncio.wait_for(ask(h), 10))[1] == {"status": "no_devices"}
    device = await online_device(h)
    device.answer_queries = silent
    first, second = ask(h), ask(h, "battery")
    queries = [await next_of(device, "phone_query"), await next_of(device, "phone_query")]
    assert (await asyncio.wait_for(ask(h, "focus"), 10))[1] == {"status": "busy"}
    for body in queries:
        await device.answer_query(body, "denied")
    assert [(await asyncio.wait_for(q, 10))[1]["status"] for q in (first, second)] == ["denied", "denied"]

    now = time.monotonic()
    h.bridge.phone._times.extend([now] * 18)  # 20 in the last 10 minutes
    assert (await asyncio.wait_for(ask(h, "focus"), 10))[1] == {"status": "rate_limited"}
    h.bridge.phone._times.clear()
    h.bridge.phone._times.extend([now - 3600] * 100)  # 100 today
    assert (await asyncio.wait_for(ask(h, "focus"), 10))[1] == {"status": "rate_limited"}


@pytest.mark.parametrize(
    "body",
    [
        {"capability": "microphone", "reason": "x"},
        {"capability": "location", "reason": ""},
        {"capability": "location", "reason": "x" * 301},
        {"capability": "location", "reason": "x", "params": {"accuracy": "exact"}},
        {"capability": "battery", "reason": "x", "params": {"limit": 3}},
        {"capability": "calendar", "reason": "x", "params": {"days": 15}},
        {"capability": "calendar", "reason": "x", "params": {"limit": True}},
        {"capability": "reminders", "reason": "x", "params": {"limit": 31}},
        {"capability": "contacts", "reason": "x"},
        {"capability": "contacts", "reason": "x", "params": {"name": "n" * 101}},
        {"capability": "photos", "reason": "x", "params": {"max": 5}},
        {"capability": "files", "reason": "x", "params": "all"},
    ],
)
async def test_bad_queries_are_rejected(h, body) -> None:
    await online_device(h)
    status, result = await hermes_api(h, "POST", "/v1/phone/queries", body)
    assert status == 400 and result["error"]


def test_params_defaults() -> None:
    assert parse_params("calendar", None) == {"days": 1, "limit": 10}
    assert parse_params("reminders", {}) == {"limit": 15}
    assert parse_params("contacts", {"name": " Anna "}) == {"name": "Anna"}
    assert parse_params("files", {"max": 4}) == {"max": 4}
    assert parse_params("home", {}) == {}


def test_data_checks() -> None:
    assert check_data("focus", {}, {"focused": True}) == ({"focused": True}, [])
    with pytest.raises(ProtocolError):
        check_data("contacts", {"name": "a"}, {"contacts": [{}] * 6})
    with pytest.raises(ProtocolError):
        check_data("clipboard", {}, {"text": "x" * 8001, "has_text": True})
    ref = {"blob_id": wire.b64e(bytes(16)), "key": wire.b64e(bytes(32)), "name": "a.jpg", "mime": "image/jpeg"}
    with pytest.raises(ProtocolError):
        check_data("photos", {"max": 1}, {"files": [ref, ref]})
    with pytest.raises(ProtocolError):
        check_data("photos", {"max": 1}, {"files": [{**ref, "path": "/etc/passwd"}]})
    _, (parsed,) = check_data("photos", {"max": 1}, {"files": [{**ref, "name": "../../x.jpg"}]})
    assert "/" not in parsed.name


async def test_picked_photos_come_back_through_blobs(h) -> None:
    device = await online_device(h)
    photos = [sodium.random_bytes(120_000), sodium.random_bytes(1000)]

    async def pick(query: dict) -> dict:
        files = []
        for n, data in enumerate(photos):
            blob_id, key = await device.upload(data)
            files.append({"blob_id": blob_id, "key": key, "name": f"IMG_{n}.jpg", "mime": "image/jpeg"})
        return {"status": "ok", "data": {"files": files}}

    device.answer_queries = pick
    status, result = await asyncio.wait_for(ask(h, "photos", params={"max": 2}), 20)
    assert status == 200 and result["status"] == "ok" and "data" not in result
    assert [f["name"] for f in result["files"]] == ["IMG_0.jpg", "IMG_1.jpg"]
    assert [wire.b64d(f["data"], max_length=1 << 21) for f in result["files"]] == photos
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()  # downloaded and deleted


async def test_too_many_picked_files_are_rejected_and_deleted(h) -> None:
    device = await online_device(h)

    async def pick(query: dict) -> dict:
        files = []
        for _ in range(2):
            blob_id, key = await device.upload(b"photo")
            files.append({"blob_id": blob_id, "key": key, "name": "a.jpg", "mime": "image/jpeg"})
        return {"status": "ok", "data": {"files": files}}

    device.answer_queries = pick
    assert (await asyncio.wait_for(ask(h, "photos"), 20))[1] == {"status": "unavailable"}
    await asyncio.sleep(0.3)
    assert h.relay.store.blob_ids() == set()


async def test_hermes_token_may_query_and_present_but_not_manage_devices(h) -> None:
    assert (await hermes_api(h, "POST", "/v1/phone/queries", {"capability": "focus", "reason": "x"})) == (
        200,
        {"status": "no_devices"},
    )
    assert (await hermes_api(h, "POST", "/v1/present", {"title": "x"}))[0] == 400
    assert (await hermes_api(h, "GET", "/v1/devices"))[0] == 403


async def test_late_picker_answer_blobs_are_deleted(h) -> None:
    short_timeouts(h)
    device = await online_device(h)
    device.answer_queries = silent
    query = ask(h, "photos")
    body = await next_of(device, "phone_query")
    assert (await asyncio.wait_for(query, 10))[1] == {"status": "timeout"}
    blob_id, key = await device.upload(b"late photo")
    await device.answer_query(body, "ok", {"files": [{"blob_id": blob_id, "key": key, "name": "a.jpg", "mime": "image/jpeg"}]})
    await asyncio.sleep(0.5)
    assert h.relay.store.blob_ids() == set()


async def test_unpaired_phone_stops_the_wait(h) -> None:
    from .test_bridge_flows import api

    device = await online_device(h)
    device.answer_queries = silent
    query = ask(h)
    await next_of(device, "phone_query")
    started = time.monotonic()
    assert (await api(h, "DELETE", f"/v1/devices/{device.state['device_id']}"))[0] == 200
    assert (await asyncio.wait_for(query, 10))[1] == {"status": "unavailable"}
    assert time.monotonic() - started < 3


async def test_mail_failure_counts_as_unavailable(h, monkeypatch) -> None:
    await online_device(h)
    request = h.bridge.relay.request

    async def failing(message: dict) -> dict:
        if message.get("t") == "mail":
            raise ProtocolError("mailbox_full")
        return await request(message)

    monkeypatch.setattr(h.bridge.relay, "request", failing)
    started = time.monotonic()
    assert (await asyncio.wait_for(ask(h), 10))[1] == {"status": "unavailable"}
    assert time.monotonic() - started < 3
