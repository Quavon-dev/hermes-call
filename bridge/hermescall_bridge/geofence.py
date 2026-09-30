"""Place reminders (`geofence` phone capability, M9 §3): parameters and answer checks.

The phone watches the place itself (CLMonitor) and fires a local notification. The agent only
learns an id and the resolved place name — never where the phone is.
"""

import math
from typing import Any

from hermescall_common.errors import ProtocolError

ACTIONS = ("add", "remove", "list")
TRIGGERS = ("enter", "exit")
MAX_ID = 64
MAX_TITLE = 120
MAX_NOTE = 500
MAX_QUERY = 120
MAX_PLACE_NAME = 200
MIN_RADIUS, MAX_RADIUS, DEFAULT_RADIUS = 100, 2000, 200
MAX_REMINDERS = 20
PARAM_KEYS = {
    "add": frozenset({"action", "id", "title", "note", "place", "trigger", "repeat"}),
    "remove": frozenset({"action", "id"}),
    "list": frozenset({"action"}),
}
ANSWER_KEYS = {"add": frozenset({"id", "resolved_name"}), "remove": frozenset({"removed"}), "list": frozenset({"reminders"})}
REMINDER_KEYS = frozenset({"id", "title", "place_name", "trigger", "repeat"})


def _string(params: dict, name: str, limit: int, required: bool) -> str | None:
    value = params.get(name)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
        raise ValueError(f"params.{name}: {'required, ' if required else ''}1–{limit} chars")
    return value.strip()


def _coordinate(value: object, name: str, limit: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value) > limit:
        raise ValueError(f"params.place.{name}: number between -{limit:g} and {limit:g}")
    return value


def _place(raw: object) -> dict[str, Any]:
    if isinstance(raw, dict) and set(raw) == {"query"}:
        return {"query": _string(raw, "query", MAX_QUERY, required=True)}
    if not isinstance(raw, dict) or not {"lat", "lon"} <= set(raw) or set(raw) - {"lat", "lon", "radius_m"}:
        raise ValueError("params.place: required, {lat, lon, radius_m?} or {query}")
    radius = raw.get("radius_m", DEFAULT_RADIUS)
    if isinstance(radius, bool) or not isinstance(radius, (int, float)) or not MIN_RADIUS <= radius <= MAX_RADIUS:
        raise ValueError(f"params.place.radius_m: {MIN_RADIUS}–{MAX_RADIUS} metres")
    return {"lat": _coordinate(raw["lat"], "lat", 90), "lon": _coordinate(raw["lon"], "lon", 180), "radius_m": radius}


def parse_params(params: dict) -> dict[str, Any]:
    """Checks and normalizes `geofence` params. Raises ValueError (HTTP 400)."""
    action = params.get("action")
    if action not in ACTIONS:
        raise ValueError("params.action: add, remove or list")
    unknown = set(params) - PARAM_KEYS[action]
    if unknown:
        raise ValueError(f"params not allowed for geofence {action}: {', '.join(sorted(unknown))}")
    if action == "list":
        return {"action": "list"}
    if action == "remove":
        return {"action": "remove", "id": _string(params, "id", MAX_ID, required=True)}
    trigger = params.get("trigger", "enter")
    if trigger not in TRIGGERS:
        raise ValueError("params.trigger: enter or exit")
    repeat = params.get("repeat", False)
    if not isinstance(repeat, bool):
        raise ValueError("params.repeat: boolean")
    result: dict[str, Any] = {"action": "add"}
    if (reminder_id := _string(params, "id", MAX_ID, required=False)) is not None:
        result["id"] = reminder_id
    result["title"] = _string(params, "title", MAX_TITLE, required=True)
    if (note := _string(params, "note", MAX_NOTE, required=False)) is not None:
        result["note"] = note
    if "place" not in params:
        raise ValueError("params.place: required, {lat, lon, radius_m?} or {query}")
    result.update({"place": _place(params["place"]), "trigger": trigger, "repeat": repeat})
    return result


def _text(value: object, limit: int, required: bool = True) -> bool:
    return (value is None and not required) or (isinstance(value, str) and len(value) <= limit and (bool(value) or not required))


def check_data(params: dict, data: dict) -> dict:
    """The answer carries exactly what the action returns (never coordinates). Raises ProtocolError."""
    action = params["action"]
    if set(data) - ANSWER_KEYS[action]:
        raise ProtocolError("invalid geofence answer")
    if action == "add" and _text(data.get("id"), MAX_ID) and _text(data.get("resolved_name"), MAX_PLACE_NAME, False):
        return data
    if action == "remove" and isinstance(data.get("removed"), bool):
        return data
    if action == "list":
        reminders = data.get("reminders")
        if isinstance(reminders, list) and len(reminders) <= MAX_REMINDERS and all(map(_reminder_ok, reminders)):
            return data
    raise ProtocolError("invalid geofence answer")


def _reminder_ok(item: object) -> bool:
    return (
        isinstance(item, dict)
        and not set(item) - REMINDER_KEYS
        and _text(item.get("id"), MAX_ID)
        and _text(item.get("title"), MAX_TITLE)
        and _text(item.get("place_name"), MAX_PLACE_NAME, required=False)
        and item.get("trigger") in TRIGGERS
        and isinstance(item.get("repeat"), bool)
    )
