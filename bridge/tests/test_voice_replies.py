"""M9 §9: the agent answers an owner's voice note with a voice note (bridge TTS → AAC in .m4a)."""

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

from hermescall_bridge import chat as chat_mod
from hermescall_bridge import voice
from hermescall_bridge.chat import decode_audio
from hermescall_bridge.voice import encode_voice, speech_text
from hermescall_common import sodium, wire

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import hermes_api, next_of, online_device, poll, stop_devices  # noqa: F401 - fixtures

WAV = Path(__file__).parent / "data" / "question.wav"


async def send_voice_note(device, voice_replies: bool | None = True, text: str = "") -> str:
    blob_id, key = await device.upload(WAV.read_bytes())
    message_id = wire.b64e(sodium.random_bytes(16))
    body = {
        "type": "chat",
        "id": message_id,
        "text": text,
        "attachments": [{"kind": "voice", "blob_id": blob_id, "key": key, "name": "voice.m4a", "mime": "audio/mp4"}],
    }
    if voice_replies is not None:
        body["voice_replies"] = voice_replies
    await device.send(body, mail=True)
    await poll(device.h)
    return message_id


async def reply(h, text: str = "It is sunny.", answers: str | None = None) -> None:  # noqa: F811
    body = {"text": text} if answers is None else {"text": text, "answers": answers}
    status, _ = await hermes_api(h, "POST", "/v1/chat/messages", body)
    assert status == 200


async def agent_message(device) -> dict:
    while (message := await next_of(device, "chat"))["role"] != "agent":
        pass
    return message


async def voice_device(h):  # noqa: F811
    device = await online_device(h)
    device.h = h
    return device


async def test_voice_note_with_voice_replies_gets_a_spoken_answer(h) -> None:  # noqa: F811
    device = await voice_device(h)
    note = await send_voice_note(device)
    await reply(h, "On it.")  # an interim or unrelated message is not the answer
    assert "attachments" not in await agent_message(device)
    await reply(h, "**Sunny**, 24 degrees. See https://example.com/weather", answers=note)
    message = await agent_message(device)
    assert message["text"] == "**Sunny**, 24 degrees. See https://example.com/weather"
    (ref,) = message["attachments"]
    assert ref["kind"] == "voice" and ref["name"] == "reply.m4a" and ref["mime"] == "audio/mp4"
    audio = decode_audio(await device.fetch_attachment(ref))
    assert len(audio) > 1000 and abs(audio).max() > 0.05
    assert h.tts.spoken == ["Sunny, 24 degrees. See"]
    # Only the first reply to the voice note is spoken.
    await reply(h, "Anything else?", answers=note)
    assert "attachments" not in await agent_message(device)


async def test_no_flag_or_text_message_means_plain_text(h) -> None:  # noqa: F811
    device = await voice_device(h)
    note = await send_voice_note(device, voice_replies=None)
    await reply(h, answers=note)
    assert "attachments" not in await agent_message(device)
    note = await send_voice_note(device, voice_replies=True)
    await device.send_chat("never mind, just text")
    await poll(h)
    await reply(h, answers=note)
    assert "attachments" not in await agent_message(device)
    assert h.tts.spoken == []


async def test_voice_reply_request_expires(h, monkeypatch) -> None:  # noqa: F811
    device = await voice_device(h)
    await send_voice_note(device)
    monkeypatch.setattr(chat_mod, "VOICE_REPLY_TTL", 0.0)
    note = await send_voice_note(device)
    await asyncio.sleep(0.01)
    await reply(h, answers=note)
    assert "attachments" not in await agent_message(device)


async def test_tts_failure_falls_back_to_text(h) -> None:  # noqa: F811
    class BrokenTts:
        async def synthesize(self, text: str) -> AsyncIterator[bytes]:
            raise OSError("kokoro down")
            yield b""

    device = await voice_device(h)
    h.bridge.chat._tts = BrokenTts()
    note = await send_voice_note(device)
    await reply(h, "Plain it is.", answers=note)
    message = await agent_message(device)
    assert message["text"] == "Plain it is." and "attachments" not in message


async def test_upload_failure_falls_back_to_text(h, monkeypatch) -> None:  # noqa: F811
    async def no_upload(*args, **kwargs):
        raise TimeoutError

    device = await voice_device(h)
    note = await send_voice_note(device)
    monkeypatch.setattr(chat_mod.blobs, "upload", no_upload)
    await reply(h, "Still here.", answers=note)
    message = await agent_message(device)
    assert message["text"] == "Still here." and "attachments" not in message


async def test_slow_tts_falls_back_to_text(h, monkeypatch) -> None:  # noqa: F811
    class SlowTts:
        async def synthesize(self, text: str) -> AsyncIterator[bytes]:
            await asyncio.sleep(5)
            yield b"\0\0"

    monkeypatch.setattr(chat_mod, "SPEAK_TIMEOUT", 0.2)
    device = await voice_device(h)
    h.bridge.chat._tts = SlowTts()
    note = await send_voice_note(device)
    await reply(h, "Quick answer.", answers=note)
    message = await agent_message(device)
    assert message["text"] == "Quick answer." and "attachments" not in message


async def test_voice_reply_too_big_for_the_mailbox_goes_as_text(h) -> None:  # noqa: F811
    device = await voice_device(h)
    h.bridge.chat._fits = lambda device, body: "attachments" not in body
    note = await send_voice_note(device)
    await reply(h, "Long answer.", answers=note)
    message = await agent_message(device)
    assert message["text"] == "Long answer." and "attachments" not in message
    await asyncio.sleep(0.2)
    assert h.relay.store.blob_ids() == set()  # the uploaded voice note was removed again


def test_speech_text_handles_long_underscore_runs_fast() -> None:
    import time

    started = time.monotonic()
    assert speech_text("_" * 50_000 + "a" + "_" * 50_000 + " snake_case") == "a snake_case"
    assert time.monotonic() - started < 1.0


def test_speech_text_strips_markdown_and_caps_length() -> None:
    text = "# Title\n\n- **one** item\n- `two` [link](https://x.y)\n\n```\ncode\n```\nDone 🎉."
    assert speech_text(text) == "Title\n\none item\ntwo link\n\nDone."
    long = "\n\n".join(f"Paragraph {i}. " + "word " * 60 for i in range(20))
    spoken = speech_text(long)
    assert len(spoken) <= voice.MAX_SPOKEN_CHARS + 30 and spoken.endswith("More in the chat.")
    assert spoken.startswith("Paragraph 0.") and "Paragraph 19" not in spoken
    one_block = "Sentence number one. " * 200
    capped = speech_text(one_block)
    assert capped.endswith("Sentence number one. More in the chat.") and len(capped) <= voice.MAX_SPOKEN_CHARS + 30
    assert speech_text("```\nonly code\n```") == ""


def test_encode_voice_roundtrip() -> None:
    import numpy as np

    t = np.arange(24_000) / 24_000
    pcm = (np.sin(2 * np.pi * 300 * t) * 8000).astype(np.int16).tobytes()
    data = encode_voice(pcm)
    assert data[4:8] == b"ftyp"
    audio = decode_audio(data)
    assert abs(len(audio) - 16_000) < 2000 and abs(audio).max() > 0.1
