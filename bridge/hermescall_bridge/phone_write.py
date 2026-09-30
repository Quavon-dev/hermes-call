"""Phone write capabilities: `reminder_create` and `calendar_create` (No/Ask on the phone, No by default).

A write goes to one phone only (the most recently active one), so a reminder is never created
twice; the answer carries only `{ok: true, id}`.
"""

import datetime
from typing import Any

from hermescall_common.errors import ProtocolError

WRITE_CAPABILITIES = ("reminder_create", "calendar_create")
MAX_TITLE = 200
MAX_NOTES = 1000
MAX_LOCATION = 200
MAX_ID = 200
MAX_EVENT = datetime.timedelta(days=14)
PARAM_KEYS = {
    "reminder_create": frozenset({"title", "due", "notes"}),
    "calendar_create": frozenset({"title", "start", "end", "location", "notes"}),
}
ANSWER_KEYS = frozenset({"ok", "id"})


def _text(params: dict, name: str, limit: int, required: bool = False) -> str | None:
    value = params.get(name)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
        raise ValueError(f"params.{name}: {'required, ' if required else ''}1–{limit} chars")
    return value.strip()


def _time(params: dict, name: str, required: bool = False) -> datetime.datetime | None:
    value = params.get(name)
    if value is None and not required:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value) if isinstance(value, str) and len(value) <= 40 else None
    except ValueError:
        parsed = None
    if parsed is None or parsed.tzinfo is None:
        raise ValueError(f"params.{name}: {'required, ' if required else ''}ISO 8601 date-time with offset")
    return parsed


def parse_params(capability: str, params: dict) -> dict[str, Any]:
    unknown = set(params) - PARAM_KEYS[capability]
    if unknown:
        raise ValueError(f"params not allowed for {capability}: {', '.join(sorted(unknown))}")
    out: dict[str, Any] = {"title": _text(params, "title", MAX_TITLE, required=True)}
    if notes := _text(params, "notes", MAX_NOTES):
        out["notes"] = notes
    if capability == "reminder_create":
        if (due := _time(params, "due")) is not None:
            out["due"] = due.isoformat()
        return out
    start, end = _time(params, "start", required=True), _time(params, "end", required=True)
    if not start < end <= start + MAX_EVENT:
        raise ValueError("params.end: after start, at most 14 days later")
    out.update(start=start.isoformat(), end=end.isoformat())
    if location := _text(params, "location", MAX_LOCATION):
        out["location"] = location
    return out


def check_data(data: dict) -> dict[str, Any]:
    """`{ok: true, id}` only."""
    if set(data) != ANSWER_KEYS or data.get("ok") is not True:
        raise ProtocolError("invalid write answer")
    item_id = data.get("id")
    if not isinstance(item_id, str) or not 0 < len(item_id) <= MAX_ID:
        raise ProtocolError("invalid write answer id")
    return {"ok": True, "id": item_id}
