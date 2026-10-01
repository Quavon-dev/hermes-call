"""Hermes Agent API server client: one call turn as a Hermes run (SSE).

Hermes ≥ 0.21 runs a turn through `POST /v1/runs` + `GET /v1/runs/{id}/events`, the
only surface that streams tool approval requests (answered with
`POST /v1/runs/{id}/approval`) and can be stopped (`/v1/runs/{id}/stop`). Older Hermes
(no version in `/health`: its /v1/runs does not load the session's history) and a Hermes
without /v1/runs use the OpenAI-compatible `/v1/chat/completions` stream. The session id
makes Hermes load and persist the call history in its own session store, so calls
continue one conversation with full agent context.
"""

import asyncio
import base64
import contextlib
import itertools
import json
import logging
import re
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from typing import Any

import httpx

log = logging.getLogger(__name__)

# Longer approval texts are denied, never shown cut off on the phone.
MAX_APPROVAL_TEXT = 4000
# "session": allow this command pattern for the rest of the Hermes session (Hermes ≥ 0.15).
APPROVAL_CHOICES = ("once", "session", "deny")
# Answering an approval: retries, then a deny, so a Hermes run never waits on a lost answer.
APPROVAL_RETRIES = (0.5, 1.0, 2.0)
# The first Hermes whose /v1/runs continues the session's history (and streams approvals).
RUNS_SINCE = (0, 21)
# Stopping a run the call no longer waits for (barge-in, hang-up): best effort, never blocks long.
STOP_TIMEOUT = 5.0
RUN_FAILED = ("run.failed", "run.cancelled", "run.interrupted")


class HermesRunError(ValueError):
    """A Hermes run ended failed, cancelled or interrupted (a Hermes error, like an HTTP failure)."""


class _RunsUnavailable(Exception):
    """POST /v1/runs answered 404: this Hermes has no runs API."""


@dataclass(frozen=True)
class TextDelta:
    text: str


@dataclass(frozen=True)
class ApprovalRequest:
    run_id: str
    request_id: str | None
    command: str
    description: str
    # What Hermes allows for this request (a smart deny: once/deny); never "always" on the phone.
    choices: tuple[str, ...] = APPROVAL_CHOICES


@dataclass(frozen=True)
class ToolProgress:
    """`event: hermes.tool.progress` from the API server: a tool started (running) or finished (completed)."""

    tool: str
    status: str
    call_id: str
    label: str = ""


Event = TextDelta | ApprovalRequest | ToolProgress
TOOL_STATUSES = ("running", "completed")


class HermesClient:
    def __init__(self, url: str, api_key: str, session_id: str, model: str = "hermes-agent") -> None:
        self._client = httpx.AsyncClient(
            base_url=url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=httpx.Timeout(connect=5.0, read=600.0, write=30.0, pool=5.0),
        )
        self._session_id = session_id
        self._model = model
        self._runs: bool | None = None  # None: not known yet (asked on the first turn)

    async def turn(
        self, system: str, user_text: str, images: Sequence[bytes] = (), session_id: str | None = None
    ) -> AsyncIterator[Event]:
        """One user turn; `images` (JPEG) go along as OpenAI-style `image_url` parts with data URLs.
        `session_id` overrides the configured Hermes session (calls use one per phone, sessions.py)."""
        content = _content(user_text, images)
        session = session_id or self._session_id
        if await self._uses_runs():
            try:
                async with contextlib.aclosing(self._run_turn(system, content, session)) as events:
                    async for event in events:
                        yield event
                return
            except _RunsUnavailable:
                log.info("Hermes has no /v1/runs; calls use /v1/chat/completions (no approval requests)")
                self._runs = False
        async with contextlib.aclosing(self._completion_turn(system, content, session)) as events:
            async for event in events:
                yield event

    async def _uses_runs(self) -> bool:
        """Asked once: Hermes' /health names its version from 0.21 on. Unreachable: ask again next turn."""
        if self._runs is None:
            response = await self._client.get("/health")
            version = _json(response.text).get("version") if response.status_code == 200 else None
            self._runs = _version_at_least(version, RUNS_SINCE)
            log.info("Hermes %s: calls use %s", version or "(version unknown)", "/v1/runs" if self._runs else "chat completions")
        return self._runs

    async def _run_turn(self, system: str, content: str | list[dict[str, Any]], session: str) -> AsyncIterator[Event]:
        user_input = content if isinstance(content, str) else [{"role": "user", "content": content}]
        body = {"input": user_input, "instructions": system, "session_id": session, "model": self._model}
        response = await self._client.post("/v1/runs", json=body)
        if response.status_code == 404:
            raise _RunsUnavailable
        response.raise_for_status()
        run_id = str(response.json()["run_id"])
        ended = False
        try:
            async with self._client.stream("GET", f"/v1/runs/{run_id}/events") as stream:
                stream.raise_for_status()
                tools = _RunTools()
                spoke = False
                async for _, data in _sse(stream.aiter_lines()):
                    payload = _json(data)
                    name = payload.get("event")
                    if name in ("run.completed", *RUN_FAILED):
                        ended = True
                    if name in RUN_FAILED:
                        raise HermesRunError(f"{name}: {str(payload.get('error') or '')[:200]}")
                    if name == "run.completed":
                        if not spoke and isinstance(payload.get("output"), str) and payload["output"]:
                            yield TextDelta(payload["output"])  # a provider that streamed nothing
                        return
                    event = _run_event(name, payload, run_id, tools)
                    if event is not None:
                        spoke = spoke or isinstance(event, TextDelta)
                        yield event
        finally:
            if not ended:
                await self._stop(run_id)

    async def _stop(self, run_id: str) -> None:
        """The call no longer listens (barge-in, tap-to-interrupt, hang-up): Hermes stops the run."""
        try:
            await asyncio.shield(self._client.post(f"/v1/runs/{run_id}/stop", timeout=STOP_TIMEOUT))
        except httpx.HTTPError as exc:
            log.warning("stopping a Hermes run failed: %s", exc.__class__.__name__)
        except asyncio.CancelledError:
            log.debug("stopping a Hermes run continues in the background")
            raise

    async def _completion_turn(self, system: str, content: str | list[dict[str, Any]], session: str) -> AsyncIterator[Event]:
        body = {
            "model": self._model,
            "stream": True,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
        }
        headers = {"X-Hermes-Session-Id": session}
        async with self._client.stream("POST", "/v1/chat/completions", json=body, headers=headers) as response:
            response.raise_for_status()
            completion_id = ""
            async for event, data in _sse(response.aiter_lines()):
                if data == "[DONE]":
                    return
                try:
                    payload = json.loads(data)
                except ValueError:
                    continue
                if event == "approval.request":
                    yield _approval(payload, completion_id)
                elif event == "hermes.tool.progress":
                    if progress := _tool_progress(payload):
                        yield progress
                elif event in ("", "message") and isinstance(payload, dict):
                    completion_id = payload.get("id", completion_id)
                    if text := _delta_text(payload):
                        yield TextDelta(text)

    async def answer_approval(self, request: ApprovalRequest, choice: str) -> str | None:
        """Answers with retries; if `choice` cannot be delivered, a deny is tried last.
        Returns the choice Hermes accepted, or None (Hermes' own approval timeout then denies)."""
        if choice not in APPROVAL_CHOICES:
            raise ValueError("unsupported approval choice")
        for attempt in (choice, "deny") if choice != "deny" else ("deny",):
            if await self._post_approval(request, attempt):
                if attempt != choice:
                    log.warning("approval answer '%s' not accepted; denied instead", choice)
                return attempt
        log.error("approval answer could not be delivered to Hermes")
        return None

    async def _post_approval(self, request: ApprovalRequest, choice: str) -> bool:
        body: dict[str, Any] = {"choice": choice}
        if request.request_id:
            body["request_id"] = request.request_id
        for delay in (*APPROVAL_RETRIES, None):
            try:
                response = await self._client.post(f"/v1/runs/{request.run_id}/approval", json=body)
            except httpx.HTTPError as exc:
                log.warning("approval answer failed: %s", exc.__class__.__name__)
            else:
                if response.status_code < 400:
                    return True
                log.warning("approval answer rejected: status=%s", response.status_code)
                if response.status_code < 500:
                    return False  # a 4xx does not get better by retrying
            if delay is not None:
                await asyncio.sleep(delay)
        return False

    async def close(self) -> None:
        await self._client.aclose()


async def _sse(lines: AsyncIterator[str]) -> AsyncIterator[tuple[str, str]]:
    event, data = "", []
    async for line in lines:
        if not line:
            if data:
                yield event, "\n".join(data)
            event, data = "", []
        elif line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].lstrip())
    if data:
        yield event, "\n".join(data)


def _content(user_text: str, images: Sequence[bytes]) -> str | list[dict[str, Any]]:
    if not images:
        return user_text
    return [{"type": "text", "text": user_text}] + [
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{base64.b64encode(image).decode()}"}}
        for image in images
    ]


def _version_at_least(version: Any, minimum: tuple[int, int]) -> bool:
    match = re.match(r"v?(\d+)\.(\d+)", version) if isinstance(version, str) else None
    return match is not None and (int(match[1]), int(match[2])) >= minimum


def _json(data: str) -> dict:
    try:
        payload = json.loads(data)
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


class _RunTools:
    """Run events name the tool but carry no call id: one is made up per start, a completion closes
    the oldest open call of that tool."""

    def __init__(self) -> None:
        self._ids = itertools.count(1)
        self._open: dict[str, list[str]] = {}

    def started(self, tool: str) -> str:
        call_id = f"run-tool-{next(self._ids)}"
        self._open.setdefault(tool, []).append(call_id)
        return call_id

    def completed(self, tool: str) -> str | None:
        calls = self._open.get(tool)
        return calls.pop(0) if calls else None


def _run_event(name: Any, payload: dict, run_id: str, tools: _RunTools) -> Event | None:
    if name == "message.delta":
        delta = payload.get("delta")
        return TextDelta(delta) if isinstance(delta, str) and delta else None
    if name == "approval.request":
        return _approval({**payload, "run_id": payload.get("run_id") or run_id}, run_id)
    tool = payload.get("tool")
    if name not in ("tool.started", "tool.completed") or not isinstance(tool, str):
        return None
    if name == "tool.started":
        preview = payload.get("preview")
        return _tool_progress(
            {
                "tool": tool,
                "status": "running",
                "toolCallId": tools.started(tool),
                "label": preview if isinstance(preview, str) else "",
            }
        )
    call_id = tools.completed(tool)
    return _tool_progress({"tool": tool, "status": "completed", "toolCallId": call_id}) if call_id else None


def _delta_text(payload: dict) -> str:
    choices = payload.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return ""
    content = (choices[0].get("delta") or {}).get("content")
    return content if isinstance(content, str) else ""


def _tool_progress(payload: Any) -> ToolProgress | None:
    """Internal tools (`_thinking`) and events without a call id are dropped."""
    if not isinstance(payload, dict):
        return None
    tool, status, call_id, label = (payload.get(k) for k in ("tool", "status", "toolCallId", "label"))
    if not isinstance(tool, str) or not tool or tool.startswith("_") or status not in TOOL_STATUSES:
        return None
    if not isinstance(call_id, str) or not call_id:
        return None
    label = label if isinstance(label, str) and status == "running" and label != tool else ""
    return ToolProgress(tool, status, call_id, label)


def _approval(payload: Any, completion_id: str) -> ApprovalRequest:
    payload = payload if isinstance(payload, dict) else {}
    allowed = payload.get("choices")
    choices = APPROVAL_CHOICES
    if isinstance(allowed, list) and {"once", "deny"} <= set(allowed):
        choices = tuple(choice for choice in APPROVAL_CHOICES if choice in allowed)
    return ApprovalRequest(
        run_id=str(payload.get("run_id") or completion_id),
        request_id=payload.get("request_id") if isinstance(payload.get("request_id"), str) else None,
        command=str(payload.get("command", ""))[: MAX_APPROVAL_TEXT + 1],
        description=str(payload.get("description", ""))[: MAX_APPROVAL_TEXT + 1],
        choices=choices,
    )
