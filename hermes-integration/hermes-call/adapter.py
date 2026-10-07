"""Hermes platform `hermes_call`: chat with the owner in the Hermes Call app.

The adapter talks only to the local hermes-call-bridge (loopback HTTP, the same
token as `call_owner`): it long-polls `/v1/chat/events` for the owner's
messages and posts replies, files and typing notices. The bridge encrypts
everything end to end for the owner's paired phones. Only paired phones can
reach the bridge, so the platform needs no user allow-list of its own.

Approvals for commands in chat sessions, and Hermes' slash-command confirmations
(`/new`, `/reload-mcp`, ...), are shown on the phone and need Face ID; typed
`/approve` is refused on this platform.

Tool progress is not rendered as chat bubbles: the plugin's tool hooks (progress.py)
post it to the bridge, which shows it as the tasks ring and a Live Activity; this
adapter eats the tool chrome and reports when a turn ends.
"""

import asyncio
import base64
import importlib
import inspect
import logging
import mimetypes
import os
import secrets
import time
from pathlib import Path
from typing import Any, NamedTuple

import httpx
from gateway.config import Platform
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
    cache_document_from_bytes,
    cache_image_from_bytes,
)

from . import bridge_url
from .progress import DEFAULT_TURN, MAX_TURN_ID, REPORTER

log = logging.getLogger(__name__)

PLATFORM = "hermes_call"
CHAT_ID = "owner"
CHAT_NAME = "Hermes Call"
MAX_MESSAGE_LENGTH = 8000
MAX_FILE_BYTES = 10 * 1024 * 1024
POLL_WAIT_SECONDS = 25
# Hermes waits `approvals.timeout` (default 300 s) for an answer and then drops the request. The phone
# shows it a little shorter, so neither a late answer nor our expiry deny can reach another request.
DEFAULT_APPROVAL_TIMEOUT = 300.0
APPROVAL_MARGIN = 5.0
MIN_APPROVAL_TTL = 10.0
APPROVAL_CHOICES = ("once", "session")
# Hermes' runner gives up on an approval prompt after 15 s; the bridge answers at once.
APPROVAL_POST_TIMEOUT = 10.0
BACKOFF_SECONDS = (1, 2, 5, 10, 30)
TYPING_INTERVAL = 4.0
# Live reply drafts: the bridge shows at most this much (the final reply carries everything).
MAX_DRAFT = 4000
DRAFT_TIMEOUT = 5.0
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic"}
PLATFORM_HINT = (
    "You are chatting with your owner in the Hermes Call iPhone app (end-to-end encrypted to their phone). "
    "Markdown is rendered: bold, italics, lists, inline code, code blocks and links. Keep messages short and "
    "scannable; the first lines show on the lock screen. Photos and files you send appear inline. Commands that "
    "need approval are approved with Face ID on the phone. For something urgent you can phone them with call_owner."
)


def _token() -> str:
    return os.environ.get("HERMES_CALL_TOKEN", "")


def _b64decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _b64encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class _Pending(NamedTuple):
    """An approval sheet on the phone, by our request id."""

    session_key: str
    until: float  # monotonic deadline
    hermes_id: str | None = None  # Hermes' request id (v0.21); None: Hermes resolves its oldest
    confirm_id: str | None = None  # set for a slash-command confirmation (tools.slash_confirm)


def _client(timeout: float = 30.0) -> httpx.AsyncClient:
    # The token must reach only the local bridge: no proxies from the environment, no redirects.
    return httpx.AsyncClient(
        base_url=bridge_url(),
        headers={"Authorization": f"Bearer {_token()}"},
        timeout=httpx.Timeout(timeout, connect=5.0),
        trust_env=False,
        follow_redirects=False,
    )


def _file_body(path: str, kind: str, caption: str | None, name: str | None) -> dict[str, Any]:
    file = Path(path)
    if not file.is_file() or file.stat().st_size > MAX_FILE_BYTES:
        raise ValueError("file missing or larger than 10 MiB")
    mime = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    return {
        "kind": kind,
        "name": name or file.name,
        "mime": mime,
        "data": _b64encode(file.read_bytes()),
        "caption": (caption or "")[:MAX_MESSAGE_LENGTH],
    }


def _kind_for(path: str) -> str:
    return "photo" if Path(path).suffix.lower() in IMAGE_EXTENSIONS else "file"


async def _post(client: httpx.AsyncClient, path: str, body: dict[str, Any], timeout: float | None = None) -> dict[str, Any]:
    response = await (client.post(path, json=body, timeout=timeout) if timeout else client.post(path, json=body))
    response.raise_for_status()
    return response.json()


class HermesCallAdapter(BasePlatformAdapter):
    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH
    # send() chunks long text itself, so Hermes hands cron output over in full.
    splits_long_messages = True

    def __init__(self, config: Any) -> None:
        super().__init__(config=config, platform=Platform(PLATFORM))
        self._http: httpx.AsyncClient | None = None
        self._poller: asyncio.Task | None = None
        self._cursor = 0
        # The bridge's event store: a different one means our cursor is meaningless (sent along, A1).
        self._epoch: str | None = None
        # our request id (the phone's) → what it answers
        self._approvals: dict[str, _Pending] = {}
        self._last_typing = 0.0
        # Owner messages being answered (insertion order = start order): a turn's final reply carries
        # `answers` = its message id, so a voice note gets a spoken reply.
        self._answering: dict[str, None] = {}

    @property
    def enforces_own_access_policy(self) -> bool:
        return True

    async def connect(self, *, is_reconnect: bool = False, **_: object) -> bool:
        """Hermes v0.21 passes is_reconnect; later keywords are accepted so a new one cannot break chat."""
        if self._poller is not None:  # a reconnect replaces the old poll loop and HTTP client
            await self.disconnect()
        if not _token():
            self._set_fatal_error("config", "HERMES_CALL_TOKEN is not set", retryable=False)
            return False
        try:
            self._http = _client(timeout=POLL_WAIT_SECONDS + 10)
        except ValueError as exc:
            self._set_fatal_error("config", str(exc), retryable=False)
            return False
        self._mark_connected()
        self._poller = asyncio.create_task(self._poll_loop())
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()
        if self._poller is not None:
            self._poller.cancel()
            await asyncio.gather(self._poller, return_exceptions=True)
            self._poller = None
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        return {"name": CHAT_NAME, "type": "dm"}

    # ---- inbound -----------------------------------------------------------

    async def _poll_loop(self) -> None:
        failures = 0
        while self._running and self._http is not None:
            self._expire_approvals()
            try:
                # files=1: attachments are fetched one by one (GET /v1/chat/files/<id>), not inline.
                params: dict[str, Any] = {"cursor": self._cursor, "wait": POLL_WAIT_SECONDS, "files": 1}
                if self._epoch:
                    params["epoch"] = self._epoch
                response = await self._http.get("/v1/chat/events", params=params)
                if response.status_code in (401, 403):
                    self._set_fatal_error("auth", "hermes-call-bridge rejected HERMES_CALL_TOKEN", retryable=False)
                    notify = getattr(self, "_notify_fatal_error", None)  # tells the gateway at once (v0.21)
                    if notify is not None:
                        await notify()
                    return
                response.raise_for_status()
                data = response.json()
                for event in data.get("events", []):
                    await self._dispatch(event)
                self._cursor = int(data.get("cursor", self._cursor))
                if isinstance(data.get("epoch"), str):  # older bridges send none
                    self._epoch = data["epoch"]
                failures = 0
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # the bridge restarting must not kill the adapter
                log.warning("hermes_call: bridge unavailable (%s)", exc.__class__.__name__)
                await asyncio.sleep(BACKOFF_SECONDS[min(failures, len(BACKOFF_SECONDS) - 1)])
                failures += 1

    async def _dispatch(self, event: dict[str, Any]) -> None:
        kind = event.get("type")
        if kind == "message":
            await self._on_message(event)
        elif kind == "approval":
            await self._on_approval(event)
        elif kind == "delivery_failed":
            log.warning(
                "hermes_call: message %s could not be delivered to a phone (%s)",
                str(event.get("message_id"))[:6],
                str(event.get("why"))[:60],
            )

    async def _on_message(self, event: dict[str, Any]) -> None:
        text = str(event.get("text") or "")
        if text.strip().lower().startswith("/approve"):
            await self.send(CHAT_ID, "Approvals need Face ID: use the approval sheet in the app.")
            return
        media_urls, media_types = [], []
        for item in event.get("attachments") or []:
            try:
                data = await self._attachment_data(item)
                name = Path(str(item.get("name") or "file")).name
                if item.get("kind") == "photo":
                    media_urls.append(cache_image_from_bytes(data, Path(name).suffix.lower() or ".jpg"))
                else:
                    media_urls.append(cache_document_from_bytes(data, name))
                media_types.append(str(item.get("mime") or "application/octet-stream"))
            except (KeyError, ValueError, OSError, httpx.HTTPError) as exc:
                log.warning("hermes_call: attachment dropped (%s)", exc.__class__.__name__)
        message_type = MessageType.TEXT
        if any(mime.startswith("image/") for mime in media_types):
            message_type = MessageType.PHOTO
        elif media_types:
            message_type = MessageType.DOCUMENT
        source = self.build_source(
            chat_id=CHAT_ID,
            chat_name=CHAT_NAME,
            chat_type="dm",
            user_id=CHAT_ID,
            user_name=str(event.get("user_name") or "Owner"),
            # Becomes HERMES_SESSION_MESSAGE_ID for the turn: the tool hooks use it as the task's turn id.
            message_id=event.get("id"),
        )
        await self.handle_message(
            MessageEvent(
                text=text,
                message_type=message_type,
                source=source,
                message_id=event.get("id"),
                media_urls=media_urls,
                media_types=media_types,
                reply_to_message_id=event.get("reply_to"),
            )
        )

    async def _attachment_data(self, item: dict[str, Any]) -> bytes:
        """Bridges from 0.7 send a `file_id` to fetch; older ones the bytes inline (`data`)."""
        if "data" in item:
            return _b64decode(item["data"])
        file_id = str(item["file_id"])
        if self._http is None or not file_id.replace("-", "").replace("_", "").isalnum() or len(file_id) > 64:
            raise ValueError("invalid file id")
        response = await self._http.get(f"/v1/chat/files/{file_id}")
        response.raise_for_status()
        return response.content

    async def _on_approval(self, event: dict[str, Any]) -> None:
        entry = self._approvals.pop(str(event.get("request_id")), None)
        if entry is None:
            return
        choice = event.get("choice") if event.get("choice") in APPROVAL_CHOICES else "deny"
        if entry.confirm_id is None:
            _resolve(entry.session_key, choice, entry.hermes_id)
            return
        reply = await _resolve_confirm(entry.session_key, entry.confirm_id, "once" if choice == "once" else "cancel")
        if reply:
            await self.send(CHAT_ID, reply)

    def _expire_approvals(self) -> None:
        """Approvals nobody answered in time are denied, so Hermes never waits on them forever.
        Slash-command confirmations just lapse (Hermes drops stale ones itself)."""
        now = time.monotonic()
        for request_id in [r for r, entry in self._approvals.items() if entry.until < now]:
            entry = self._approvals.pop(request_id)
            log.info("hermes_call: approval %s expired; denied", request_id[:6])
            if entry.confirm_id is None:
                _resolve(entry.session_key, "deny", entry.hermes_id)

    # ---- tool progress (tasks ring / Live Activity on the phone) ---------------

    def format_tool_event(self, event: Any, *, mode: str = "all", preview_max_len: int = 40) -> str | None:
        """No tool chrome in the chat: progress reaches the phone through the tool hooks (progress.py)."""
        return None

    async def on_processing_start(self, event: MessageEvent) -> None:
        if event.message_id:
            self._answering[str(event.message_id)] = None

    async def on_processing_complete(self, event: MessageEvent, outcome: Any) -> None:
        """The reply for this owner message was sent, or the turn failed or was cancelled (/stop):
        the task ends; a cancelled one as `failed`, the end state phones know besides `done`."""
        self._answering.pop(str(event.message_id), None)
        turn_id = str(event.message_id or DEFAULT_TURN)[:MAX_TURN_ID]
        REPORTER.turn_ended(turn_id, failed=getattr(outcome, "value", outcome) in ("failure", "cancelled"))

    # ---- outbound ----------------------------------------------------------

    async def send(
        self, chat_id: str, content: str, reply_to: str | None = None, metadata: dict[str, Any] | None = None
    ) -> SendResult:
        if self._http is None:
            return SendResult(success=False, error="not connected", retryable=True)
        message_id = None
        # Hermes marks the final response of a turn with metadata notify=True (interim messages are unmarked)
        # and replies to the owner message that started the turn (reply_to); older Hermes: the newest turn.
        answers = self._answers_for(reply_to) if (metadata or {}).get("notify") is True else None
        try:
            for chunk in self.truncate_message(content, MAX_MESSAGE_LENGTH):
                body = {"text": chunk}
                if reply_to:
                    body["reply_to"] = reply_to
                if answers:
                    body["answers"], answers = answers, None  # the first chunk only
                message_id = (await _post(self._http, "/v1/chat/messages", body)).get("message_id")
        except httpx.HTTPError as exc:
            return SendResult(success=False, error=f"bridge: {exc.__class__.__name__}", retryable=True)
        return SendResult(success=True, message_id=message_id)

    def _answers_for(self, reply_to: str | None) -> str | None:
        if reply_to and reply_to in self._answering:
            return reply_to
        return next(reversed(self._answering), None) if self._answering else None

    def supports_draft_streaming(
        self, chat_type: str | None = None, metadata: dict[str, Any] | None = None, chat_id: str | None = None
    ) -> bool:
        return True

    async def send_draft(self, chat_id: str, draft_id: int, content: str, metadata: dict[str, Any] | None = None) -> SendResult:
        """The reply so far, shown live in the app. Always "sent": a lost frame is replaced by the next one or
        the final reply, and a failure would make Hermes fall back to edits, which this platform does not have."""
        if self._http is not None:
            try:
                await _post(self._http, "/v1/chat/draft", {"draft_id": str(draft_id), "text": content[:MAX_DRAFT]}, DRAFT_TIMEOUT)
            except httpx.HTTPError:
                pass
        return SendResult(success=True)

    async def send_typing(self, chat_id: str, metadata: dict[str, Any] | None = None) -> None:
        now = time.monotonic()
        if self._http is None or now - self._last_typing < TYPING_INTERVAL:
            return
        self._last_typing = now
        try:
            await _post(self._http, "/v1/chat/typing", {})
        except httpx.HTTPError:
            pass

    async def _send_file(self, path: str, kind: str, caption: str | None, name: str | None = None) -> SendResult:
        if self._http is None:
            return SendResult(success=False, error="not connected", retryable=True)
        try:
            body = await asyncio.to_thread(_file_body, path, kind, caption, name)
            result = await _post(self._http, "/v1/chat/files", body)
        except (ValueError, OSError) as exc:
            return SendResult(success=False, error=str(exc))
        except httpx.HTTPError as exc:
            return SendResult(success=False, error=f"bridge: {exc.__class__.__name__}", retryable=True)
        return SendResult(success=True, message_id=result.get("message_id"))

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: str | None = None,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> SendResult:
        return await self._send_file(image_path, "photo", caption)

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: str | None = None,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> SendResult:
        if await asyncio.to_thread(Path(image_url).is_file):
            return await self._send_file(image_url, "photo", caption)
        return await super().send_image(chat_id, image_url, caption, reply_to, metadata)

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: str | None = None,
        file_name: str | None = None,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> SendResult:
        return await self._send_file(file_path, _kind_for(file_path), caption, file_name)

    async def send_voice(
        self,
        chat_id: str,
        audio_path: str,
        caption: str | None = None,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> SendResult:
        return await self._send_file(audio_path, "voice", caption)

    async def send_video(
        self,
        chat_id: str,
        video_path: str,
        caption: str | None = None,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> SendResult:
        return await self._send_file(video_path, "file", caption)

    async def send_exec_approval(
        self,
        chat_id: str,
        command: str,
        session_key: str,
        description: str = "dangerous command",
        metadata: dict[str, Any] | None = None,
        allow_permanent: bool = True,
        allow_session: bool = True,
        smart_denied: bool = False,
        **_: Any,
    ) -> SendResult:
        """Face ID sheet on the phone (Hermes up to v0.20 calls this directly; v0.21 through
        `_send_exec_approval_prompt`). "Allow for this session" only when Hermes allows that tier;
        the permanent tier is never offered on the phone."""
        choices = ["once", "session", "deny"] if allow_session and not smart_denied else ["once", "deny"]
        # Newer Hermes declares description: str | None (it sends its own default text).
        description = description if isinstance(description, str) else "dangerous command"
        return await self._deliver_approval(chat_id, str(command or ""), session_key, description, choices)

    async def _send_exec_approval_prompt(self, prompt: Any) -> SendResult:
        """Hermes v0.21 renders approvals through this hook; overriding it is what tells Hermes the
        platform has its own approval UI (otherwise it falls back to a typed `/approve` message)."""
        offered = {action[1] for action in getattr(prompt, "actions", ())}
        choices = [choice for choice in ("once", "session", "deny") if choice in offered] or ["once", "deny"]
        if "deny" not in choices:
            choices.append("deny")
        return await self._deliver_approval(
            prompt.chat_id, str(prompt.command or ""), prompt.session_key, str(getattr(prompt, "description", "") or ""), choices
        )

    async def send_slash_confirm(
        self,
        chat_id: str,
        title: str,
        message: str,
        session_key: str,
        confirm_id: str,
        metadata: dict[str, Any] | None = None,
        **_: Any,
    ) -> SendResult:
        """`/new`, `/reset`, `/undo`, `/reload-mcp`, `/model` ... ask before they run: the phone's approval
        sheet (Approve once / Deny), answered through tools.slash_confirm like other button platforms."""
        description = "\n".join(line for line in str(message).splitlines() if "/approve" not in line).strip()
        return await self._deliver_approval(
            chat_id, str(title), session_key, description, ["once", "deny"], confirm_id=str(confirm_id)
        )

    async def _deliver_approval(
        self,
        chat_id: str,
        command: str,
        session_key: str,
        description: str,
        choices: list[str],
        confirm_id: str | None = None,
    ) -> SendResult:
        """Anything that fails is denied (or cancelled) here rather than returned as a failure, which
        would make Hermes fall back to a typed `/approve` prompt."""
        self._expire_approvals()
        request_id = secrets.token_urlsafe(16)
        ttl = _approval_ttl()
        hermes_id = None if confirm_id else self._shown_hermes_request(session_key)
        self._approvals[request_id] = _Pending(session_key, time.monotonic() + ttl, hermes_id, confirm_id)
        status = "error"
        if self._http is not None:
            try:
                body = {
                    "request_id": request_id,
                    "command": command,
                    "description": description,
                    "choices": choices,
                    "ttl": int(ttl),
                }
                result = await _post(self._http, "/v1/chat/approvals", body, timeout=APPROVAL_POST_TIMEOUT)
                status = result.get("status", "error")
            except httpx.HTTPError as exc:
                log.warning("hermes_call: approval not delivered (%s)", exc.__class__.__name__)
        if status != "sent":
            self._approvals.pop(request_id, None)
            if confirm_id is None:
                _resolve(session_key, "deny", hermes_id)
                await self.send(chat_id, "I could not show that approval on your phone, so the command was denied.")
            else:
                await _resolve_confirm(session_key, confirm_id, "cancel")
                await self.send(chat_id, f"I could not show that confirmation on your phone, so {command} was cancelled.")
        return SendResult(success=True, message_id=request_id)

    def _shown_hermes_request(self, session_key: str) -> str | None:
        """Hermes queues a request before it notifies us, so the one being shown is the newest pending
        one we do not track yet. None on Hermes without request ids (before v0.21)."""
        try:
            from tools.approval import list_gateway_approvals

            pending = list_gateway_approvals(session_key)
        except Exception:
            return None
        tracked = {entry.hermes_id for entry in self._approvals.values()}
        ids = [str(item.get("request_id")) for item in pending if isinstance(item, dict) and item.get("request_id")]
        return next((rid for rid in reversed(ids) if rid not in tracked), None)


def _approval_ttl() -> float:
    """How long the phone shows an approval: Hermes' own approval timeout, minus a margin."""
    timeout = DEFAULT_APPROVAL_TIMEOUT
    for module in ("tools.approval_context", "tools.approval"):  # v0.21; before
        try:
            timeout = float(importlib.import_module(module)._get_approval_timeout())
        except Exception:
            log.debug("hermes_call: no approval timeout in %s", module)
        else:
            break
    return max(timeout - APPROVAL_MARGIN, MIN_APPROVAL_TTL)


def _resolve(session_key: str, choice: str, request_id: str | None = None) -> None:
    """Resolves exactly `request_id` where Hermes supports it; without one Hermes takes its oldest."""
    try:
        from tools.approval import resolve_gateway_approval

        if request_id and "request_id" in inspect.signature(resolve_gateway_approval).parameters:
            resolve_gateway_approval(session_key, choice, request_id=request_id)
        else:
            resolve_gateway_approval(session_key, choice)
    except Exception:  # a Hermes internal: log it, never let it kill the poll loop
        log.exception("hermes_call: could not resolve an approval")


async def _resolve_confirm(session_key: str, confirm_id: str, choice: str) -> str | None:
    """Runs (or cancels) a pending slash command; returns Hermes' reply for the chat."""
    try:
        from tools.slash_confirm import resolve

        return await resolve(session_key, confirm_id, choice)
    except Exception:
        log.exception("hermes_call: could not resolve a slash-command confirmation")
        return None


# ---- registration helpers ----------------------------------------------------


def check_requirements() -> bool:
    return bool(_token())


def is_connected(config: Any) -> bool:
    return bool(_token())


def env_enablement() -> dict[str, Any] | None:
    if not _token():
        return None
    return {"home_channel": {"chat_id": CHAT_ID, "name": CHAT_NAME}}


async def standalone_send(
    pconfig: Any,
    chat_id: str,
    message: str,
    *,
    thread_id: str | None = None,
    media_files: list[str] | None = None,
    force_document: bool = False,
) -> dict[str, Any]:
    """`hermes send --to hermes_call`, cron delivery and send_message when no gateway runs in this process."""
    if not _token():
        return {"error": "HERMES_CALL_TOKEN is not set"}
    message_id = None
    try:
        async with _client() as client:
            if message and message.strip():
                for chunk in BasePlatformAdapter.truncate_message(message, MAX_MESSAGE_LENGTH):
                    message_id = (await _post(client, "/v1/chat/messages", {"text": chunk})).get("message_id")
            for path in media_files or []:
                kind = "file" if force_document else _kind_for(path)
                body = await asyncio.to_thread(_file_body, path, kind, None, None)
                message_id = (await _post(client, "/v1/chat/files", body)).get("message_id")
    except (ValueError, OSError) as exc:
        return {"error": f"hermes_call: {exc}"}
    except httpx.HTTPError as exc:
        return {"error": f"hermes_call: bridge unavailable ({exc.__class__.__name__})"}
    return {"success": True, "message_id": message_id}


def register(ctx: Any) -> None:
    # Only paired phones reach the bridge; a global GATEWAY_ALLOWED_USERS must not lock the owner out.
    os.environ.setdefault("HERMES_CALL_ALLOW_ALL_USERS", "true")
    os.environ.setdefault("HERMES_CALL_HOME_CHANNEL", CHAT_ID)
    ctx.register_platform(
        name=PLATFORM,
        label=CHAT_NAME,
        adapter_factory=HermesCallAdapter,
        check_fn=check_requirements,
        is_connected=is_connected,
        required_env=["HERMES_CALL_TOKEN"],
        install_hint="Run the hermes-call-bridge installer with --configure-hermes.",
        env_enablement_fn=env_enablement,
        cron_deliver_env_var="HERMES_CALL_HOME_CHANNEL",
        standalone_sender_fn=standalone_send,
        allow_all_env="HERMES_CALL_ALLOW_ALL_USERS",
        max_message_length=MAX_MESSAGE_LENGTH,
        platform_hint=PLATFORM_HINT,
        emoji="📱",
        pii_safe=True,
    )
