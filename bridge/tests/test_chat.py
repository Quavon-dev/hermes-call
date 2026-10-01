"""M6 chat: phone ⇄ bridge ⇄ Hermes adapter API, through the real relay (TLS, mailbox, blobs)."""

import asyncio
import os
from pathlib import Path

import pytest
from aiohttp import ClientSession

from hermescall_common import sodium, wire

from .conftest import CALL_TOKEN
from .test_bridge_flows import connect, h, pair_device  # noqa: F401 - h is a fixture

WAV = Path(__file__).parent / "data" / "question.wav"


async def hermes_api(h, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    """What the Hermes plugin does: the ring/chat token, never the admin token."""
    async with (
        ClientSession() as session,
        session.request(
            method, f"http://127.0.0.1:{h.api_port}{path}", json=body, headers={"Authorization": f"Bearer {CALL_TOKEN}"}
        ) as response,
    ):
        return response.status, await response.json(content_type=None)


async def poll(h, cursor: int = 0, wait: float = 5) -> tuple[int, list[dict]]:
    status, result = await hermes_api(h, "GET", f"/v1/chat/events?cursor={cursor}&wait={wait}")
    assert status == 200
    return result["cursor"], result["events"]


async def next_of(device, kind: str, timeout: float = 10) -> dict:
    while True:
        body = await asyncio.wait_for(device.inbox.get(), timeout)
        if body["type"] == kind:
            return body


@pytest.fixture(autouse=True)
async def stop_devices(h):
    h.devices = []
    yield
    for device in h.devices:
        device.session.stop()
    await asyncio.sleep(0)


async def online_device(h, name: str = "Test phone"):
    device = await pair_device(h, name)
    h.devices.append(device)
    await connect(device)
    return device


async def test_owner_message_reaches_hermes_and_is_acked(h) -> None:
    device = await online_device(h)
    message_id = await device.send_chat("What's on my calendar?")
    ack = await next_of(device, "chat_ack")
    assert ack == {**ack, "id": message_id, "state": "delivered"}
    cursor, events = await poll(h)
    assert len(events) == 1
    event = events[0]
    assert event["type"] == "message" and event["chat_id"] == "owner" and event["id"] == message_id
    assert event["text"] == "What's on my calendar?" and event["user_id"] == device.state["device_id"]
    assert event["user_name"] == "Test phone"
    # Polling with the new cursor acknowledges; nothing is delivered twice.
    assert await poll(h, cursor, wait=0) == (cursor, [])


async def test_replayed_chat_message_is_ignored(h) -> None:
    device = await online_device(h)
    mid = wire.b64e(sodium.random_bytes(16))
    body = {"type": "chat", "id": wire.b64e(sodium.random_bytes(16)), "text": "once"}
    sealed = device.channel.seal(device.bridge_id, device.bridge_pk, body, mid=mid)
    for _ in range(2):
        await device.session.send({"t": "e2e", "data": sealed})
    await asyncio.sleep(0.5)
    _, events = await poll(h, wait=0)
    assert len(events) == 1


async def test_live_chat_without_mailbox_envelope_is_rejected(h) -> None:
    device = await online_device(h)
    await device.send({"type": "chat", "id": wire.b64e(sodium.random_bytes(16)), "text": "no mid"})
    await asyncio.sleep(0.3)
    assert (await poll(h, wait=0))[1] == []


async def test_agent_message_reaches_online_and_offline_phones(h) -> None:
    online = await online_device(h, "Phone A")
    offline = await pair_device(h, "Phone B")
    h.devices.append(offline)
    status, sent = await hermes_api(h, "POST", "/v1/chat/messages", {"text": "Your build finished ✅"})
    assert status == 200
    body = await next_of(online, "chat")
    assert body["role"] == "agent" and body["text"] == "Your build finished ✅" and body["id"] == sent["message_id"]
    assert body["mid"]  # mailbox envelope
    await asyncio.sleep(0.3)
    assert h.relay.store.pending_mail(online.state["device_id"]) == []  # acked
    assert len(h.relay.store.pending_mail(offline.state["device_id"])) == 1

    await connect(offline)
    await offline.session.request({"t": "mail_fetch"})
    assert (await next_of(offline, "chat"))["text"] == "Your build finished ✅"


async def test_messages_from_one_phone_are_mirrored_to_the_others(h) -> None:
    first = await online_device(h, "Phone A")
    second = await online_device(h, "Phone B")
    await first.send_chat("hi from A")
    mirrored = await next_of(second, "chat")
    assert mirrored["role"] == "owner" and mirrored["text"] == "hi from A"


async def test_photo_from_phone_and_file_from_agent(h) -> None:
    device = await online_device(h)
    photo = sodium.random_bytes(150_000)
    await device.send_chat("look", [("photo", "IMG_1.jpg", "image/jpeg", photo)])
    _, events = await poll(h)
    (attachment,) = events[0]["attachments"]
    assert attachment["kind"] == "photo" and attachment["mime"] == "image/jpeg" and attachment["name"] == "IMG_1.jpg"
    assert wire.b64d(attachment["data"], max_length=1 << 21) == photo
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()  # the bridge deletes blobs after download

    report = b"%PDF-1.7 fake report"
    body = {"kind": "file", "name": "report.pdf", "mime": "application/pdf", "data": wire.b64e(report), "caption": "Here"}
    assert (await hermes_api(h, "POST", "/v1/chat/files", body))[0] == 200
    message = await next_of(device, "chat")
    (ref,) = message["attachments"]
    assert message["text"] == "Here" and ref["name"] == "report.pdf" and ref["size"] == len(report)
    assert await device.fetch_attachment(ref) == report


async def test_voice_note_is_transcribed_on_the_bridge(h) -> None:
    device = await online_device(h)
    await device.send_chat("", [("voice", "voice.m4a", "audio/mp4", WAV.read_bytes())])
    ack = await next_of(device, "chat_ack")
    assert ack["state"] == "delivered"
    ack = await next_of(device, "chat_ack")
    assert ack["state"] == "transcribed" and ack["transcript"] == "hello hermes"
    _, events = await poll(h)
    assert events[0]["text"] == "[Voice note] hello hermes" and events[0]["attachments"] == []


async def test_chat_approval_roundtrip(h) -> None:
    device = await online_device(h)
    device.approve = None  # answer by hand below
    body = {"request_id": "sess-1", "command": "rm -rf /tmp/x", "description": "delete files"}
    assert (await hermes_api(h, "POST", "/v1/chat/approvals", body)) == (200, {"status": "sent"})
    request = await next_of(device, "approval_request")
    assert request["chat"] is True and request["command"] == "rm -rf /tmp/x" and "call_id" not in request
    await device.send({"type": "approval", "request_id": "unknown", "choice": "once"}, mail=True)
    await device.send({"type": "approval", "request_id": "sess-1", "choice": "once"}, mail=True)
    _, events = await poll(h)
    assert events == [{"type": "approval", "chat_id": "owner", "request_id": "sess-1", "choice": "once"}]
    # Answered once only.
    await device.send({"type": "approval", "request_id": "sess-1", "choice": "deny"}, mail=True)
    await asyncio.sleep(0.3)
    assert (await poll(h, 1, wait=0))[1] == []


async def test_chat_approval_offers_only_the_choices_hermes_allows(h) -> None:
    device = await online_device(h)
    device.approve = None
    body = {"request_id": "sess-2", "command": "rm -rf /tmp/y", "description": "smart-denied", "choices": ["once", "deny"]}
    assert (await hermes_api(h, "POST", "/v1/chat/approvals", body)) == (200, {"status": "sent"})
    request = await next_of(device, "approval_request")
    assert request["choices"] == ["once", "deny"]
    await device.send({"type": "approval", "request_id": "sess-2", "choice": "session"}, mail=True)
    _, events = await poll(h)
    assert events == [{"type": "approval", "chat_id": "owner", "request_id": "sess-2", "choice": "deny"}]


async def test_chat_approval_choices_must_include_once_and_deny(h) -> None:
    await online_device(h)
    body = {"request_id": "sess-3", "command": "x", "description": "", "choices": ["session"]}
    status, _ = await hermes_api(h, "POST", "/v1/chat/approvals", body)
    assert status == 400


async def test_overlong_approval_is_denied_not_shown(h) -> None:
    await online_device(h)
    body = {"request_id": "x", "command": "a" * 4001, "description": ""}
    assert (await hermes_api(h, "POST", "/v1/chat/approvals", body)) == (200, {"status": "denied"})


async def test_missed_call_becomes_a_chat_message(h) -> None:
    device = await online_device(h)
    ring = asyncio.ensure_future(
        hermes_api(h, "POST", "/v1/calls", {"reason": "server down", "first_message": "The server is down."})
    )
    invite = await next_of(device, "invite")
    await device.send({"type": "decline", "call_id": invite["call_id"]})
    status, result = await asyncio.wait_for(ring, 10)
    assert result["status"] == "declined" and result["messaged"] is True
    message = await next_of(device, "chat")
    assert message["kind"] == "declined_call" and message["text"].startswith("The server is down.")


async def test_call_transcript_is_context_for_the_next_chat_message(h) -> None:
    device = await online_device(h)
    h.bridge.chat.note_call([("owner", "remind me about the dentist"), ("Hermes", "Will do.")])
    await device.send_chat("thanks")
    _, events = await poll(h)
    assert events[0]["text"].startswith("[Context: a phone call with your owner ended")
    assert "remind me about the dentist" in events[0]["text"] and events[0]["text"].endswith("thanks")
    assert "Recent chat messages" in h.bridge.chat.recent_context()


async def test_hermes_token_is_limited_to_calls_and_chat(h) -> None:
    assert (await hermes_api(h, "GET", "/v1/devices"))[0] == 403
    assert (await hermes_api(h, "POST", "/v1/devices/pairing", {"name": "x"}))[0] == 403
    assert (await hermes_api(h, "GET", "/v1/chat/events?cursor=0&wait=0"))[0] == 200
    assert (await hermes_api(h, "POST", "/v1/chat/messages", {"text": " "}))[0] == 400
    assert (await hermes_api(h, "POST", "/v1/chat/files", {"kind": "exe", "data": ""}))[0] == 400


HERMES_DIR = Path(os.environ.get("HERMES_AGENT_DIR") or Path.home() / ".hermes" / "hermes-agent")
HERMES_PYTHON = Path(os.environ.get("HERMES_AGENT_PYTHON") or HERMES_DIR / "venv" / "bin" / "python3")
PLUGIN_DIR = Path(__file__).resolve().parents[2] / "hermes-integration" / "hermes-call"


@pytest.mark.skipif(not HERMES_PYTHON.exists(), reason="needs a local Hermes checkout (~/.hermes/hermes-agent)")
async def test_adapter_against_real_hermes_gateway_classes(h, tmp_path) -> None:
    import json
    import struct
    import zlib

    def png() -> bytes:
        def chunk(kind: bytes, data: bytes) -> bytes:
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0")) + chunk(b"IEND", b"")

    device = await online_device(h)
    photo = tmp_path / "chart.png"
    photo.write_bytes(png())
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
        "HERMES_HOME": str(tmp_path / "hermes-home"),
        "HERMES_CALL_TOKEN": CALL_TOKEN,
        "HERMES_CALL_URL": f"http://127.0.0.1:{h.api_port}",
    }
    process = await asyncio.create_subprocess_exec(
        str(HERMES_PYTHON),
        str(Path(__file__).parent / "hermes_adapter_smoke.py"),
        str(HERMES_DIR),
        str(PLUGIN_DIR),
        str(photo),
        env=env,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    async def step() -> dict:
        line = await asyncio.wait_for(process.stdout.readline(), 60)
        if not line:
            raise AssertionError((await process.stderr.read()).decode()[-3000:])
        return json.loads(line)

    registered = await step()
    assert registered == {
        "step": "registered",
        "check": True,
        "home": {"home_channel": {"chat_id": "owner", "name": "Hermes Call"}},
        "hint": True,
    }
    assert (await step())["step"] == "connected"
    await device.send_chat("status?", [("photo", "IMG.png", "image/png", png())])
    message = await step()
    assert message["text"] == "status?" and message["type"] == "photo" and message["media"] == [True]
    assert message["user"] == "owner" and message["chat"] == "owner" and message["platform"] == "hermes_call"
    progress = await step()
    assert progress["chrome"] is None and progress["hooks"] == ["post_tool_call", "pre_tool_call"]
    task = await next_of(device, "task")
    assert task["turn_id"] == progress["turn"] and len(progress["turn"]) == 22 and task["step"] == 1
    assert task["label"] == "Searching the web" and "weather munich" in task["preview"]
    assert (await next_of(device, "task"))["state"] == "done"
    assert (await step()) == {"step": "sent", "success": True}
    first = await next_of(device, "chat")
    assert "**markdown**" in first["text"] and first["role"] == "agent" and len(first["text"]) <= 8000
    assert (await step()) == {"step": "file", "success": True}
    while "attachments" not in (message := await next_of(device, "chat")):
        assert message["role"] == "agent"  # remaining chunks of the long reply
    assert message["attachments"][0]["kind"] == "photo" and message["text"] == "chart"
    assert (await step()) == {"step": "standalone", "success": True}
    assert (await next_of(device, "chat"))["text"] == "from cron"
    device.approve = None
    assert (await step()) == {"step": "approval_sent", "success": True}
    request = await next_of(device, "approval_request")
    await device.send({"type": "approval", "request_id": request["request_id"], "choice": "once"}, mail=True)
    assert (await step()) == {"step": "approval_resolved", "resolved": [["session-key-1", "once"]]}
    assert (await step()) == {"step": "real_resolver", "pending": 0}
    # Hermes >= 0.21: two real pending approvals, the newer answered first, each by its own id.
    sheets = {}
    real = asyncio.ensure_future(step())
    while not real.done() and len(sheets) < 2:
        try:
            request = await next_of(device, "approval_request", timeout=1)
        except TimeoutError:
            continue
        sheets[request["command"]] = request["request_id"]
        if len(sheets) == 2:
            for command, choice in (("touch /tmp/newer", "once"), ("touch /tmp/older", "deny")):
                await device.send({"type": "approval", "request_id": sheets[command], "choice": choice}, mail=True)
    answered = {"step": "real_approvals", "older": "deny", "newer": "once"}
    assert (await real) in ({"step": "real_approvals", "skipped": True}, answered)
    assert (await step())["step"] == "done"
    await process.wait()


async def test_resent_message_is_acked_again_but_delivered_once(h) -> None:
    device = await online_device(h)
    body = {"type": "chat", "id": wire.b64e(sodium.random_bytes(16)), "text": "retry me"}
    for _ in range(2):
        await device.send(body, mail=True)
        assert (await next_of(device, "chat_ack"))["state"] == "delivered"
    _, events = await poll(h, wait=1)
    assert len(events) == 1
