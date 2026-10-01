"""Hermes plugin: feature probe (E6), interruptible tools (E8), adapter cursor epoch (A1),
approvals and per-turn answers (E7). Hermes' gateway modules are stubbed here; the real ones are
exercised by test_chat.py::test_adapter_against_real_hermes_gateway_classes when available."""

import asyncio
import importlib
import json
import logging
import sys
import threading
import time
import types
from dataclasses import dataclass, field
from typing import Any

import pytest

from .test_hermes_plugin import Ctx, plugin

# ---- stubbed Hermes -------------------------------------------------------------


@dataclass
class SendResult:
    success: bool
    message_id: str | None = None
    error: str | None = None
    retryable: bool = False


@dataclass
class MessageEvent:
    text: str = ""
    message_type: Any = None
    source: Any = None
    message_id: str | None = None
    media_urls: list = field(default_factory=list)
    media_types: list = field(default_factory=list)
    reply_to_message_id: str | None = None


class BasePlatformAdapter:
    def __init__(self, config: Any, platform: Any) -> None:
        self._running = False
        self.handled: list = []

    def _mark_connected(self) -> None:
        self._running = True

    def _mark_disconnected(self) -> None:
        self._running = False

    def _set_fatal_error(self, *args, **kwargs) -> None:
        self._running = False

    def build_source(self, **kwargs) -> dict:
        return kwargs

    async def handle_message(self, event: MessageEvent) -> None:
        self.handled.append(event)

    @staticmethod
    def truncate_message(content: str, limit: int) -> list[str]:
        return [content[i : i + limit] for i in range(0, len(content), limit)] or [""]


@pytest.fixture
def adapter_module(monkeypatch):
    resolved: list[tuple[str, str]] = []
    base = types.ModuleType("gateway.platforms.base")
    base.BasePlatformAdapter = BasePlatformAdapter
    base.MessageEvent = MessageEvent
    base.MessageType = types.SimpleNamespace(TEXT="text", PHOTO="photo", DOCUMENT="document")
    base.SendResult = SendResult
    base.cache_image_from_bytes = base.cache_document_from_bytes = lambda data, name: name
    config = types.ModuleType("gateway.config")
    config.Platform = str
    approval = types.ModuleType("tools.approval")
    approval.resolve_gateway_approval = lambda key, choice: resolved.append((key, choice)) or 1
    for name, module in {
        "gateway": types.ModuleType("gateway"),
        "gateway.platforms": types.ModuleType("gateway.platforms"),
        "gateway.platforms.base": base,
        "gateway.config": config,
        "tools": types.ModuleType("tools"),
        "tools.approval": approval,
    }.items():
        monkeypatch.setitem(sys.modules, name, module)
    monkeypatch.delitem(sys.modules, "hermes_call_plugin.adapter", raising=False)
    module = importlib.import_module("hermes_call_plugin.adapter")
    module.resolved = resolved
    yield module
    sys.modules.pop("hermes_call_plugin.adapter", None)


# ---- E6 -------------------------------------------------------------------------------


def test_min_hermes_is_declared() -> None:
    text = (plugin.__file__.rsplit("/", 1)[0] + "/plugin.yaml").strip()
    with open(text) as handle:
        assert 'min_hermes: "0.15"' in handle.read()


def test_missing_hermes_internals_disable_only_their_feature(monkeypatch, caplog) -> None:
    features = dict.fromkeys(plugin.FEATURES, True) | {"task progress": False}
    monkeypatch.setattr(plugin, "probe_features", lambda: features)
    ctx = Ctx()
    with caplog.at_level(logging.WARNING):
        plugin.register(ctx)
    assert "call_owner" in ctx.tools and ctx.hooks == {}
    assert "task progress" in caplog.text


def test_probe_reports_what_is_importable(adapter_module) -> None:
    features = plugin.probe_features()
    assert features["chat platform"] and features["chat approvals"]
    assert not features["task progress"]  # no gateway.session_context in the stub


# ---- E8 -------------------------------------------------------------------------------


def test_waiting_tool_returns_when_the_agent_is_interrupted(monkeypatch) -> None:
    release = threading.Event()

    def slow(path: str, body: dict, timeout: float) -> dict:
        release.wait(10)
        return {"status": "answered"}

    monkeypatch.setattr(plugin, "_post_blocking", slow)
    monkeypatch.setattr(plugin, "INTERRUPT_POLL", 0.02)
    flag = {"on": False}
    monkeypatch.setattr(plugin, "_interrupted", lambda: flag["on"])
    monkeypatch.setenv("HERMES_CALL_TOKEN", "t")
    threading.Timer(0.1, lambda: flag.update(on=True)).start()
    started = time.monotonic()
    result = json.loads(plugin.call_owner({"reason": "r", "first_message": "hi"}))
    release.set()
    assert result["success"] is False and "interrupted" in result["error"]
    assert time.monotonic() - started < 2


def test_waiting_tool_passes_results_and_errors_through(monkeypatch) -> None:
    monkeypatch.setattr(plugin, "INTERRUPT_POLL", 0.01)
    monkeypatch.setattr(plugin, "_post_blocking", lambda path, body, timeout: {"status": "answered"})
    assert plugin._post("/v1/calls", {}, 5) == {"status": "answered"}

    def failing(path: str, body: dict, timeout: float) -> dict:
        raise plugin._BridgeError("the bridge answered HTTP 500")

    monkeypatch.setattr(plugin, "_post_blocking", failing)
    with pytest.raises(plugin._BridgeError, match="HTTP 500"):
        plugin._post("/v1/calls", {}, 5)


# ---- adapter: A1 epoch, E7 approvals and answers ------------------------------------


class FakeHttp:
    def __init__(self, responses: list[dict]) -> None:
        self.responses = responses
        self.gets: list[dict] = []
        self.posts: list[tuple[str, dict]] = []
        self.timeouts: dict[str, float | None] = {}

    async def get(self, path: str, params: dict):
        self.gets.append(dict(params))
        if not self.responses:
            await asyncio.sleep(10)
        return Response(self.responses.pop(0))

    async def post(self, path: str, json: dict, timeout: float | None = None):
        self.posts.append((path, json))
        self.timeouts[path] = timeout
        return Response({"message_id": "m", "status": "sent"})

    async def aclose(self) -> None:
        pass


class Response:
    status_code = 200

    def __init__(self, body: dict) -> None:
        self.body = body

    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict:
        return self.body


async def run_polls(adapter, http: FakeHttp, count: int) -> None:
    adapter._http, adapter._running = http, True
    task = asyncio.ensure_future(adapter._poll_loop())
    while len(http.gets) <= count:
        await asyncio.sleep(0.01)
    task.cancel()


async def test_adapter_sends_the_bridge_epoch_with_its_cursor(adapter_module) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    http = FakeHttp(
        [
            {"cursor": 5, "events": [], "epoch": "E1"},
            {"cursor": 7, "events": [], "epoch": "E2"},  # the bridge's event store changed
            {"cursor": 7, "events": []},  # an older bridge: no epoch, keep the last one
        ]
    )
    await run_polls(adapter, http, 3)
    assert [g["cursor"] for g in http.gets[:4]] == [0, 5, 7, 7]
    assert [g.get("epoch") for g in http.gets[:4]] == [None, "E1", "E2", "E2"]


async def test_session_approval_and_expiry(adapter_module, monkeypatch) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._http = FakeHttp([])
    await adapter.send_exec_approval("owner", "ls", "session-1")
    request_id = next(iter(adapter._approvals))
    await adapter._on_approval({"request_id": request_id, "choice": "session"})
    await adapter.send_exec_approval("owner", "rm x", "session-2")
    await adapter.send_exec_approval("owner", "rm y", "session-3")
    second = list(adapter._approvals)[0]
    await adapter._on_approval({"request_id": second, "choice": "always"})  # not offered: denied
    adapter._approvals = {k: entry._replace(until=time.monotonic() - 1) for k, entry in adapter._approvals.items()}
    adapter._expire_approvals()
    assert adapter_module.resolved == [("session-1", "session"), ("session-2", "deny"), ("session-3", "deny")]
    assert adapter._approvals == {}


async def test_a_failing_resolver_does_not_break_the_adapter(adapter_module, monkeypatch) -> None:
    def broken(key: str, choice: str) -> int:
        raise RuntimeError("hermes internals changed")

    monkeypatch.setattr(sys.modules["tools.approval"], "resolve_gateway_approval", broken)
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._approvals["r"] = adapter_module._Pending("s", time.monotonic() + 60)
    await adapter._on_approval({"request_id": "r", "choice": "once"})  # logged, no exception
    assert adapter._approvals == {}


async def test_final_reply_answers_its_own_turn(adapter_module) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._http = FakeHttp([])
    await adapter.on_processing_start(MessageEvent(message_id="voice-note"))
    await adapter.on_processing_start(MessageEvent(message_id="later-text"))
    await adapter.send("owner", "reply to the note", reply_to="voice-note", metadata={"notify": True})
    await adapter.send("owner", "interim", reply_to="later-text")
    await adapter.on_processing_complete(MessageEvent(message_id="voice-note"), "success")
    await adapter.send("owner", "cron", metadata={"notify": True})
    bodies = [body for path, body in adapter._http.posts if path == "/v1/chat/messages"]
    assert bodies[0]["answers"] == "voice-note"
    assert "answers" not in bodies[1]
    assert bodies[2]["answers"] == "later-text"  # no reply anchor: the newest open turn


async def test_adapter_fetches_spooled_attachments_and_still_reads_inline_ones(adapter_module) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    fetched: list[str] = []

    class FileHttp:
        async def get(self, path: str, params: dict | None = None):
            fetched.append(path)
            return type("R", (), {"raise_for_status": lambda self: None, "content": b"spooled bytes"})()

    adapter._http = FileHttp()
    assert await adapter._attachment_data({"file_id": "A" * 22}) == b"spooled bytes"
    assert fetched == ["/v1/chat/files/" + "A" * 22]
    assert await adapter._attachment_data({"data": "aW5saW5l"}) == b"inline"
    with pytest.raises(ValueError):
        await adapter._attachment_data({"file_id": "../../etc/passwd"})
    http = FakeHttp([{"cursor": 1, "events": []}])
    await run_polls(adapter, http, 1)
    assert http.gets[0]["files"] == 1


# ---- Hermes passes connect(is_reconnect=...) (v0.21) ----------------------------------


async def test_connect_accepts_the_arguments_hermes_passes(adapter_module, monkeypatch) -> None:
    monkeypatch.setenv("HERMES_CALL_TOKEN", "t")
    monkeypatch.setattr(adapter_module, "_client", lambda timeout: FakeHttp([]))
    adapter = adapter_module.HermesCallAdapter(None)
    assert await adapter.connect(is_reconnect=False)
    first = adapter._poller
    assert await adapter.connect(is_reconnect=True)
    await asyncio.sleep(0)
    assert first.cancelled() or first.done(), "a reconnect must not leave the old poll loop running"
    assert adapter._poller is not first
    await adapter.disconnect()


# ---- Hermes v0.21 approvals: _send_exec_approval_prompt and the allowed choices -------------


def test_the_adapter_renders_hermes_approval_prompts(adapter_module) -> None:
    # Hermes v0.21 sends approvals to a platform only if it overrides this (else: typed /approve).
    assert "_send_exec_approval_prompt" in adapter_module.HermesCallAdapter.__dict__


async def test_send_exec_approval_takes_hermes_flags_and_offers_only_allowed_choices(adapter_module) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    await adapter.send_exec_approval(
        "owner", "rm -rf /x", "s1", "delete", None, allow_permanent=True, allow_session=True, smart_denied=False
    )
    await adapter.send_exec_approval(
        "owner", "rm -rf /y", "s2", "delete", None, allow_permanent=True, allow_session=True, smart_denied=True
    )
    await adapter.send_exec_approval("owner", "rm -rf /z", "s3", "delete", None, allow_session=False)
    choices = [body["choices"] for path, body in http.posts if path == "/v1/chat/approvals"]
    assert choices == [["once", "session", "deny"], ["once", "deny"], ["once", "deny"]]


async def test_a_hermes_prompt_object_is_delivered_without_the_always_tier(adapter_module) -> None:
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    prompt = types.SimpleNamespace(
        chat_id="owner",
        session_key="s4",
        command="rm -rf /w",
        description="delete",
        metadata=None,
        actions=[("Once", "once", ""), ("Session", "session", ""), ("Always", "always", ""), ("Deny", "deny", "")],
    )
    result = await adapter._send_exec_approval_prompt(prompt)
    assert result.success
    path, body = http.posts[-1]
    assert path == "/v1/chat/approvals" and body["choices"] == ["once", "session", "deny"]
    assert body["command"] == "rm -rf /w"
