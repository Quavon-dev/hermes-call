"""Hermes Agent API server client (OpenAI-compatible chat completions, SSE).

The session id makes Hermes load and persist the call history in its own
session store, so calls continue one conversation with full agent context.
"""

import asyncio
import base64
import json
import logging
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


@dataclass(frozen=True)
class TextDelta:
    text: str


@dataclass(frozen=True)
class ApprovalRequest:
    run_id: str
    request_id: str | None
    command: str
    description: str


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

    async def turn(
        self, system: str, user_text: str, images: Sequence[bytes] = (), session_id: str | None = None
    ) -> AsyncIterator[Event]:
        """One user turn; `images` (JPEG) go along as OpenAI-style `image_url` parts with data URLs.
        `session_id` overrides the configured Hermes session (calls use one per phone, sessions.py)."""
        content: str | list[dict[str, Any]] = user_text
        if images:
            content = [{"type": "text", "text": user_text}] + [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{base64.b64encode(image).decode()}"}}
                for image in images
            ]
        body = {
            "model": self._model,
            "stream": True,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
        }
        headers = {"X-Hermes-Session-Id": session_id or self._session_id}
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
    return ApprovalRequest(
        run_id=str(payload.get("run_id") or completion_id),
        request_id=payload.get("request_id") if isinstance(payload.get("request_id"), str) else None,
        command=str(payload.get("command", ""))[: MAX_APPROVAL_TEXT + 1],
        description=str(payload.get("description", ""))[: MAX_APPROVAL_TEXT + 1],
    )
