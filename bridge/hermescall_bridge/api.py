"""Local-only control API (127.0.0.1) used by the Hermes plugin and the CLI.

Route groups: calls and devices (admin token; `POST /v1/calls` also the Hermes token), chat and
tasks, phone context and presentations (Hermes token), and unauthenticated health/metrics
(`/healthz`, `/metrics`: states and counts only, loopback only like everything here).
"""

import hmac
import json
import logging
import sqlite3
from collections.abc import Awaitable, Callable

from aiohttp import web

from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .calls import MAX_FIRST_MESSAGE, MAX_REASON, CallManager
from .chat import ATTACHMENT_KINDS, MAX_TEXT, ChatService
from .devices import DeviceRegistry
from .health import HealthChecker
from .metrics import METRICS
from .phone import PhoneService
from .present import PresentService
from .tasks import TaskService

MAX_BODY = 16 * 1024 * 1024
MAX_FILE = 10 * 1024 * 1024
# The Hermes token may ring the phone and run the chat adapter, nothing else.
HERMES_ROUTES = {
    ("POST", "/v1/calls"),
    ("GET", "/v1/chat/events"),
    ("POST", "/v1/chat/messages"),
    ("POST", "/v1/chat/files"),
    ("POST", "/v1/chat/typing"),
    ("POST", "/v1/chat/approvals"),
    ("POST", "/v1/chat/progress"),
    ("POST", "/v1/phone/queries"),
    ("POST", "/v1/present"),
}
# Plus the attachments of owner messages: GET /v1/chat/files/<file id>.
HERMES_FILES = "/v1/chat/files/"
PUBLIC_ROUTES = {("GET", "/healthz"), ("GET", "/metrics")}

log = logging.getLogger(__name__)


def _error(status: type[web.HTTPException], message: str) -> web.HTTPException:
    return status(text=json.dumps({"error": message}), content_type="application/json")


def _matches(supplied: str, token: str) -> bool:
    return bool(token) and hmac.compare_digest(supplied.encode(), token.encode())


async def json_body(request: web.Request) -> dict:
    try:
        body = await request.json()
    except ValueError as exc:
        raise _error(web.HTTPBadRequest, "invalid json") from exc
    if not isinstance(body, dict):
        raise _error(web.HTTPBadRequest, "expected an object")
    return body


def text_field(body: dict, name: str, limit: int, required: bool = False) -> str:
    value = body.get(name, "")
    if not isinstance(value, str) or len(value) > limit or (required and not value.strip()):
        raise _error(web.HTTPBadRequest, f"{name}: {'required, ' if required else ''}string of at most {limit} chars")
    return value


def _auth_middleware(token: str, call_token: str):
    @web.middleware
    async def require_token(request: web.Request, handler):
        if (request.method, request.path) in PUBLIC_ROUTES:
            return await handler(request)
        supplied = request.headers.get("Authorization", "").removeprefix("Bearer ")
        if _matches(supplied, token):
            return await handler(request)
        if _matches(supplied, call_token):
            if (request.method, request.path) in HERMES_ROUTES or (
                request.method == "GET" and request.path.startswith(HERMES_FILES)
            ):
                return await handler(request)
            return web.json_response({"error": "forbidden"}, status=403)
        return web.json_response({"error": "unauthorized"}, status=401)

    return require_token


def add_call_routes(
    app: web.Application,
    calls: CallManager,
    devices: DeviceRegistry,
    status: Callable[[], dict],
    unpair: Callable[[str], Awaitable[bool]] | None,
) -> None:
    async def start_call(request: web.Request) -> web.Response:
        body = await json_body(request)
        reason, first, device = body.get("reason", ""), body.get("first_message", ""), body.get("device", "all")
        if not isinstance(reason, str) or not isinstance(first, str) or not isinstance(device, str):
            raise _error(web.HTTPBadRequest, "reason, first_message and device must be strings")
        if len(reason) > MAX_REASON or len(first) > MAX_FIRST_MESSAGE or not first.strip():
            raise _error(web.HTTPBadRequest, "first_message is required; reason ≤ 500, first_message ≤ 1000 chars")
        return web.json_response(await calls.ring(reason.strip(), first.strip(), device))

    async def list_devices(request: web.Request) -> web.Response:
        return web.json_response({"devices": [{"id": d.id, "name": d.name, "created": d.created} for d in devices.list()]})

    async def pair_device(request: web.Request) -> web.Response:
        name = (await json_body(request)).get("name", "iPhone")
        if not isinstance(name, str) or len(name) > 64:
            raise _error(web.HTTPBadRequest, "invalid name")
        invitation, invite = await devices.invite(name)
        return web.json_response({"slot": invitation.code.slot, "code": invitation.code.display(), "uri": invite.to_uri()})

    async def pairing_status(request: web.Request) -> web.Response:
        invitation = devices.invitation(request.match_info["slot"])
        if invitation is None:
            return web.json_response({"status": "closed"})
        if invitation.result.done():
            device = invitation.result.result()
            return web.json_response({"status": "paired", "device": {"id": device.id, "name": device.name}})
        return web.json_response({"status": "waiting"})

    async def revoke(request: web.Request) -> web.Response:
        device_id = request.match_info["device_id"]
        revoked = await unpair(device_id) if unpair is not None else await devices.revoke(device_id)
        if not revoked:
            raise _error(web.HTTPNotFound, "unknown device")
        return web.json_response({"revoked": device_id})

    async def get_status(request: web.Request) -> web.Response:
        return web.json_response(status())

    app.router.add_post("/v1/calls", start_call)
    app.router.add_get("/v1/devices", list_devices)
    app.router.add_post("/v1/devices/pairing", pair_device)
    app.router.add_get("/v1/devices/pairing/{slot}", pairing_status)
    app.router.add_delete("/v1/devices/{device_id}", revoke)
    app.router.add_get("/v1/status", get_status)


def add_chat_routes(app: web.Application, chat: ChatService) -> None:
    async def chat_events(request: web.Request) -> web.Response:
        try:
            cursor = int(request.query.get("cursor", "0"))
            wait = float(request.query.get("wait", "25"))
        except ValueError as exc:
            raise _error(web.HTTPBadRequest, "cursor and wait must be numbers") from exc
        epoch = request.query.get("epoch")
        files = request.query.get("files") == "1"
        cursor, events = await chat.poll(max(cursor, 0), max(0.0, wait), epoch[:64] if epoch else None, files)
        return web.json_response({"cursor": cursor, "events": events, "epoch": chat.epoch})

    async def chat_message(request: web.Request) -> web.Response:
        body = await json_body(request)
        text = text_field(body, "text", MAX_TEXT, required=True)
        reply_to, answers = body.get("reply_to"), body.get("answers")
        message_id = await chat.send_text(
            text.strip(),
            reply_to if isinstance(reply_to, str) and len(reply_to) <= 64 else None,
            answers=answers if isinstance(answers, str) and len(answers) <= 64 else None,
        )
        return web.json_response({"message_id": message_id, "queued": await chat.queued(message_id)})

    async def chat_file(request: web.Request) -> web.Response:
        body = await json_body(request)
        kind = body.get("kind", "file")
        if kind not in ATTACHMENT_KINDS:
            raise _error(web.HTTPBadRequest, "kind: photo, voice or file")
        try:
            data = wire.b64d(body.get("data"), max_length=MAX_FILE)
        except ProtocolError as exc:
            raise _error(web.HTTPBadRequest, "data: base64url, at most 10 MiB") from exc
        name, mime = text_field(body, "name", 200), text_field(body, "mime", 100)
        caption = text_field(body, "caption", MAX_TEXT)
        return web.json_response({"message_id": await chat.send_file(data, name, mime, kind, caption.strip())})

    async def chat_file_data(request: web.Request) -> web.Response:
        data = await chat.file_data(request.match_info["file_id"])
        if data is None:
            raise _error(web.HTTPNotFound, "unknown or expired file")
        return web.Response(body=data, content_type="application/octet-stream")

    async def chat_typing(request: web.Request) -> web.Response:
        await chat.typing()
        return web.json_response({"ok": True})

    async def chat_approval(request: web.Request) -> web.Response:
        body = await json_body(request)
        request_id = text_field(body, "request_id", 64, required=True)
        command = body.get("command", "")
        description = body.get("description", "")
        if not isinstance(command, str) or not isinstance(description, str):
            raise _error(web.HTTPBadRequest, "command and description must be strings")
        if not await chat.request_approval(request_id, command, description):
            return web.json_response({"status": "denied"})
        return web.json_response({"status": "sent"})

    app.router.add_get("/v1/chat/events", chat_events)
    app.router.add_post("/v1/chat/messages", chat_message)
    app.router.add_post("/v1/chat/files", chat_file)
    app.router.add_get("/v1/chat/files/{file_id}", chat_file_data)
    app.router.add_post("/v1/chat/typing", chat_typing)
    app.router.add_post("/v1/chat/approvals", chat_approval)


def add_agent_routes(
    app: web.Application, tasks: TaskService | None, phone: PhoneService | None, presenter: PresentService | None
) -> None:
    async def chat_progress(request: web.Request) -> web.Response:
        if tasks is None:
            raise _error(web.HTTPServiceUnavailable, "task progress is not available")
        body = await json_body(request)
        try:
            await tasks.progress(body)
        except ValueError as exc:
            raise _error(web.HTTPBadRequest, str(exc)) from exc
        return web.Response(status=204)

    async def phone_query(request: web.Request) -> web.Response:
        body = await json_body(request)
        try:
            result = await phone.query(body.get("capability"), body.get("reason"), body.get("params"))
        except ValueError as exc:
            raise _error(web.HTTPBadRequest, str(exc)) from exc
        return web.json_response(result)

    async def present(request: web.Request) -> web.Response:
        body = await json_body(request)
        try:
            return web.json_response(await presenter.present(body))
        except ValueError as exc:
            raise _error(web.HTTPBadRequest, str(exc)) from exc

    app.router.add_post("/v1/chat/progress", chat_progress)
    if phone is not None:
        app.router.add_post("/v1/phone/queries", phone_query)
    if presenter is not None:
        app.router.add_post("/v1/present", present)


def add_health_routes(app: web.Application, status: Callable[[], dict], health: HealthChecker | None) -> None:
    async def healthz(request: web.Request) -> web.Response:
        result = await health.check() if health is not None else {"ok": status()["connected"], "relay": status()["connected"]}
        return web.json_response(result, status=200 if result["ok"] else 503)

    async def metrics(request: web.Request) -> web.Response:
        if METRICS.refresh is not None:
            try:
                await METRICS.refresh()
            except (sqlite3.Error, RuntimeError) as exc:
                log.warning("metrics refresh failed: %s", exc.__class__.__name__)
        return web.Response(text=METRICS.render(), content_type="text/plain", charset="utf-8")

    app.router.add_get("/healthz", healthz)
    app.router.add_get("/metrics", metrics)


def build_app(
    token: str,
    calls: CallManager,
    devices: DeviceRegistry,
    status: Callable[[], dict],
    call_token: str = "",
    chat: ChatService | None = None,
    phone: PhoneService | None = None,
    presenter: PresentService | None = None,
    tasks: TaskService | None = None,
    unpair: Callable[[str], Awaitable[bool]] | None = None,
    health: HealthChecker | None = None,
) -> web.Application:
    """`token` may do everything; `call_token` (given to Hermes) may only ring the phone and chat."""
    app = web.Application(middlewares=[_auth_middleware(token, call_token)], client_max_size=MAX_BODY)
    add_call_routes(app, calls, devices, status, unpair)
    if chat is not None:
        add_chat_routes(app, chat)
    add_agent_routes(app, tasks, phone, presenter)
    add_health_routes(app, status, health)
    return app
