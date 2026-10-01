"""Hermes plugin for Hermes Call (hermes-call-bridge on this machine):

- tool `call_owner`: rings the owner's iPhone and talks by voice;
- tool `phone_context`: asks the owner's phone for location, calendar, photos, … (the owner decides);
- tool `present_to_owner`: shows structured results (places, links, lists) as cards in the app;
- platform `hermes_call`: chat with the owner in the app (adapter.py), so
  `send_message`, cron delivery and `hermes send --to hermes_call` reach the phone;
- hooks `pre_tool_call` / `post_tool_call`: tool progress of hermes_call chat turns goes to the
  phone's tasks ring and Live Activity (progress.py). This works with any
  `display.platforms.hermes_call.tool_progress` setting; no Hermes config change is needed.
"""

import base64
import binascii
import http.client
import importlib
import json
import logging
import os
import re
import shutil
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger(__name__)

DEFAULT_URL = "http://127.0.0.1:8765"
MIN_HERMES = "0.15"
# Hermes internals this plugin uses: (module, attribute or None) per feature. A missing one disables
# only that feature (with a warning) instead of breaking Hermes' startup.
FEATURES = {
    "chat platform": (("gateway.platforms.base", "BasePlatformAdapter"), ("gateway.config", "Platform")),
    "chat approvals": (("tools.approval", "resolve_gateway_approval"),),
    "task progress": (("gateway.session_context", "get_session_env"),),
    "tool previews": (("agent.display", "build_tool_preview"),),
}
# How often a waiting tool checks whether the owner interrupted the agent.
INTERRUPT_POLL = 0.5
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
MAX_REASON = 500
MAX_FIRST_MESSAGE = 1000
REQUEST_TIMEOUT = 90
PHONE_TIMEOUT = 200
TEMP_PREFIX = "hermes-call-"
TEMP_MAX_AGE = 24 * 3600
PRESENT_TIMEOUT = 60
MAX_QUERY_REASON = 300
CAPABILITIES = (
    "location",
    "battery",
    "device",
    "calendar",
    "reminders",
    "contacts",
    "motion",
    "focus",
    "now_playing",
    "health",
    "home",
    "clipboard",
    "photos",
    "files",
    "geofence",
    "reminder_create",
    "calendar_create",
)
STATUS_NOTES = {
    "denied": "The owner declined. This is final: do not ask again for this; continue without it.",
    "unavailable": "The phone cannot provide this (permission off or feature missing). Do not retry; continue without it.",
    "timeout": "Nobody answered in time. Do not retry in a loop; continue without it or ask the owner in chat.",
    "no_devices": "No phone is paired with Hermes Call.",
    "rate_limited": "Too many phone requests recently (20 per 10 minutes, 100 per day). Do not retry now.",
    "busy": "Two phone requests are already open. Wait for them before asking again.",
}

SCHEMA = {
    "name": "call_owner",
    "description": (
        "Phone your owner on their iPhone and talk to them by voice. Use it only when something needs their "
        "attention now (they asked you to call, an urgent result, a decision you cannot make alone), never for "
        "routine updates (send those as a hermes_call chat message instead). The phone rings for up to 45 seconds; "
        "this tool waits for the outcome. If they answer, you speak `first_message` and the conversation continues "
        "on the call in a separate phone session, which is told the `reason`. If they decline or do not answer, "
        "`first_message` is left for them as a chat message (`messaged: true`). Result status: answered, declined, "
        "no_answer, busy (already on a call or ringing), no_devices, or rate_limited (at most 3 rings per 10 minutes "
        "and 20 per day; do not retry)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "reason": {
                "type": "string",
                "description": "Why you are calling, with the facts needed to continue on the call (max 500 chars).",
            },
            "first_message": {
                "type": "string",
                "description": "The first sentence you say when they pick up, plain spoken English (max 1000 chars).",
            },
            "device": {
                "type": "string",
                "description": 'Paired device id to ring, or "all" (default).',
            },
        },
        "required": ["reason", "first_message"],
    },
}


PHONE_SCHEMA = {
    "name": "phone_context",
    "description": (
        "Ask your owner's iPhone for context: location, battery, device state, calendar, reminders, a contact, "
        "motion/activity, whether a Focus is on, now playing, health summary, HomeKit accessories, the clipboard, "
        "or photos/files the owner picks. The owner decides per capability in the app (No / Ask / Yes): with Ask "
        "the phone shows your `reason` and the owner allows or declines; many capabilities are off (No) by "
        "default. Ask only when the answer is really needed for the current task, one capability at a time, and "
        "give a short, honest reason (shown to the owner, max 300 chars). A `denied` or `unavailable` result is "
        "final: never retry it in a loop or rephrase to ask again; continue without the information. The tool waits "
        "for the answer (up to about 70 s, or 130 s for photos/files). Result: status ok (with `data`, or for "
        "photos/files `files`: [{path, name, mime, size}] saved in a private temporary directory; images can be "
        "analyzed with vision_analyze using the path), denied, unavailable, timeout, no_devices, rate_limited "
        "(20 per 10 minutes, 100 per day) or busy (two requests already open). "
        "geofence sets place reminders ('remind me when I'm at the supermarket'): the phone watches the place "
        "itself and fires a local notification there; the phone's location is never returned to you. Prefer "
        "coordinates you found with your web tools (place: {lat, lon, radius_m}); otherwise give a place query "
        "(place: {query}) that the phone resolves near the owner. Results: add → {id, resolved_name}; "
        "remove → {removed}; list → {reminders: [{id, title, place_name, trigger, repeat}]} (at most 20). "
        "reminder_create / calendar_create add a reminder or calendar event on the owner's phone (off by default; "
        "the owner confirms each one); only do this when the owner asked for it. Result: {ok, id}."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "capability": {
                "type": "string",
                "enum": list(CAPABILITIES),
                "description": (
                    "location: lat, lon, accuracy_m, time, place. battery: level 0–1, state, low_power. device: model, "
                    "system, network, storage, thermal state, timezone, locale. calendar: upcoming events. reminders: "
                    "open reminders. contacts: phones/emails of a named contact (≤ 5 matches). motion: current "
                    "activity, steps. focus: whether a Focus is on (never which). now_playing: current Apple Music "
                    "track. health: steps, active energy, sleep, resting heart rate. home: HomeKit accessories and "
                    "their state. clipboard: current clipboard text (always asks). photos/files: the owner picks "
                    "files to share (always asks). geofence: add, remove or list place reminders (see params). "
                    "reminder_create: create a reminder (title, due?, notes?). calendar_create: create an event "
                    "(title, start, end, location?, notes?)."
                ),
            },
            "reason": {
                "type": "string",
                "description": "Why you need it, in one short honest sentence shown to the owner (1–300 chars).",
            },
            "params": {
                "type": "object",
                "description": "Options for some capabilities only; omit otherwise.",
                "properties": {
                    "accuracy": {
                        "type": "string",
                        "enum": ["approximate", "precise"],
                        "description": "location: approximate (default, about 1 km) or precise. Prefer approximate.",
                    },
                    "days": {"type": "integer", "minimum": 1, "maximum": 14, "description": "calendar: days ahead (default 1)."},
                    "limit": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 30,
                        "description": "calendar: max events 1–25 (default 10); reminders: max reminders 1–30 (default 15).",
                    },
                    "name": {"type": "string", "description": "contacts (required): the name to search for, 1–100 chars."},
                    "max": {"type": "integer", "minimum": 1, "maximum": 4, "description": "photos/files: how many (default 1)."},
                    "action": {
                        "type": "string",
                        "enum": ["add", "remove", "list"],
                        "description": "geofence (required): add a reminder, remove one by id, or list them.",
                    },
                    "id": {"type": "string", "description": "geofence remove (required): the reminder id (≤ 64 chars)."},
                    "title": {
                        "type": "string",
                        "description": (
                            "geofence add (required): what to remind of, 1–120 chars; "
                            "reminder_create / calendar_create (required): 1–200 chars."
                        ),
                    },
                    "note": {"type": "string", "description": "geofence add: optional details, ≤ 500 chars."},
                    "place": {
                        "type": "object",
                        "description": (
                            "geofence add (required): either {lat, lon, radius_m} (radius 100–2000 m, default 200) "
                            "or {query} (1–120 chars, e.g. 'Rewe Schwabing'), resolved on the phone near the owner."
                        ),
                        "properties": {
                            "lat": {"type": "number", "minimum": -90, "maximum": 90},
                            "lon": {"type": "number", "minimum": -180, "maximum": 180},
                            "radius_m": {"type": "number", "minimum": 100, "maximum": 2000},
                            "query": {"type": "string"},
                        },
                        "additionalProperties": False,
                    },
                    "trigger": {
                        "type": "string",
                        "enum": ["enter", "exit"],
                        "description": "geofence add: remind when arriving (enter, default) or leaving (exit).",
                    },
                    "repeat": {"type": "boolean", "description": "geofence add: every time (true) or once (false, default)."},
                    "due": {
                        "type": "string",
                        "description": "reminder_create: due date-time, ISO 8601 with offset (e.g. 2026-10-01T09:00:00+02:00).",
                    },
                    "notes": {"type": "string", "description": "reminder_create / calendar_create: details, ≤ 1000 chars."},
                    "start": {"type": "string", "description": "calendar_create (required): start, ISO 8601 with offset."},
                    "end": {
                        "type": "string",
                        "description": "calendar_create (required): end, ISO 8601 with offset, after start, ≤ 14 days later.",
                    },
                    "location": {"type": "string", "description": "calendar_create: where, ≤ 200 chars."},
                },
                "additionalProperties": False,
            },
        },
        "required": ["capability", "reason"],
    },
}

_ACTION_SCHEMA = {
    "type": "object",
    "description": "Exactly one of url, tel or maps.",
    "properties": {
        "label": {"type": "string", "description": "Button text, 1–30 chars."},
        "url": {"type": "string", "description": "https:// link to open."},
        "tel": {"type": "string", "description": "Phone number to call: +, digits, spaces, -()/ (3–30 chars)."},
        "maps": {"type": "boolean", "description": "true: route there in Maps (the item needs lat and lon)."},
    },
    "required": ["label"],
}

PRESENT_SCHEMA = {
    "name": "present_to_owner",
    "description": (
        "Show structured results to your owner as a deck of cards in the Hermes Call app (also during a phone "
        "call, and kept in the chat): places, links or lists, each item with title, subtitle, detail, a link, an "
        "optional picture, coordinates and up to 3 buttons (open link, call a number, route in Maps). Use it "
        "for results the owner will want to look at or act on (restaurants nearby, search results, options to "
        "choose from), not for plain answers. Keep it short: at most 10 items, ideally 3–5. Only https:// links "
        "and image URLs; no HTML or Markdown (shown as plain text). Pictures are fetched by the bridge; ones that "
        "fail are left out. Result: message_id and the number of pictures loaded."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "Heading of the deck, 1–120 chars."},
            "kind": {"type": "string", "enum": ["places", "links", "list"], "description": "Default list."},
            "text": {"type": "string", "description": "Optional one-line summary (≤ 2000 chars), also the notification text."},
            "items": {
                "type": "array",
                "minItems": 1,
                "maxItems": 10,
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string", "description": "1–120 chars."},
                        "subtitle": {"type": "string", "description": "≤ 200 chars, e.g. 'Italian · 4.6 ★ · 350 m'."},
                        "detail": {"type": "string", "description": "≤ 600 chars."},
                        "url": {"type": "string", "description": "https:// link for the card (≤ 1000 chars)."},
                        "image_url": {"type": "string", "description": "https:// picture URL (≤ 1000 chars)."},
                        "lat": {"type": "number", "description": "Latitude; give lat and lon together."},
                        "lon": {"type": "number", "description": "Longitude; give lat and lon together."},
                        "actions": {"type": "array", "maxItems": 3, "items": _ACTION_SCHEMA},
                    },
                    "required": ["title"],
                },
            },
        },
        "required": ["title", "items"],
    },
}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs) -> None:
        return None


# The bearer token must reach only the local bridge: no proxies from the environment, no redirects.
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)


def bridge_url() -> str:
    url = os.environ.get("HERMES_CALL_URL", DEFAULT_URL).rstrip("/")
    try:
        parts = urllib.parse.urlsplit(url)
        valid = parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS and parts.port is not None
    except ValueError:
        valid = False
    if not valid or parts.username or parts.password or parts.path or parts.query or parts.fragment:
        raise ValueError("HERMES_CALL_URL must be a loopback http:// URL with a port")
    return url


def _error(message: str) -> str:
    return json.dumps({"success": False, "error": message})


class _BridgeError(Exception):
    pass


def probe_features() -> dict[str, bool]:
    """Which Hermes internals are importable here (see FEATURES)."""
    available = {}
    for feature, needs in FEATURES.items():
        ok = True
        for module_name, attribute in needs:
            try:
                module = importlib.import_module(module_name)
            except ImportError:
                ok = False
                break
            ok = ok and (attribute is None or hasattr(module, attribute))
        available[feature] = ok
    return available


def hermes_too_old() -> str | None:
    """The installed Hermes version if it is older than MIN_HERMES (plugin.yaml's requires_hermes is
    enforced only by Hermes v0.21+), else None (new enough, or not installed as a package)."""
    try:
        from importlib.metadata import PackageNotFoundError, version

        installed = version("hermes-agent")
    except (ImportError, PackageNotFoundError):
        return None
    parts = [int(p) for p in re.findall(r"\d+", installed)[:2]]
    return installed if parts < [int(p) for p in MIN_HERMES.split(".")] else None


def _interrupted() -> bool:
    """Whether the owner stopped the agent (Hermes' per-thread interrupt flag), if this Hermes has one."""
    try:
        from tools.interrupt import is_interrupted
    except ImportError:
        return False
    return bool(is_interrupted())


def _post(path: str, body: dict, timeout: float) -> dict:
    """Like _post_blocking, but a stopped agent turn does not wait for the answer.

    Hermes runs tool handlers synchronously on the agent's worker thread (an `is_async` handler is
    only run on a private event loop in that same thread), so the request runs in a helper thread
    and this thread polls Hermes' interrupt flag. The bridge finishes the request on its own."""
    result: dict = {}

    def run() -> None:
        try:
            result["value"] = _post_blocking(path, body, timeout)
        except _BridgeError as exc:
            result["error"] = exc

    worker = threading.Thread(target=run, name="hermes-call-request", daemon=True)
    worker.start()
    deadline = time.monotonic() + timeout + 5
    while worker.is_alive():
        worker.join(INTERRUPT_POLL)
        if worker.is_alive() and (_interrupted() or time.monotonic() > deadline):
            raise _BridgeError("interrupted: the request was abandoned (the bridge may still complete it)")
    if "error" in result:
        raise result["error"]
    return result["value"]


def _post_blocking(path: str, body: dict, timeout: float) -> dict:
    """POST to the local bridge with the Hermes token. Raises _BridgeError with a message for the agent."""
    token = os.environ.get("HERMES_CALL_TOKEN", "")
    if not token:
        raise _BridgeError("HERMES_CALL_TOKEN is not set; run the hermes-call-bridge installer with --configure-hermes")
    try:
        url = bridge_url()
    except ValueError as exc:
        raise _BridgeError(str(exc)) from exc
    try:
        request = urllib.request.Request(  # noqa: S310 - loopback http only (checked above)
            f"{url}{path}",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with _opener.open(request, timeout=timeout) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise _BridgeError("the bridge rejected the token") from exc
        if exc.code == 400:
            raise _BridgeError(f"invalid request: {_error_text(exc)}") from exc
        raise _BridgeError(f"the bridge answered HTTP {exc.code}") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise _BridgeError("cannot reach hermes-call-bridge on this machine; is it running?") from exc
    except ValueError as exc:
        raise _BridgeError("invalid response from hermes-call-bridge") from exc
    if not isinstance(result, dict):
        raise _BridgeError("invalid response from hermes-call-bridge")
    return result


def _error_text(exc: urllib.error.HTTPError) -> str:
    try:
        message = json.loads(exc.read(4096)).get("error")
    except (OSError, ValueError, AttributeError):
        message = None
    return message[:300] if isinstance(message, str) else "rejected"


def call_owner(params: dict, **kwargs) -> str:
    del kwargs
    reason, first = params.get("reason", ""), params.get("first_message", "")
    device = params.get("device") or "all"
    if not os.environ.get("HERMES_CALL_TOKEN"):
        return _error("HERMES_CALL_TOKEN is not set; run the hermes-call-bridge installer with --configure-hermes")
    if not all(isinstance(v, str) for v in (reason, first, device)):
        return _error("reason, first_message and device must be strings")
    reason, first = reason.strip()[:MAX_REASON], first.strip()[:MAX_FIRST_MESSAGE]
    if not first:
        return _error("first_message is required")
    try:
        result = _post("/v1/calls", {"reason": reason, "first_message": first, "device": device}, REQUEST_TIMEOUT)
    except _BridgeError as exc:
        return _error(str(exc))
    status = result.get("status")
    reply = {"success": status == "answered", "status": status}
    if result.get("messaged") is True:
        reply["messaged"] = True
    return json.dumps(reply)


def _safe_name(name: object, index: int) -> str:
    text = os.path.basename(name if isinstance(name, str) else "")
    text = re.sub(r"[^A-Za-z0-9._-]", "_", text).lstrip(".")[:100]
    return f"{index}-{text or 'file'}"


def _sweep_old_dirs() -> None:
    """Best effort: picked files from earlier requests do not pile up in the temp dir."""
    cutoff = time.time() - TEMP_MAX_AGE
    try:
        entries = list(os.scandir(tempfile.gettempdir()))
    except OSError:
        return
    for entry in entries:
        try:
            if (
                entry.name.startswith(TEMP_PREFIX)
                and entry.is_dir(follow_symlinks=False)
                and entry.stat(follow_symlinks=False).st_uid == os.getuid()
                and entry.stat(follow_symlinks=False).st_mtime < cutoff
            ):
                shutil.rmtree(entry.path, ignore_errors=True)
        except OSError:
            continue


def _save_files(files: object) -> list[dict]:
    """Picked photos/files → a private temp dir (0700, files 0600). The agent gets paths, never bytes."""
    if not isinstance(files, list):
        raise ValueError("invalid files")
    _sweep_old_dirs()
    directory = tempfile.mkdtemp(prefix=TEMP_PREFIX)
    try:
        os.chmod(directory, 0o700)
        return _write_files(directory, files)
    except (OSError, ValueError, binascii.Error):
        shutil.rmtree(directory, ignore_errors=True)
        raise


def _write_files(directory: str, files: list) -> list[dict]:
    saved = []
    for index, item in enumerate(files, 1):
        if not isinstance(item, dict) or not isinstance(item.get("data"), str):
            raise ValueError("invalid file")
        data = base64.urlsafe_b64decode(item["data"] + "=" * (-len(item["data"]) % 4))
        path = os.path.join(directory, _safe_name(item.get("name"), index))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        mime = item.get("mime") if isinstance(item.get("mime"), str) else "application/octet-stream"
        name = item.get("name") if isinstance(item.get("name"), str) else os.path.basename(path)
        saved.append({"path": path, "name": name[:200], "mime": mime[:100], "size": len(data)})
    return saved


def phone_context(params: dict, **kwargs) -> str:
    del kwargs
    capability, reason, options = params.get("capability"), params.get("reason", ""), params.get("params") or {}
    if not os.environ.get("HERMES_CALL_TOKEN"):
        return _error("HERMES_CALL_TOKEN is not set; run the hermes-call-bridge installer with --configure-hermes")
    if capability not in CAPABILITIES:
        return _error(f"capability must be one of: {', '.join(CAPABILITIES)}")
    if not isinstance(reason, str) or not reason.strip() or len(reason.strip()) > MAX_QUERY_REASON:
        return _error("reason is required (1–300 chars): tell the owner briefly and honestly why you need this")
    if not isinstance(options, dict):
        return _error("params must be an object")
    body = {"capability": capability, "reason": reason.strip(), "params": options}
    try:
        result = _post("/v1/phone/queries", body, PHONE_TIMEOUT)
    except _BridgeError as exc:
        return _error(str(exc))
    status = result.get("status")
    reply: dict = {"success": status == "ok", "status": status}
    if status != "ok":
        reply["note"] = STATUS_NOTES.get(status, "The phone did not provide this. Do not retry in a loop.")
    elif "files" in result:
        try:
            reply["files"] = _save_files(result["files"])
        except (OSError, ValueError, binascii.Error):
            return _error("could not store the files from the phone")
    else:
        reply["data"] = result.get("data")
    return json.dumps(reply)


def present_to_owner(params: dict, **kwargs) -> str:
    del kwargs
    if not os.environ.get("HERMES_CALL_TOKEN"):
        return _error("HERMES_CALL_TOKEN is not set; run the hermes-call-bridge installer with --configure-hermes")
    body = {key: params[key] for key in ("title", "kind", "text", "items") if params.get(key) is not None}
    try:
        result = _post("/v1/present", body, PRESENT_TIMEOUT)
    except _BridgeError as exc:
        return _error(str(exc))
    return json.dumps({"success": True, "message_id": result.get("message_id"), "images": result.get("images", 0)})


def register(ctx) -> None:
    if old := hermes_too_old():
        log.warning("hermes-call: needs Hermes >= %s, found %s; features Hermes lacks are disabled", MIN_HERMES, old)
    features = probe_features()
    for feature, ok in features.items():
        if not ok:
            log.warning(
                "hermes-call: this Hermes lacks what %s needs (Hermes >= %s expected); it is disabled", feature, MIN_HERMES
            )
    ctx.register_tool(
        name="call_owner",
        toolset="hermes_call",
        schema=SCHEMA,
        handler=call_owner,
        check_fn=lambda: bool(os.environ.get("HERMES_CALL_TOKEN")),
        requires_env=["HERMES_CALL_TOKEN"],
        emoji="📞",
    )
    for name, schema, handler, emoji in (
        ("phone_context", PHONE_SCHEMA, phone_context, "📱"),
        ("present_to_owner", PRESENT_SCHEMA, present_to_owner, "🗂️"),
    ):
        ctx.register_tool(
            name=name,
            toolset="hermes_call",
            schema=schema,
            handler=handler,
            check_fn=lambda: bool(os.environ.get("HERMES_CALL_TOKEN")),
            requires_env=["HERMES_CALL_TOKEN"],
            emoji=emoji,
        )
    if hasattr(ctx, "register_hook") and features["task progress"]:
        from . import progress

        ctx.register_hook("pre_tool_call", progress.on_pre_tool_call)
        ctx.register_hook("post_tool_call", progress.on_post_tool_call)
    if hasattr(ctx, "register_platform") and features["chat platform"] and features["chat approvals"]:
        from . import adapter

        adapter.register(ctx)
