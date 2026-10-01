# SPDX-License-Identifier: MIT
"""D5: attachments go through a spool on disk (sealed, 0600), not base64 inside the event queue; the
adapter fetches them one by one; other phones get the same sealed blob instead of a label."""

import stat

from aiohttp import ClientSession

from hermescall_common import sodium, wire

from .conftest import CALL_TOKEN
from .test_bridge_flows import h  # noqa: F401 - h is a fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401


async def poll_files(h, cursor: int = 0, wait: float = 5) -> tuple[int, list[dict]]:  # noqa: F811
    status, result = await hermes_api(h, "GET", f"/v1/chat/events?cursor={cursor}&wait={wait}&files=1")
    assert status == 200
    return result["cursor"], result["events"]


async def fetch_file(h, file_id: str) -> tuple[int, bytes]:  # noqa: F811
    async with (
        ClientSession() as session,
        session.get(
            f"http://127.0.0.1:{h.api_port}/v1/chat/files/{file_id}", headers={"Authorization": f"Bearer {CALL_TOKEN}"}
        ) as response,
    ):
        return response.status, await response.read()


def spool(h):  # noqa: F811
    return h.bridge.chat.files.directory


async def test_attachment_is_spooled_and_fetched_not_inlined(h) -> None:  # noqa: F811
    device = await online_device(h)
    photo = sodium.random_bytes(300_000)
    await device.send_chat("look", [("photo", "IMG_1.jpg", "image/jpeg", photo)])
    cursor, events = await poll_files(h)
    (attachment,) = events[0]["attachments"]
    assert "data" not in attachment and attachment["size"] == len(photo)
    assert attachment["kind"] == "photo" and attachment["name"] == "IMG_1.jpg"
    stored = list(spool(h).iterdir())
    assert len(stored) == 1 and stat.S_IMODE(stored[0].stat().st_mode) == 0o600
    assert photo not in stored[0].read_bytes(), "the spool keeps the sealed blob, not the plaintext"
    status, body = await fetch_file(h, attachment["file_id"])
    assert status == 200 and body == photo
    assert (await fetch_file(h, "A" * 22))[0] == 404


async def test_spooled_file_goes_once_hermes_has_the_event_and_history_does_not_need_it(h, monkeypatch) -> None:  # noqa: F811
    device = await online_device(h)
    monkeypatch.setattr(h.bridge.chat, "history_limit", 0)
    await device.send_chat("look", [("file", "a.txt", "text/plain", b"hello file")])
    cursor, events = await poll_files(h)
    file_id = events[0]["attachments"][0]["file_id"]
    await poll_files(h, cursor, wait=0)  # acks
    assert (await fetch_file(h, file_id))[0] == 404
    assert list(spool(h).iterdir()) == []


async def test_older_adapters_still_get_inline_data(h) -> None:  # noqa: F811
    device = await online_device(h)
    await device.send_chat("x", [("file", "a.txt", "text/plain", b"legacy")])
    _, result = await hermes_api(h, "GET", "/v1/chat/events?cursor=0&wait=5")
    (attachment,) = result["events"][0]["attachments"]
    assert wire.b64d(attachment["data"], max_length=100) == b"legacy"


async def test_other_phones_get_the_attachment_itself(h) -> None:  # noqa: F811
    first = await online_device(h, "Phone A")
    second = await online_device(h, "Phone B")
    photo = sodium.random_bytes(50_000)
    await first.send_chat("from A", [("photo", "IMG.jpg", "image/jpeg", photo)])
    mirrored = await next_of(second, "chat")
    assert mirrored["role"] == "owner" and mirrored["text"] == "from A"
    (ref,) = mirrored["attachments"]
    assert ref["name"] == "IMG.jpg" and ref["kind"] == "photo" and ref["size"] == len(photo)
    assert await second.fetch_attachment(ref) == photo


async def test_agent_file_is_sealed_once_for_all_phones(h) -> None:  # noqa: F811
    first = await online_device(h, "Phone A")
    second = await online_device(h, "Phone B")
    report = b"%PDF-1.7 shared report"
    body = {"kind": "file", "name": "report.pdf", "mime": "application/pdf", "data": wire.b64e(report)}
    assert (await hermes_api(h, "POST", "/v1/chat/files", body))[0] == 200
    refs = [(await next_of(phone, "chat"))["attachments"][0] for phone in (first, second)]
    assert refs[0]["key"] == refs[1]["key"] and refs[0]["blob_id"] != refs[1]["blob_id"]
    assert [await phone.fetch_attachment(ref) for phone, ref in zip((first, second), refs, strict=True)] == [report, report]
