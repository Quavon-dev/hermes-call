import asyncio
import json
import os
import stat
import time
import wave
from pathlib import Path

import httpx
import numpy as np
import pytest

from hermescall_bridge import config as config_mod
from hermescall_bridge.audio import SpeechTrack
from hermescall_bridge.conversation import APPROVAL_DENIED, APPROVAL_PROMPT, Conversation
from hermescall_bridge.hermes import ApprovalRequest, HermesClient, TextDelta
from hermescall_bridge.state import StateStore, new_device
from hermescall_bridge.text import Chunker, speakable
from hermescall_bridge.vad import StreamingVad
from hermescall_common import sodium, wire
from hermescall_common.e2e import Channel
from hermescall_common.errors import ProtocolError

from .conftest import FakeHermes, FakeTts

DATA = Path(__file__).parent / "data"


def speech_16k() -> np.ndarray:
    with wave.open(str(DATA / "question.wav")) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


# ---- text ----------------------------------------------------------------


def test_first_chunk_ends_at_clause_then_sentences() -> None:
    chunker = Chunker()
    out = []
    for delta in ["Good evening, sir", ", the backup ", "finished. Everything ", "looks fine. Want ", "details?"]:
        out += chunker.feed(delta)
    out += chunker.flush()
    assert out == ["Good evening,", "sir, the backup finished.", "Everything looks fine.", "Want details?"]


def test_first_chunk_is_forced_after_eight_words() -> None:
    chunks = Chunker().feed("one two three four five six seven eight nine ten")
    assert chunks == ["one two three four five six seven eight"]


def test_short_first_sentence_is_not_delayed() -> None:
    assert Chunker().feed("Sure. Let me check.") == ["Sure."]


def test_speakable_strips_markdown_and_urls() -> None:
    assert (
        speakable("**Done**: see [the docs](https://x.y) or https://a.b/c\n- item `x`") == "Done: see the docs or a link item x"
    )


def test_overlong_text_is_split() -> None:
    chunks = Chunker().feed("word " * 100)
    assert chunks and all(len(c) <= 220 for c in chunks)


# ---- hermes client ---------------------------------------------------------


def sse(*events: tuple[str, dict | str]) -> bytes:
    lines = []
    for event, data in events:
        if event:
            lines.append(f"event: {event}")
        lines.append(f"data: {data if isinstance(data, str) else json.dumps(data)}")
        lines.append("")
    return ("\n".join(lines) + "\n").encode()


async def test_hermes_stream_parsing_and_session_header() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.url.path.endswith("/approval"):
            return httpx.Response(200, json={})
        body = sse(
            ("", {"id": "chatcmpl-1", "choices": [{"delta": {"content": "Hel"}}]}),
            ("hermes.tool.progress", {"tool": "x"}),
            ("approval.request", {"run_id": "chatcmpl-1", "request_id": "r1", "command": "ls", "description": "list"}),
            ("", {"id": "chatcmpl-1", "choices": [{"delta": {"content": "lo"}}]}),
            ("", "[DONE]"),
        )
        return httpx.Response(200, content=body, headers={"content-type": "text/event-stream"})

    client = HermesClient("http://127.0.0.1:8642", "key", "phone-session")
    client._client = httpx.AsyncClient(
        base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(handler), headers=client._client.headers
    )
    events = [e async for e in client.turn("sys", "hi")]
    assert events == [TextDelta("Hel"), ApprovalRequest("chatcmpl-1", "r1", "ls", "list"), TextDelta("lo")]
    request = seen[0]
    assert request.headers["X-Hermes-Session-Id"] == "phone-session"
    assert request.headers["Authorization"] == "Bearer key"
    assert json.loads(request.content)["messages"][0] == {"role": "system", "content": "sys"}
    await client.answer_approval(events[1], "deny")
    assert json.loads(seen[1].content) == {"choice": "deny", "request_id": "r1"}
    assert seen[1].url.path == "/v1/runs/chatcmpl-1/approval"
    with pytest.raises(ValueError):
        await client.answer_approval(events[1], "always")


# ---- e2e channel -----------------------------------------------------------


def channels() -> tuple[Channel, bytes, Channel, bytes]:
    a_pk, a_sk = sodium.box_keypair()
    b_pk, b_sk = sodium.box_keypair()
    return Channel("A", a_sk), a_pk, Channel("B", b_sk), b_pk


def test_e2e_roundtrip_and_replay() -> None:
    a, a_pk, b, b_pk = channels()
    sealed = a.seal("B", b_pk, {"type": "offer", "sdp": "x"})
    assert b.open("A", a_pk, sealed)["sdp"] == "x"
    with pytest.raises(ProtocolError):
        b.open("A", a_pk, sealed)
    second = a.seal("B", b_pk, {"type": "hangup"})
    assert b.open("A", a_pk, second)["type"] == "hangup"


def test_e2e_rejects_wrong_sender_recipient_and_stale() -> None:
    a, a_pk, b, b_pk = channels()
    m_pk, m_sk = sodium.box_keypair()
    with pytest.raises(ProtocolError):
        b.open("A", m_pk, a.seal("B", b_pk, {"type": "x"}))
    with pytest.raises(ProtocolError):
        b.open("A", a_pk, a.seal("C", b_pk, {"type": "x"}))
    with pytest.raises(ProtocolError):
        b.open("M", a_pk, a.seal("B", b_pk, {"type": "x"}))
    a._last_sent = int(time.time() * 1000) - 10 * 60 * 1000
    stale = sodium.box_seal(json.dumps({"type": "x", "from": "A", "to": "B", "ts": a._last_sent}).encode(), b_pk, a._sk)
    with pytest.raises(ProtocolError):
        b.open("A", a_pk, wire.b64e(stale))
    with pytest.raises(ProtocolError):
        a.seal("B", b_pk, {"no": "type"})


# ---- state + config --------------------------------------------------------


def test_state_is_private_and_persistent(tmp_path: Path) -> None:
    store = StateStore(tmp_path / "s")
    state = store.load()
    state.devices["d1"] = new_device("d1", "Phone\x00\n", wire.b64e(b"x" * 32), wire.b64e(b"y" * 32))
    store.save(state)
    assert stat.S_IMODE(os.stat(store.path).st_mode) == 0o600
    reloaded = store.load()
    assert reloaded.keys == state.keys and reloaded.devices["d1"].name == "Phone"
    with pytest.raises(ProtocolError):
        new_device("d2", "x", "short", wire.b64e(b"y" * 32))


def test_config_requires_loopback(tmp_path: Path) -> None:
    path = tmp_path / "bridge.toml"
    path.write_text('[hermes]\nurl = "http://192.168.1.20:8642"\n')
    with pytest.raises(config_mod.ConfigError):
        config_mod.load(path)
    path.write_text('[api]\nhost = "0.0.0.0"\n')
    with pytest.raises(config_mod.ConfigError):
        config_mod.load(path)
    for url in ("http://127.0.0.1:80@evil.example", "http://127.0.0.1", "https://127.0.0.1:8642", "http://127.0.0.1:8642/x"):
        path.write_text(f'[hermes]\nurl = "{url}"\n')
        with pytest.raises(config_mod.ConfigError):
            config_mod.load(path)
    path.write_text("")
    assert config_mod.load(path).tts_voice == "bm_george"


@pytest.mark.parametrize(("name", "ok"), [("Nova", True), ("O'Neil-2", True), ("", False), ('a"b', False), ("x" * 33, False)])
def test_config_agent_name(tmp_path: Path, name: str, ok: bool) -> None:
    path = tmp_path / "bridge.toml"
    path.write_text(f"agent_name = {json.dumps(name)}\n")
    if ok:
        assert config_mod.load(path).agent_name == name
    else:
        with pytest.raises(config_mod.ConfigError):
            config_mod.load(path)
    path.write_text("")
    assert config_mod.load(path).agent_name == "Hermes"


# ---- VAD + conversation ----------------------------------------------------


def test_vad_detects_speech_not_silence() -> None:
    vad = StreamingVad()
    silence = [vad.probability(np.zeros(512, dtype=np.float32)) for _ in range(20)]
    audio = speech_16k()
    speech = [vad.probability(audio[i : i + 512]) for i in range(0, len(audio) - 512, 512)]
    assert max(silence) < 0.2 and max(speech) > 0.8


def drain(out: SpeechTrack) -> asyncio.Task:
    async def pull() -> None:
        while True:
            await out.recv()

    return asyncio.ensure_future(pull())


async def feed(conversation: Conversation, blocks: list[np.ndarray]) -> None:
    async def source():
        for block in blocks:
            yield block
            await asyncio.sleep(0)

    await conversation.run(source())


def blocks_of(audio: np.ndarray, size: int = 320) -> list[np.ndarray]:
    return [audio[i : i + size] for i in range(0, len(audio), size)]


async def test_utterance_triggers_one_turn_and_is_spoken() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    heard: list[int] = []

    async def transcribe(audio: np.ndarray) -> str:
        heard.append(len(audio))
        return "what is on my calendar"

    conversation = Conversation(hermes, tts, transcribe, out, lambda r: asyncio.sleep(0, "deny"), "note")
    silence = np.zeros(16000, dtype=np.float32)
    source_blocks = blocks_of(np.concatenate([silence, speech_16k(), silence]))

    async def source():
        for block in source_blocks:
            yield block
            await asyncio.sleep(0)
        while conversation.busy:
            await asyncio.sleep(0.01)

    player = drain(out)
    await asyncio.wait_for(conversation.run(source()), 10)
    player.cancel()
    assert len(heard) == 1 and heard[0] >= 16000 * 2
    assert hermes.turns[0][1] == "what is on my calendar" and "note" in hermes.turns[0][0]
    assert tts.spoken == ["Sure, I heard you.", "Anything else?"]


def test_one_word_clause_is_not_cut() -> None:
    assert Chunker().feed("Sure, ") == []


async def test_barge_in_cancels_speech_and_marks_interruption() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    conversation = Conversation(
        hermes, tts, lambda a: asyncio.sleep(0, "second question"), out, lambda r: asyncio.sleep(0, "deny")
    )
    out.enqueue_pcm(b"\1\0" * 48000 * 5, 48000)
    assert conversation.busy
    silence = np.zeros(8000, dtype=np.float32)
    await asyncio.wait_for(feed(conversation, blocks_of(np.concatenate([speech_16k(), silence]))), 10)
    assert hermes.turns and hermes.turns[0][1].startswith("(I interrupted you.)")


async def test_noise_shorter_than_barge_in_does_not_interrupt() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    conversation = Conversation(hermes, tts, lambda a: asyncio.sleep(0, "x"), out, lambda r: asyncio.sleep(0, "deny"))
    out.enqueue_pcm(b"\1\0" * 48000 * 5, 48000)
    blip = speech_16k()[8000:10400]
    await asyncio.wait_for(feed(conversation, blocks_of(np.concatenate([blip, np.zeros(16000, dtype=np.float32)]))), 10)
    assert hermes.turns == [] and out.speaking


async def test_push_to_talk_and_phone_approval() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    hermes.ask_approval = True
    asked: list[ApprovalRequest] = []

    async def approve(request: ApprovalRequest) -> str:
        asked.append(request)
        return "deny"

    conversation = Conversation(hermes, tts, lambda a: asyncio.sleep(0, "delete it"), out, approve)
    conversation.set_ptt(True)
    conversation._on_chunk(np.zeros(512, dtype=np.float32))
    conversation.set_ptt(False)
    player = drain(out)
    await asyncio.wait_for(conversation._turn, 10)
    player.cancel()
    assert asked[0].command == "rm -rf /tmp/x" and hermes.approvals == ["deny"]
    assert tts.spoken[:2] == [APPROVAL_PROMPT, APPROVAL_DENIED]


async def test_device_stt_uses_phone_text_and_audio_only_for_barge_in() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    transcribed: list[int] = []

    async def transcribe(audio: np.ndarray) -> str:
        transcribed.append(len(audio))
        return "whisper text"

    conversation = Conversation(hermes, tts, transcribe, out, lambda r: asyncio.sleep(0, "deny"))
    conversation.submit_text("ignored before device mode")
    assert conversation._turn is None
    conversation.use_device_stt()
    silence = np.zeros(8000, dtype=np.float32)
    await asyncio.wait_for(feed(conversation, blocks_of(np.concatenate([speech_16k(), silence]))), 10)
    assert transcribed == [] and hermes.turns == []
    conversation.submit_text("what is on my calendar", stt_ms=120)
    player = drain(out)
    await asyncio.wait_for(conversation._turn, 10)
    player.cancel()
    assert hermes.turns[0][1] == "what is on my calendar"


# ---- captions and tap-to-interrupt ----------------------------------------


async def test_captions_follow_owner_then_agent_sentences() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    captions: list[tuple[str, str]] = []
    conversation = Conversation(
        hermes,
        tts,
        lambda a: asyncio.sleep(0, "what is on my calendar"),
        out,
        lambda r: asyncio.sleep(0, "deny"),
        on_caption=lambda role, text: captions.append((role, text)),
    )
    conversation.set_ptt(True)
    conversation._on_chunk(np.zeros(512, dtype=np.float32))
    conversation.set_ptt(False)
    player = drain(out)
    await asyncio.wait_for(conversation._turn, 10)
    player.cancel()
    assert captions == [("owner", "what is on my calendar"), ("agent", "Sure, I heard you."), ("agent", "Anything else?")]
    assert tts.spoken == ["Sure, I heard you.", "Anything else?"]


async def test_agent_caption_waits_for_audio_queued_ahead_and_interrupt_drops_it() -> None:
    captions: list[tuple[str, str]] = []
    out = SpeechTrack()
    conversation = Conversation(
        FakeHermes(),
        FakeTts(),
        lambda a: asyncio.sleep(0, "x"),
        out,
        lambda r: asyncio.sleep(0, "deny"),
        on_caption=lambda role, text: captions.append((role, text)),
    )
    out.enqueue_pcm(b"\1\0" * 48000 * 5, 48000)
    conversation._caption_when_heard("later sentence")
    await asyncio.sleep(0.05)
    assert captions == []
    conversation.interrupt()
    assert not out.speaking and not conversation._pending_captions
    await asyncio.sleep(0.05)
    assert captions == []


async def test_device_stt_gets_no_owner_caption_and_failing_caption_is_harmless() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    roles: list[str] = []

    def on_caption(role: str, text: str) -> None:
        roles.append(role)
        raise RuntimeError("relay down")

    conversation = Conversation(
        hermes, tts, lambda a: asyncio.sleep(0, "x"), out, lambda r: asyncio.sleep(0, "deny"), on_caption=on_caption
    )
    conversation.use_device_stt()
    conversation.submit_text("hello from the phone")
    player = drain(out)
    await asyncio.wait_for(conversation._turn, 10)
    player.cancel()
    assert roles == ["agent", "agent"] and tts.spoken == ["Sure, I heard you.", "Anything else?"]


async def test_interrupt_stops_speech_and_is_idempotent() -> None:
    hermes, tts, out = FakeHermes(), FakeTts(), SpeechTrack()
    conversation = Conversation(
        hermes, tts, lambda a: asyncio.sleep(0, "tell me a story"), out, lambda r: asyncio.sleep(0, "deny")
    )
    conversation.interrupt()
    assert conversation._interrupted is False and not conversation.busy
    conversation.set_ptt(True)
    conversation._on_chunk(np.zeros(512, dtype=np.float32))
    conversation.set_ptt(False)
    turn = conversation._turn
    for _ in range(500):
        if out.speaking:
            break
        await asyncio.sleep(0.01)
    assert out.speaking
    conversation.interrupt()
    conversation.interrupt()
    with pytest.raises(asyncio.CancelledError):
        await turn
    await asyncio.sleep(0.05)
    assert not out.speaking and not conversation.busy
    conversation.submit_text("ignored: not device stt")
    conversation.set_ptt(True)
    conversation._on_chunk(np.zeros(512, dtype=np.float32))
    conversation.set_ptt(False)
    player = drain(out)
    await asyncio.wait_for(conversation._turn, 10)
    player.cancel()
    assert hermes.turns[-1][1] == "(I interrupted you.) tell me a story"


class RecordingChannel:
    def seal(self, device_id: str, box_key: bytes, body: dict) -> dict:
        return body


class RecordingRelay:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.fail = False

    async def send(self, message: dict) -> None:
        if self.fail:
            raise RuntimeError("socket closed")
        self.sent.append(message["data"])


async def test_call_manager_captions_are_trimmed_filtered_and_best_effort() -> None:
    from hermescall_bridge.calls import MAX_CAPTION, ActiveCall, CallManager
    from hermescall_bridge.state import State

    device = new_device("dev1", "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    relay = RecordingRelay()
    manager = CallManager(State(keys={}, devices={"dev1": device}), relay, RecordingChannel(), conversation_factory=None)
    call = ActiveCall("call1", device, pc=None)
    manager.active = call

    async def settle() -> None:
        while call.captions:
            await asyncio.sleep(0)

    manager._caption(call, "agent", "  " + "a" * (MAX_CAPTION + 100) + "  ")
    manager._caption(call, "owner", " hi there ")
    manager._caption(call, "system", "nope")
    manager._caption(call, "agent", "   ")
    await settle()
    assert [(m["type"], m["call_id"], m["role"], len(m["text"])) for m in relay.sent] == [
        ("caption", "call1", "agent", MAX_CAPTION),
        ("caption", "call1", "owner", len("hi there")),
    ]
    call.device_stt = True
    manager._caption(call, "owner", "echo")
    manager._caption(ActiveCall("other", device, pc=None), "agent", "stale call")
    relay.fail = True
    manager._caption(call, "agent", "lost")
    await settle()
    assert len(relay.sent) == 2


def test_answer_sdp_requests_constant_bitrate_opus() -> None:
    from hermescall_bridge.calls import prefer_constant_bitrate

    sdp = "v=0\r\na=rtpmap:96 opus/48000/2\r\na=fmtp:96 minptime=10;useinbandfec=1\r\na=rtpmap:0 PCMU/8000\r\na=fmtp:0 x=1\r\n"
    out = prefer_constant_bitrate(sdp)
    assert "a=fmtp:96 minptime=10;useinbandfec=1;cbr=1" in out
    assert "a=fmtp:0 x=1\r\n" in out and prefer_constant_bitrate(out) == out
