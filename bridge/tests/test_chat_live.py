"""Live reply drafts (Hermes streaming) and voice replies whose audio follows the text."""

import asyncio

from hermescall_bridge import chat as chat_mod

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_voice_replies import agent_message, reply, send_voice_note, voice_device


async def say_hello(device, *caps: str) -> None:
    await device.send({"type": "hello", "v": 1, "app": "test", "caps": list(caps)})
    await next_of(device, "hello")


async def test_drafts_reach_only_phones_that_show_them_and_are_coalesced(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(chat_mod, "DRAFT_INTERVAL", 0.2)
    showing, older = await online_device(h, "new"), await online_device(h, "old")
    await say_hello(showing, "chat_draft")
    for text in ("Sure", "Sure, the", "Sure, the weather"):
        status, _ = await hermes_api(h, "POST", "/v1/chat/draft", {"draft_id": "7", "text": text})
        assert status == 200
    first = await next_of(showing, "chat_draft")
    latest = await next_of(showing, "chat_draft")
    assert first == {**first, "draft": "7", "text": "Sure"}
    assert latest["text"] == "Sure, the weather"  # the middle frame was folded into the newest
    await asyncio.sleep(0.3)
    while not older.inbox.empty():
        assert older.inbox.get_nowait()["type"] != "chat_draft"


async def test_the_final_reply_stops_pending_drafts(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setattr(chat_mod, "DRAFT_INTERVAL", 0.2)
    device = await online_device(h)
    await say_hello(device, "chat_draft")
    await hermes_api(h, "POST", "/v1/chat/draft", {"draft_id": "1", "text": "Partial"})
    await hermes_api(h, "POST", "/v1/chat/draft", {"draft_id": "1", "text": "Partial answ"})
    await reply(h, "Partial answer, done.")
    assert (await next_of(device, "chat_draft"))["text"] == "Partial"
    assert (await agent_message(device))["text"] == "Partial answer, done."
    await asyncio.sleep(0.3)
    while not device.inbox.empty():
        assert device.inbox.get_nowait()["type"] != "chat_draft"


async def test_a_bad_draft_is_refused(h) -> None:  # noqa: F811
    status, _ = await hermes_api(h, "POST", "/v1/chat/draft", {"text": "no id"})
    assert status == 400


async def test_voice_reply_text_arrives_first_and_its_audio_follows(h) -> None:  # noqa: F811
    device = await voice_device(h)
    await say_hello(device, "voice_follow")
    note = await send_voice_note(device)
    await reply(h, "Sunny, 24 degrees.", answers=note)
    text = await agent_message(device)
    assert text["text"] == "Sunny, 24 degrees." and "attachments" not in text
    follow = await next_of(device, "chat_attach")
    (ref,) = follow["attachments"]
    assert follow["id"] == text["id"] and ref["kind"] == "voice" and ref["name"] == "reply.m4a"
    assert len(await device.fetch_attachment(ref)) > 1000


async def test_an_older_phone_still_gets_text_and_voice_together(h) -> None:  # noqa: F811
    device = await voice_device(h)
    note = await send_voice_note(device)
    await reply(h, "Sunny, 24 degrees.", answers=note)
    message = await agent_message(device)
    assert message["text"] == "Sunny, 24 degrees." and message["attachments"][0]["kind"] == "voice"
