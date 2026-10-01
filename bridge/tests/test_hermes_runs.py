"""Call turns through Hermes' /v1/runs (v0.21): the only API surface that streams approval requests.
Older Hermes (no version in /health, or no /v1/runs) keeps /v1/chat/completions."""

import asyncio
import json

import httpx
import pytest

from hermescall_bridge.calls import ActiveCall
from hermescall_bridge.hermes import ApprovalRequest, HermesClient, HermesRunError, TextDelta, ToolProgress

from .test_regressions import SlowTurnRelay, call_manager
from .test_units import sse


def runs_events(*events: dict) -> bytes:
    """GET /v1/runs/{id}/events: `data:` frames only, the event name inside, then a closing comment."""
    frames = [f"data: {json.dumps(event)}\n\n" for event in events]
    return ("".join(frames) + ": stream closed\n\n").encode()


def ev(name: str, **fields) -> dict:
    return {"event": name, "run_id": "run_1", "timestamp": 1.0, **fields}


class FakeApi:
    """Hermes' API server: /health with or without a version, /v1/runs, chat completions."""

    def __init__(self, version: str | None = "0.21.5", runs: bool = True, events: bytes = b"") -> None:
        self.version, self.runs, self.events = version, runs, events
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        path = request.url.path
        if path == "/health":
            body = {"status": "ok", "platform": "hermes-agent"}
            return httpx.Response(200, json=body | ({"version": self.version} if self.version else {}))
        if path == "/v1/runs":
            if not self.runs:
                return httpx.Response(404, json={"error": "not found"})
            return httpx.Response(202, json={"run_id": "run_1", "status": "started"})
        if path == "/v1/runs/run_1/events":
            return httpx.Response(200, content=self.events, headers={"content-type": "text/event-stream"})
        if path.startswith("/v1/runs/run_1/"):
            return httpx.Response(200, json={})
        body = sse(("", {"id": "chatcmpl-1", "choices": [{"delta": {"content": "Completions."}}]}), ("", "[DONE]"))
        return httpx.Response(200, content=body, headers={"content-type": "text/event-stream"})

    def paths(self) -> list[str]:
        return [f"{r.method} {r.url.path}" for r in self.seen]


def client_for(api: FakeApi) -> HermesClient:
    client = HermesClient("http://127.0.0.1:8642", "key", "phone-session")
    client._client = httpx.AsyncClient(
        base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(api), headers=client._client.headers
    )
    return client


async def test_a_call_turn_runs_through_v1_runs_and_streams_approvals() -> None:
    api = FakeApi(
        events=runs_events(
            ev("tool.started", tool="terminal", preview="rm -rf /tmp/x"),
            ev(
                "approval.request",
                request_id="r1",
                command="rm -rf /tmp/x",
                description="delete",
                choices=["once", "session", "always", "deny"],
            ),
            ev("approval.responded", choice="once", request_id="r1", resolved=1),
            ev("tool.completed", tool="terminal", duration=0.2, error=False),
            ev("message.delta", delta="Done, "),
            ev("message.delta", delta="deleted."),
            ev("run.completed", output="Done, deleted.", completed=True),
        )
    )
    client = client_for(api)
    events = [e async for e in client.turn("sys", "delete it", session_id="s-1")]
    started, approval, completed, *text = events
    assert approval == ApprovalRequest("run_1", "r1", "rm -rf /tmp/x", "delete", ("once", "session", "deny"))
    assert started.status == "running" and started.tool == "terminal" and started.label == "rm -rf /tmp/x"
    assert completed == ToolProgress("terminal", "completed", started.call_id)
    assert text == [TextDelta("Done, "), TextDelta("deleted.")]
    assert api.paths() == ["GET /health", "POST /v1/runs", "GET /v1/runs/run_1/events"]
    body = json.loads(api.seen[1].content)
    assert body == {"input": "delete it", "instructions": "sys", "session_id": "s-1", "model": "hermes-agent"}
    assert api.seen[1].headers["Authorization"] == "Bearer key"
    await client.answer_approval(approval, "once")
    assert api.seen[-1].url.path == "/v1/runs/run_1/approval"
    assert json.loads(api.seen[-1].content) == {"choice": "once", "request_id": "r1"}


async def test_images_go_as_content_parts_of_the_run_input() -> None:
    api = FakeApi(events=runs_events(ev("message.delta", delta="A cat."), ev("run.completed", output="A cat.")))
    events = [e async for e in client_for(api).turn("sys", "what is this?", images=[b"\xff\xd8"])]
    assert events == [TextDelta("A cat.")]
    [message] = json.loads(api.seen[1].content)["input"]
    assert message["role"] == "user" and message["content"][0] == {"type": "text", "text": "what is this?"}
    assert message["content"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


async def test_a_run_without_streamed_text_speaks_its_output() -> None:
    api = FakeApi(events=runs_events(ev("run.completed", output="All good.")))
    assert [e async for e in client_for(api).turn("sys", "status?")] == [TextDelta("All good.")]


async def test_a_failed_run_is_a_hermes_error() -> None:
    api = FakeApi(events=runs_events(ev("message.delta", delta="Let me"), ev("run.failed", error="provider down")))
    with pytest.raises(HermesRunError):
        [e async for e in client_for(api).turn("sys", "status?")]


async def test_a_turn_cut_off_stops_its_run() -> None:
    api = FakeApi(events=runs_events(ev("message.delta", delta="One. "), ev("message.delta", delta="Two.")))
    turn = client_for(api).turn("sys", "count")
    assert await anext(turn) == TextDelta("One. ")
    await turn.aclose()  # barge-in, hang-up or tap-to-interrupt
    assert api.paths()[-1] == "POST /v1/runs/run_1/stop"


async def test_a_finished_run_is_not_stopped() -> None:
    api = FakeApi(events=runs_events(ev("message.delta", delta="Hi."), ev("run.completed", output="Hi.")))
    [e async for e in client_for(api).turn("sys", "hi")]
    assert "POST /v1/runs/run_1/stop" not in api.paths()


async def test_older_hermes_keeps_chat_completions_and_is_detected_once() -> None:
    api = FakeApi(version=None)  # v0.15: /health has no version, /v1/runs loads no session history
    client = client_for(api)
    for _ in range(2):
        assert [e async for e in client.turn("sys", "hi")] == [TextDelta("Completions.")]
    assert api.paths() == ["GET /health", "POST /v1/chat/completions", "POST /v1/chat/completions"]


async def test_no_v1_runs_falls_back_to_chat_completions_for_good() -> None:
    api = FakeApi(runs=False)
    client = client_for(api)
    for _ in range(2):
        assert [e async for e in client.turn("sys", "hi")] == [TextDelta("Completions.")]
    assert api.paths() == ["GET /health", "POST /v1/runs", "POST /v1/chat/completions", "POST /v1/chat/completions"]


async def test_hermes_down_during_detection_is_asked_again_next_turn() -> None:
    api = FakeApi()
    calls = 0

    def flaky(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ConnectError("starting")
        return api(request)

    client = client_for(api)
    client._client = httpx.AsyncClient(base_url="http://127.0.0.1:8642", transport=httpx.MockTransport(flaky))
    with pytest.raises(httpx.HTTPError):
        [e async for e in client.turn("sys", "hi")]
    api.events = runs_events(ev("message.delta", delta="Up."), ev("run.completed", output="Up."))
    assert [e async for e in client.turn("sys", "hi")] == [TextDelta("Up.")]


async def test_the_phone_is_offered_only_the_choices_hermes_allows() -> None:
    relay = SlowTurnRelay()
    manager, device = call_manager(relay)
    call = ActiveCall("c1", device, pc=None)
    manager.active = call
    request = ApprovalRequest("run_1", "r9", "rm -rf /", "smart-denied", ("once", "deny"))
    ask = asyncio.ensure_future(manager._ask_approval(call, request))
    await asyncio.sleep(0)
    assert relay.sent[-1]["data"]["choices"] == ["once", "deny"]
    await manager._on_approval_answer(device, {"call_id": "c1", "request_id": "r9", "choice": "session"})
    assert await ask == "deny"
