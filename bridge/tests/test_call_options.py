"""C4 TURN URL order, C5 call timeouts/resends, E5 per-phone sessions, E7 approval answers, J1–J3 health/metrics."""

import asyncio
import json

import httpx
import pytest
from aiohttp import ClientSession

from hermescall_bridge import calls as calls_mod
from hermescall_bridge.calls import ActiveCall, CallTimeouts
from hermescall_bridge.config import ConfigError, load
from hermescall_bridge.hermes import ApprovalRequest, HermesClient
from hermescall_bridge.metrics import METRICS
from hermescall_bridge.sessions import PhoneSessions
from hermescall_bridge.webrtc import order_turn_urls

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_regressions import FakePc, SlowTurnRelay, call_manager, until

# ---- C4 --------------------------------------------------------------------------

URLS = [
    "turns:relay.example:5349?transport=tcp",
    "turn:relay.example:3478?transport=tcp",
    "turn:relay.example:3478?transport=udp",
    "stun:relay.example:3478",
]


@pytest.mark.parametrize(
    ("preference", "first"),
    [("auto", "transport=udp"), ("udp", "transport=udp"), ("tcp", "turn:relay.example:3478?transport=tcp"), ("tls", "turns:")],
)
def test_turn_urls_keep_all_turn_entries_in_preference_order(preference, first) -> None:
    ordered = order_turn_urls(URLS, preference)
    assert len(ordered) == 3 and "stun:relay.example:3478" not in ordered
    assert first in ordered[0]


def test_tls_only_relay_still_gets_a_turn_server() -> None:
    assert order_turn_urls(["turns:relay.example:443?transport=tcp"]) == ["turns:relay.example:443?transport=tcp"]


# ---- C5 --------------------------------------------------------------------------


def test_call_timeouts_from_config(tmp_path) -> None:
    path = tmp_path / "bridge.toml"
    path.write_text(
        "[calls]\nring_timeout = 30\nmax_call_seconds = 1800\n"
        "[voice]\nend_silence_ms = 700\nacknowledgement_after_ms = 900\nacknowledgement_text = 'One moment.'\n"
        "[tts]\nspeed = 1.08\n"
        "[hermes]\nmodel = 'voice-fast'\nprovider = 'openrouter'\nreasoning_effort = 'none'\n"
        "[log]\nformat = 'json'\n"
    )
    config = load(path)
    assert (config.ring_timeout, config.max_call_seconds, config.approval_timeout) == (30.0, 1800.0, 60.0)
    assert config.end_silence_ms == 700 and config.log_format == "json" and config.turn_transport == "auto"
    assert config.acknowledgement_after_ms == 900 and config.acknowledgement_text == "One moment."
    assert config.tts_speed == 1.08
    assert (config.hermes_model, config.hermes_provider, config.hermes_reasoning_effort) == (
        "voice-fast",
        "openrouter",
        "none",
    )
    for bad in (
        "[calls]\nring_timeout = 1\n",
        "[voice]\nend_silence_ms = 'x'\n",
        "[voice]\nacknowledgement_after_ms = 6000\n",
        "[tts]\nspeed = 3\n",
        "[hermes]\nreasoning_effort = 'extreme'\n",
        "[turn]\ntransport = 'sctp'\n",
    ):
        path.write_text(bad)
        with pytest.raises(ConfigError):
            load(path)


async def test_call_without_media_ends_after_the_media_timeout(monkeypatch) -> None:
    monkeypatch.setattr(calls_mod, "peer_connection", lambda turn, *_: FakePc())
    relay = SlowTurnRelay()
    relay.release.set()
    manager, device = call_manager(relay)
    manager._timeouts = CallTimeouts(media=0.1)
    await manager.on_e2e(device.id, {"type": "offer", "call_id": calls_mod.new_call_id(), "sdp": "v=0\r\n"})
    assert manager.active is not None
    await until(lambda: manager.active is None, 3)
    assert relay.sent[-1]["data"]["type"] == "hangup"


class Announcer:
    def __init__(self) -> None:
        self.said: list[str] = []

    def announce(self, text: str) -> None:
        self.said.append(text)


def test_warning_before_the_call_time_limit() -> None:
    manager, device = call_manager(SlowTurnRelay())
    call = ActiveCall("c", device, pc=None)
    call.conversation = Announcer()
    manager.active = call
    manager._warn_ending(call)
    manager._warn_ending(ActiveCall("other", device, pc=None))  # not the active call: nothing
    assert call.conversation.said == [calls_mod.CALL_ENDING_LINE]


async def test_pending_approval_and_lost_captions_are_resent_after_a_relay_reconnect() -> None:
    relay = SlowTurnRelay()
    manager, device = call_manager(relay)
    call = ActiveCall("c1", device, pc=None)
    manager.active = call
    ask = asyncio.ensure_future(manager._ask_approval(call, ApprovalRequest("run", "req", "ls", "list")))
    await asyncio.sleep(0)
    relay.sent.clear()

    async def failing_send(message: dict) -> None:
        raise ConnectionError("relay gone")

    ok_send, relay.send = relay.send, failing_send
    await manager._send_caption(call, "agent", "you missed this")
    relay.send = ok_send
    await manager.on_relay_ready()
    kinds = [m["data"]["type"] for m in relay.sent]
    assert kinds == ["approval_request", "caption"]
    assert relay.sent[0]["data"]["choices"] == ["once", "session", "deny"]
    await manager._on_approval_answer(device, {"call_id": "c1", "request_id": "req", "choice": "session"})
    assert await ask == "session"
    relay.sent.clear()
    await manager.on_relay_ready()
    assert relay.sent == [], "an answered approval is not sent again"


# ---- E5 --------------------------------------------------------------------------


def test_phone_sessions_are_per_phone_daily_and_roll_over(tmp_path, monkeypatch) -> None:
    from hermescall_bridge import sessions as sessions_mod

    monkeypatch.setattr(sessions_mod, "_today", lambda: "20260930")
    sessions = PhoneSessions("hermes-call-phone", tmp_path / "sessions.json", max_turns=2)
    a, b = sessions.session_id("AAAAAAAAxyz"), sessions.session_id("BBBBBBBBxyz")
    assert a == "hermes-call-phone-AAAAAAAA-20260930" and a != b
    sessions.note_turn("AAAAAAAAxyz")
    sessions.note_turn("AAAAAAAAxyz")
    assert sessions.session_id("AAAAAAAAxyz") == "hermes-call-phone-AAAAAAAA-20260930-1"
    reloaded = PhoneSessions("hermes-call-phone", tmp_path / "sessions.json", max_turns=2)
    assert reloaded.session_id("AAAAAAAAxyz").endswith("-1")
    monkeypatch.setattr(sessions_mod, "_today", lambda: "20261001")
    assert reloaded.session_id("AAAAAAAAxyz") == "hermes-call-phone-AAAAAAAA-20261001"


async def test_conversation_uses_the_phone_session() -> None:
    from hermescall_bridge.audio import SpeechTrack
    from hermescall_bridge.conversation import Conversation

    from .conftest import FakeHermes, FakeTts
    from .test_units import drain

    hermes, turns = FakeHermes(), []
    out = SpeechTrack()
    conversation = Conversation(hermes, FakeTts(), None, out, None, session_id="s-1", on_turn=lambda: turns.append(1))
    player = drain(out)
    await conversation._run_turn(None, 0.0, "hi")
    player.cancel()
    assert hermes.sessions == ["s-1"] and turns == [1]


# ---- E7 --------------------------------------------------------------------------


def hermes_with(handler) -> HermesClient:
    client = HermesClient("http://127.0.0.1:8642", "key", "s")
    client._client = httpx.AsyncClient(base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(handler))
    return client


async def test_approval_answer_is_retried(monkeypatch) -> None:
    monkeypatch.setattr("hermescall_bridge.hermes.APPROVAL_RETRIES", (0.0, 0.0, 0.0))
    answers: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        answers.append(json.loads(request.content))
        return httpx.Response(503 if len(answers) < 3 else 200)

    client = hermes_with(handler)
    assert await client.answer_approval(ApprovalRequest("run", "r", "ls", ""), "session") == "session"
    assert [a["choice"] for a in answers] == ["session"] * 3


async def test_undeliverable_approval_falls_back_to_deny(monkeypatch) -> None:
    monkeypatch.setattr("hermescall_bridge.hermes.APPROVAL_RETRIES", (0.0,))
    answers: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        choice = json.loads(request.content)["choice"]
        answers.append(choice)
        return httpx.Response(400 if choice == "once" else 200)

    assert await hermes_with(handler).answer_approval(ApprovalRequest("run", "r", "ls", ""), "once") == "deny"
    assert answers == ["once", "deny"]

    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    assert await hermes_with(down).answer_approval(ApprovalRequest("run", "r", "ls", ""), "once") is None


# ---- J1/J2 -------------------------------------------------------------------------


async def test_healthz_and_metrics_need_no_token_but_nothing_else_opens(h) -> None:  # noqa: F811
    METRICS.call_latency.observe(1.2)
    async with ClientSession() as session:
        async with session.get(f"http://127.0.0.1:{h.api_port}/healthz") as response:
            assert response.status == 200 and (await response.json())["relay"] is True
        async with session.get(f"http://127.0.0.1:{h.api_port}/metrics") as response:
            text = await response.text()
            assert response.status == 200
            assert "hermescall_bridge_call_latency_seconds_count" in text
            assert "hermescall_bridge_relay_connected 1" in text and "hermescall_bridge_chat_outbox_depth 0" in text
        async with session.get(f"http://127.0.0.1:{h.api_port}/v1/status") as response:
            assert response.status == 401
        async with session.get(f"http://127.0.0.1:{h.api_port}/healthz/../v1/status") as response:
            assert response.status == 401


async def test_health_checker_reports_each_dependency(monkeypatch) -> None:
    from hermescall_bridge import health

    async def probe(url: str, path: str = "/health", timeout: float = 3.0) -> health.Probe:
        return health.Probe("8642" in url, "x")

    monkeypatch.setattr(health, "probe_http", probe)
    checker = health.HealthChecker("http://127.0.0.1:8642", "http://127.0.0.1:8880", lambda: True)
    assert await checker.check() == {"ok": False, "relay": True, "hermes": True, "kokoro": False}


def test_sd_notify_writes_to_the_notify_socket(tmp_path, monkeypatch) -> None:
    import socket
    import tempfile

    from hermescall_bridge import health

    path = tempfile.mktemp(prefix="hc-notify-", dir="/tmp")  # noqa: S306 - AF_UNIX paths must be short
    server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    server.bind(path)
    try:
        monkeypatch.setenv("NOTIFY_SOCKET", path)
        assert health.sd_notify("READY=1") and server.recv(64) == b"READY=1"
        monkeypatch.setenv("WATCHDOG_USEC", "60000000")
        monkeypatch.delenv("WATCHDOG_PID", raising=False)
        assert health.watchdog_interval() == 30.0
    finally:
        server.close()
    monkeypatch.delenv("NOTIFY_SOCKET")
    assert health.sd_notify("READY=1") is False
