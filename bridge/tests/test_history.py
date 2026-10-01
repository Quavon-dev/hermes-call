# SPDX-License-Identifier: MIT
"""D4: a phone paired later gets the recent chat (history_request → history_page)."""

import asyncio

from hermescall_bridge import history as history_mod
from hermescall_common import wire

from .test_bridge_flows import h  # noqa: F401 - h is a fixture
from .test_chat import hermes_api, next_of, online_device, poll, stop_devices  # noqa: F401


async def request(device, before=None, limit=None) -> dict:
    body = {"type": "history_request"}
    if before is not None:
        body["before"] = before
    if limit is not None:
        body["limit"] = limit
    await device.send(body)
    return await next_of(device, "history_page")


async def test_new_phone_gets_the_recent_chat_newest_first(h) -> None:  # noqa: F811
    first = await online_device(h, "Phone A")
    owner_id = await first.send_chat("What's the weather?")
    await next_of(first, "chat_ack")
    await poll(h)
    assert (await hermes_api(h, "POST", "/v1/chat/messages", {"text": "Sunny, 21 °C."}))[0] == 200
    report = b"%PDF quarterly"
    body = {"kind": "file", "name": "q3.pdf", "mime": "application/pdf", "data": wire.b64e(report), "caption": "Report"}
    assert (await hermes_api(h, "POST", "/v1/chat/files", body))[0] == 200

    later = await online_device(h, "Phone B")
    page = await request(later)
    assert page["more"] is False and page["next"] is None
    texts = [(m["role"], m["text"]) for m in page["messages"]]
    assert texts == [("agent", "Report"), ("agent", "Sunny, 21 °C."), ("owner", "What's the weather?")]
    assert page["messages"][2]["id"] == owner_id and all(isinstance(m["ts"], int) for m in page["messages"])
    (ref,) = page["messages"][0]["attachments"]
    assert ref["name"] == "q3.pdf" and await later.fetch_attachment(ref) == report


async def test_history_is_paged_and_bounded(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(h.bridge.chat, "history_limit", 5)
    for n in range(8):
        await h.bridge.chat.send_text(f"message {n}")
    device = await online_device(h)
    page = await request(device, limit=3)
    assert [m["text"] for m in page["messages"]] == ["message 7", "message 6", "message 5"]
    assert page["more"] is True
    older = await request(device, before=page["next"], limit=3)
    assert [m["text"] for m in older["messages"]] == ["message 4", "message 3"] and older["more"] is False


async def test_trimmed_history_frees_its_files(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(h.bridge.chat, "history_limit", 1)
    await h.bridge.chat.send_file(b"old file", "a.txt", "text/plain", "file")
    assert len(list(h.bridge.chat.files.directory.iterdir())) == 1
    await h.bridge.chat.send_text("newer")
    assert list(h.bridge.chat.files.directory.iterdir()) == []


async def test_attachments_beyond_the_budget_become_a_line(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(history_mod, "SYNC_FILES", 0)
    await h.bridge.chat.send_file(b"x", "photo.jpg", "image/jpeg", "photo", "pic")
    device = await online_device(h)
    (message,) = (await request(device))["messages"]
    assert "attachments" not in message and message["text"] == "pic\n[photo: photo.jpg]"


async def test_bridge_lists_history_and_limits_requests(h, monkeypatch) -> None:  # noqa: F811
    device = await online_device(h)
    await device.send({"type": "hello", "v": 1, "caps": ["history"]})
    assert "history" in (await next_of(device, "hello"))["caps"]
    monkeypatch.setattr(history_mod, "REQUEST_LIMIT", (600.0, 1))
    await request(device)
    await device.send({"type": "history_request"})
    await asyncio.sleep(0.3)
    assert all(body["type"] != "history_page" for body in list(device.inbox._queue))
