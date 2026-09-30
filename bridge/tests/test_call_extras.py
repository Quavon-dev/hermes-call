"""M9 calls: tool progress from the chat-completions stream (§1) and "look at this" images (§8)."""

import asyncio
import base64
import io
import json

import httpx
import pytest
from PIL import Image

from hermescall_bridge import calls as calls_mod
from hermescall_bridge.audio import SpeechTrack
from hermescall_bridge.calls import ActiveCall
from hermescall_bridge.conversation import Conversation
from hermescall_bridge.hermes import HermesClient, TextDelta, ToolProgress
from hermescall_bridge.tasks import Progress
from hermescall_common import sodium, wire

from .conftest import FakeHermes, FakeTts
from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_units import sse


def jpeg(width: int = 2000, height: int = 1000, fmt: str = "JPEG") -> bytes:
    out = io.BytesIO()
    image = Image.new("RGB", (width, height), (200, 120, 30))
    exif = Image.Exif()
    exif[0x010F] = "SecretCam"  # Make
    image.save(out, fmt, exif=exif) if fmt == "JPEG" else image.save(out, fmt)
    return out.getvalue()


# ---- Hermes stream ---------------------------------------------------------


async def test_hermes_stream_tool_progress_and_image_parts() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        body = sse(
            ("hermes.tool.progress", {"tool": "web_search", "label": "weather", "toolCallId": "c1", "status": "running"}),
            ("hermes.tool.progress", {"tool": "_thinking", "toolCallId": "c0", "status": "running"}),
            ("hermes.tool.progress", {"tool": "web_search", "toolCallId": "c1", "status": "completed"}),
            ("hermes.tool.progress", {"tool": "x", "status": "running"}),
            ("", {"id": "chatcmpl-1", "choices": [{"delta": {"content": "Sunny."}}]}),
            ("", "[DONE]"),
        )
        return httpx.Response(200, content=body, headers={"content-type": "text/event-stream"})

    client = HermesClient("http://127.0.0.1:8642", "key", "phone-session")
    client._client = httpx.AsyncClient(base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(handler))
    events = [e async for e in client.turn("sys", "what is this?", images=[b"\xff\xd8jpeg"])]
    assert events == [
        ToolProgress("web_search", "running", "c1", "weather"),
        ToolProgress("web_search", "completed", "c1", ""),
        TextDelta("Sunny."),
    ]
    user = json.loads(seen[0].content)["messages"][1]
    assert user["role"] == "user"
    assert user["content"][0] == {"type": "text", "text": "what is this?"}
    url = user["content"][1]["image_url"]["url"]
    assert user["content"][1]["type"] == "image_url"
    assert url.startswith("data:image/jpeg;base64,") and base64.b64decode(url.split(",", 1)[1]) == b"\xff\xd8jpeg"
    [_ async for _ in client.turn("sys", "plain")]
    assert json.loads(seen[1].content)["messages"][1] == {"role": "user", "content": "plain"}


# ---- conversation ----------------------------------------------------------


def conversation_with(hermes: FakeHermes, progress: list[Progress]) -> Conversation:
    async def approve(request):
        return "deny"

    conversation = Conversation(
        hermes, FakeTts(), lambda a: asyncio.sleep(0, ""), SpeechTrack(), approve, on_progress=progress.append
    )
    conversation.use_device_stt()
    return conversation


async def run_turn(conversation: Conversation, text: str) -> None:
    conversation.submit_text(text)
    player = asyncio.ensure_future(drain(conversation._out))
    try:
        await asyncio.wait_for(conversation._turn, 10)
    finally:
        player.cancel()


async def drain(out: SpeechTrack) -> None:
    while True:
        await out.recv()


async def test_conversation_reports_tool_progress_for_the_turn() -> None:
    hermes, progress = FakeHermes(), []
    hermes.tools = [
        ToolProgress("web_search", "running", "c1", "weather munich"),
        ToolProgress("terminal", "running", "c2", ""),
        ToolProgress("web_search", "completed", "c1", ""),
        ToolProgress("bad name!", "running", "c3", ""),
    ]
    conversation = conversation_with(hermes, progress)
    await run_turn(conversation, "check the weather")
    turn_ids = {p.turn_id for p in progress}
    assert len(turn_ids) == 1 and next(iter(turn_ids)).startswith("call-")
    assert [(p.tool, p.index, p.state, p.preview) for p in progress] == [
        ("web_search", 0, "started", "weather munich"),
        ("terminal", 1, "started", None),
        ("web_search", 0, "finished", None),
        ("", 0, "done", None),
    ]
    hermes.tools = []
    await run_turn(conversation, "thanks")
    assert len(progress) == 4  # a turn without tools reports nothing


async def test_images_wait_for_the_next_turn() -> None:
    hermes, progress = FakeHermes(), []
    conversation = conversation_with(hermes, progress)
    for image in (b"1", b"2", b"3", b"4"):
        conversation.add_image(image)
    await run_turn(conversation, "what is this?")
    await run_turn(conversation, "and now?")
    assert hermes.images == [[b"2", b"3", b"4"], []]


async def test_bridge_wires_call_progress_to_tasks(h) -> None:  # noqa: F811
    conversation = h.bridge.calls._make_conversation(SpeechTrack(), None, None, lambda role, text: None)
    assert conversation._on_progress == h.bridge.tasks.submit


# ---- "look at this" --------------------------------------------------------


class FakePc:
    async def close(self) -> None:
        pass


class ImageSink:
    def __init__(self) -> None:
        self.images: list[bytes] = []

    def add_image(self, data: bytes) -> None:
        self.images.append(data)


async def in_call(h):  # noqa: F811
    device = await online_device(h)
    device_id = device.state["device_id"]
    call = ActiveCall(wire.b64e(sodium.random_bytes(16)), h.bridge.calls._state.devices[device_id], FakePc())
    call.conversation = ImageSink()
    h.bridge.calls.active = call
    return device, call


async def send_image(device, call_id: str, data: bytes, mime: str = "image/jpeg") -> dict:
    blob_id, key = await device.upload(data)
    await device.send({"type": "call_image", "call_id": call_id, "blob_id": blob_id, "key": key, "mime": mime})
    ack = await next_of(device, "call_image_ack")
    assert ack["blob_id"] == blob_id and ack["call_id"] == call_id
    return ack


async def test_call_image_is_attached_to_the_conversation(h) -> None:  # noqa: F811
    device, call = await in_call(h)
    ack = await send_image(device, call.call_id, jpeg())
    assert ack["ok"] is True
    (attached,) = call.conversation.images
    with Image.open(io.BytesIO(attached)) as image:
        assert image.format == "JPEG" and max(image.size) == 1280 and not image.getexif()
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()


async def test_call_image_rate_limits(h) -> None:  # noqa: F811
    device, call = await in_call(h)
    small = jpeg(64, 64)
    assert (await send_image(device, call.call_id, small))["ok"] is True
    assert (await send_image(device, call.call_id, small))["ok"] is False  # within a second
    call.images = 30
    call.last_image = 0.0
    assert (await send_image(device, call.call_id, small))["ok"] is False  # 30 per call
    assert len(call.conversation.images) == 1
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()


@pytest.mark.parametrize(("data", "mime"), [(b"not an image", "image/jpeg"), (jpeg(64, 64), "image/gif")])
async def test_bad_call_images_are_rejected(h, data, mime) -> None:  # noqa: F811
    device, call = await in_call(h)
    assert (await send_image(device, call.call_id, data, mime))["ok"] is False
    assert call.conversation.images == []


async def test_call_image_only_from_the_device_in_the_call(h) -> None:  # noqa: F811
    _, call = await in_call(h)
    other = await online_device(h, "Other phone")
    assert (await send_image(other, call.call_id, jpeg(64, 64)))["ok"] is False
    assert call.conversation.images == []
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()


async def test_png_is_reencoded_as_jpeg(h) -> None:  # noqa: F811
    device, call = await in_call(h)
    assert (await send_image(device, call.call_id, jpeg(300, 200, "PNG"), "image/png"))["ok"] is True
    assert call.conversation.images[0][:2] == b"\xff\xd8"


async def test_malformed_call_image_still_frees_the_blob(h) -> None:  # noqa: F811
    device, _ = await in_call(h)
    blob_id, key = await device.upload(jpeg(64, 64))
    await device.send({"type": "call_image", "call_id": "nope", "blob_id": blob_id, "key": key, "mime": "image/jpeg"})
    ack = await next_of(device, "call_image_ack")
    assert ack == {**ack, "call_id": "", "blob_id": blob_id, "ok": False}
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()


async def test_call_image_messages_are_limited_per_device(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(calls_mod, "CALL_IMAGE_MESSAGES", (60.0, 2))
    device = await online_device(h)  # not in a call: every image is rejected
    call_id = wire.b64e(sodium.random_bytes(16))
    for _ in range(2):
        assert (await send_image(device, call_id, jpeg(32, 32)))["ok"] is False
    blob_id, key = await device.upload(jpeg(32, 32))
    await device.send({"type": "call_image", "call_id": call_id, "blob_id": blob_id, "key": key, "mime": "image/jpeg"})
    with pytest.raises(TimeoutError):
        await next_of(device, "call_image_ack", timeout=0.5)  # ignored: no ack, no relay request


async def test_images_stay_pending_when_hermes_fails() -> None:
    class DownHermes(FakeHermes):
        async def turn(self, system: str, text: str, images=()):
            self.images.append(list(images))
            raise OSError("hermes down")
            yield  # pragma: no cover

    hermes, progress = DownHermes(), []
    conversation = conversation_with(hermes, progress)
    conversation.add_image(b"1")
    await run_turn(conversation, "what is this?")  # the owner hears the fallback line (A3)
    assert list(conversation._images) == [b"1"]
