# SPDX-License-Identifier: MIT
"""D4: a phone paired later gets the recent chat (history_request → history_page)."""

import asyncio
import json

from hermescall_bridge import history as history_mod
from hermescall_bridge.chatstore import AsyncStore, ChatStore, StoredFile
from hermescall_common import sodium, wire
from hermescall_common.e2e import MAX_PLAINTEXT
from hermescall_common.errors import ProtocolError

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


class FakeSpool:
    """Spooled files by id; `upload` records each relay upload (or fails while `failing`)."""

    def __init__(self) -> None:
        self.files: dict[str, StoredFile] = {}
        self.uploads: list[str] = []
        self.failing = False

    def add(self, message_id: str, name: str = "a.jpg") -> str:
        file_id = wire.b64e(sodium.random_bytes(16))
        self.files[file_id] = StoredFile(file_id, message_id, wire.b64e(bytes(32)), "photo", name, "image/jpeg", 10)
        return file_id

    async def get(self, file_id: str) -> StoredFile | None:
        return self.files.get(file_id)

    async def upload(self, relay, file: StoredFile, to: str) -> dict:
        if self.failing:
            raise OSError("relay quota")
        self.uploads.append(file.file_id)
        return {**file.meta(), "blob_id": wire.b64e(sodium.random_bytes(16)), "key": file.key}

    async def collect(self) -> int:
        return 0


def history(tmp_path) -> tuple[history_mod.ChatHistory, FakeSpool, AsyncStore]:
    db = AsyncStore(ChatStore(tmp_path / "chat.db"))
    spool = FakeSpool()
    return history_mod.ChatHistory(db, spool, relay=None), spool, db


def plaintext_size(page: dict) -> int:
    """What Channel.seal measures against MAX_PLAINTEXT (envelope fields included)."""
    envelope = {**page, "from": "b" * 22, "to": "d" * 22, "ts": 1 << 42}
    return len(json.dumps(envelope, separators=(",", ":")))


async def test_a_page_with_long_non_ascii_messages_stays_within_the_e2e_limit(tmp_path) -> None:
    chat_history, _, db = history(tmp_path)
    for n in range(3):
        body = {"id": f"m{n}", "role": "owner", "kind": "text", "text": "😀" * 8000, "transcript": "語" * 12_000}
        await chat_history.record(body, [], 200)
    pages, before = [], None
    while True:
        page = await chat_history.page("dev", before, None)
        pages.append(page)
        assert plaintext_size(page) <= MAX_PLAINTEXT, plaintext_size(page)
        assert len(json.dumps(page["messages"], separators=(",", ":"))) <= history_mod.PAGE_BYTES + 8
        if not page["more"]:
            break
        before = page["next"]
    assert [m["id"] for p in pages for m in p["messages"]] == ["m2", "m1", "m0"]
    assert all(m["text"].startswith("😀") for p in pages for m in p["messages"])
    db.close()


async def test_a_page_that_cannot_be_sealed_is_skipped_but_history_moves_on(tmp_path, monkeypatch) -> None:
    from .test_chat_durable import service

    chat, relay, device = service(tmp_path)

    def refuse(*args, **kwargs):
        raise ProtocolError("message too large")

    sent: list[dict] = []

    async def live(target, body) -> bool:
        if body.get("messages"):
            refuse()
        sent.append(body)
        return True

    monkeypatch.setattr(chat._transport, "live", live)
    for n in range(3):
        await chat.send_text(f"message {n}")
    await chat.handle(device, {"type": "history_request", "limit": 2})
    (page,) = sent
    assert page["type"] == "history_page" and page["messages"] == [] and page["more"] is True and page["next"]
    await chat.close()


async def test_attachments_are_uploaded_only_for_messages_that_fit_the_page(tmp_path, monkeypatch) -> None:
    chat_history, spool, db = history(tmp_path)
    file_id = spool.add("old")
    await chat_history.record({"id": "old", "role": "agent", "kind": "text", "text": "x" * 12_000}, [file_id], 200)
    for n in range(3):
        await chat_history.record({"id": f"new{n}", "role": "agent", "kind": "text", "text": "y" * 9_000}, [], 200)
    page = await chat_history.page("dev", None, None)
    assert "old" not in [m["id"] for m in page["messages"]] and page["more"]
    assert spool.uploads == [], "no upload (and no budget) for a message left for the next page"
    rest = await chat_history.page("dev", page["next"], None)
    assert [m["id"] for m in rest["messages"]] == ["old"] and spool.uploads == [file_id]
    assert len(rest["messages"][0]["attachments"]) == 1
    db.close()


async def test_a_failed_history_upload_gives_its_budget_back(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(history_mod, "SYNC_FILES", 1)
    chat_history, spool, db = history(tmp_path)
    file_id = spool.add("m")
    await chat_history.record({"id": "m", "role": "agent", "kind": "text", "text": "pic"}, [file_id], 200)
    spool.failing = True
    (message,) = (await chat_history.page("dev", None, None))["messages"]
    assert message["text"] == "pic\n[photo: a.jpg]"
    spool.failing = False
    (message,) = (await chat_history.page("dev", None, None))["messages"]
    assert len(message["attachments"]) == 1 and spool.uploads == [file_id]
    db.close()
