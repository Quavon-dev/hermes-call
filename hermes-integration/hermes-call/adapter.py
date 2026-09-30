"""Hermes platform `hermes_call`: chat with the owner in the Hermes Call app.

The adapter talks only to the local hermes-call-bridge (loopback HTTP, the same
token as `call_owner`): it long-polls `/v1/chat/events` for the owner's
messages and posts replies, files and typing notices. The bridge encrypts
everything end to end for the owner's paired phones. Only paired phones can
reach the bridge, so the platform needs no user allow-list of its own.

Approvals for commands in chat sessions are shown on the phone and need Face
ID; typed `/approve` is refused on this platform.

Tool progress is not rendered as chat bubbles: the plugin's tool hooks (progress.py)
post it to the bridge, which shows it as the tasks ring and a Live Activity; this
adapter eats the tool chrome and reports when a turn ends.
"""

import asyncio
import base64
import logging
import mimetypes
import os
import secrets
import time
from pathlib import Path
from typing import Any

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
BACKOFF_SECONDS = (1, 2, 5, 10, 30)
TYPING_INTERVAL = 4.0
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


async def _post(client: httpx.AsyncClient, path: str, body: dict[str, Any]) -> dict[str, Any]:
    response = await client.post(path, json=body)
    response.raise_for_status()
    return response.json()


class HermesCallAdapter(BasePlatformAdapter):
    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: Any) -> None:
        super().__init__(config=config, platform=Platform(PLATFORM))
        self._http: httpx.AsyncClient | None = None
        self._poller: asyncio.Task | None = None
        self._cursor = 0
        self._approvals: dict[str, str] = {}
        self._last_typing = 0.0
        # The owner message being answered: its final reply carries `answers` (a voice note gets a spoken reply).
        self._answering: str | None = None

    @property
    def enforces_own_access_policy(self) -> bool:
        return True

    async def connect(self) -> bool:
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
            try:
                response = await self._http.get("/v1/chat/events", params={"cursor": self._cursor, "wait": POLL_WAIT_SECONDS})
                if response.status_code in (401, 403):
                    self._set_fatal_error("auth", "hermes-call-bridge rejected HERMES_CALL_TOKEN", retryable=False)
                    return
                response.raise_for_status()
                data = response.json()
                for event in data.get("events", []):
                    await self._dispatch(event)
                self._cursor = int(data.get("cursor", self._cursor))
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
            self._on_approval(event)

    async def _on_message(self, event: dict[str, Any]) -> None:
        text = str(event.get("text") or "")
        if text.strip().lower().startswith("/approve"):
            await self.send(CHAT_ID, "Approvals need Face ID: use the approval sheet in the app.")
            return
        media_urls, media_types = [], []
        for item in event.get("attachments") or []:
            try:
                data = _b64decode(item["data"])
                name = Path(str(item.get("name") or "file")).name
                if item.get("kind") == "photo":
                    media_urls.append(cache_image_from_bytes(data, Path(name).suffix.lower() or ".jpg"))
                else:
                    media_urls.append(cache_document_from_bytes(data, name))
                media_types.append(str(item.get("mime") or "application/octet-stream"))
            except (KeyError, ValueError, OSError) as exc:
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

    def _on_approval(self, event: dict[str, Any]) -> None:
        session_key = self._approvals.pop(str(event.get("request_id")), None)
        if session_key is None:
            return
        choice = "once" if event.get("choice") == "once" else "deny"
        _resolve(session_key, choice)

    # ---- tool progress (tasks ring / Live Activity on the phone) ---------------

    def format_tool_event(self, event: Any, *, mode: str = "all", preview_max_len: int = 40) -> str | None:
        """No tool chrome in the chat: progress reaches the phone through the tool hooks (progress.py)."""
        return None

    async def on_processing_start(self, event: MessageEvent) -> None:
        self._answering = str(event.message_id) if event.message_id else None

    async def on_processing_complete(self, event: MessageEvent, outcome: Any) -> None:
        """The reply for this owner message was sent (or the turn failed): the task ends."""
        if self._answering == event.message_id:
            self._answering = None
        turn_id = str(event.message_id or DEFAULT_TURN)[:MAX_TURN_ID]
        REPORTER.turn_ended(turn_id, failed=getattr(outcome, "value", outcome) == "failure")

    # ---- outbound ----------------------------------------------------------

    async def send(
        self, chat_id: str, content: str, reply_to: str | None = None, metadata: dict[str, Any] | None = None
    ) -> SendResult:
        if self._http is None:
            return SendResult(success=False, error="not connected", retryable=True)
        message_id = None
        # Hermes marks the final response of a turn with metadata notify=True (interim messages are unmarked).
        answers = self._answering if (metadata or {}).get("notify") is True else None
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
    ) -> SendResult:
        """Face ID sheet on the phone. Anything that fails is denied here rather than returned as a
        failure, which would make Hermes fall back to a typed `/approve` prompt."""
        request_id = secrets.token_urlsafe(16)
        self._approvals[request_id] = session_key
        status = "error"
        if self._http is not None:
            try:
                body = {"request_id": request_id, "command": command, "description": description}
                status = (await _post(self._http, "/v1/chat/approvals", body)).get("status", "error")
            except httpx.HTTPError as exc:
                log.warning("hermes_call: approval not delivered (%s)", exc.__class__.__name__)
        if status != "sent":
            self._approvals.pop(request_id, None)
            _resolve(session_key, "deny")
            await self.send(chat_id, "I could not show that approval on your phone, so the command was denied.")
        return SendResult(success=True, message_id=request_id)


def _resolve(session_key: str, choice: str) -> None:
    from tools.approval import resolve_gateway_approval

    resolve_gateway_approval(session_key, choice)


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
