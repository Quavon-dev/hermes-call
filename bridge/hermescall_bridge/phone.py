"""Phone context: the agent asks the owner's phones for information (docs/protocol.md, "Phone context").

The phone decides (No/Ask/Yes per capability); the bridge relays the query, validates the
answer and forgets it. Logs carry ids, capability and status only — never data.
"""

import asyncio
import contextlib
import json
import logging
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from hermescall_common import blobs, sodium, wire
from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel
from hermescall_common.errors import CryptoError, ProtocolError

from . import geofence, phone_write
from .chat import _clean_mime, _clean_name
from .state import Device, State
from .transport import Transport

log = logging.getLogger(__name__)

MAX_REASON = 300
MAX_DATA = 16 * 1024
TTL_MS = 60_000
PICKER_TTL_MS = 120_000
GRACE_MS = 10_000
MAX_OPEN = 2
QUERY_LIMITS = ((600.0, 20), (86_400.0, 100))
ANSWER_STATUSES = ("ok", "denied", "unavailable", "timeout")
PICKERS = ("photos", "files")
FILE_KEYS = frozenset({"blob_id", "key", "name", "mime"})

# capability → top-level keys allowed in `data` of an `ok` answer
DATA_KEYS: dict[str, frozenset[str]] = {
    "location": frozenset({"lat", "lon", "accuracy_m", "time", "place"}),
    "battery": frozenset({"level", "state", "low_power"}),
    "device": frozenset({"model", "system", "network", "expensive", "storage_free_gb", "thermal", "timezone", "locale"}),
    "calendar": frozenset({"events"}),
    "reminders": frozenset({"reminders"}),
    "contacts": frozenset({"contacts"}),
    "motion": frozenset({"activity", "confidence", "steps_today", "distance_today_m"}),
    "focus": frozenset({"focused"}),
    "now_playing": frozenset({"playing", "title", "artist", "album"}),
    "health": frozenset({"steps_today", "active_energy_kcal_today", "sleep_hours_last_night", "resting_heart_rate"}),
    "home": frozenset({"homes"}),
    "clipboard": frozenset({"text", "has_text"}),
    "photos": frozenset({"files"}),
    "files": frozenset({"files"}),
    "geofence": frozenset({"id", "resolved_name", "removed", "reminders"}),
    "reminder_create": phone_write.ANSWER_KEYS,
    "calendar_create": phone_write.ANSWER_KEYS,
}
CAPABILITIES = tuple(DATA_KEYS)
# With several phones, an `ok` from a phone that was not the most recently active one waits this
# long for that phone's answer (the owner is probably holding it).
PREFER_WAIT = 3.0


def _int_param(params: dict, name: str, low: int, high: int, default: int) -> int:
    value = params.get(name, default)
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError(f"params.{name}: integer {low}–{high}")
    return value


def parse_params(capability: str, params: object) -> dict[str, Any]:
    """Checks `params` against the capability table and fills in defaults. Raises ValueError."""
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    if capability == "geofence":
        return geofence.parse_params(params)
    if capability in phone_write.WRITE_CAPABILITIES:
        return phone_write.parse_params(capability, params)
    allowed: dict[str, tuple[str, ...]] = {
        "location": ("accuracy",),
        "calendar": ("days", "limit"),
        "reminders": ("limit",),
        "contacts": ("name",),
        "photos": ("max",),
        "files": ("max",),
    }
    unknown = set(params) - set(allowed.get(capability, ()))
    if unknown:
        raise ValueError(f"params not allowed for {capability}: {', '.join(sorted(unknown))}")
    if capability == "location":
        accuracy = params.get("accuracy", "approximate")
        if accuracy not in ("approximate", "precise"):
            raise ValueError("params.accuracy: approximate or precise")
        return {"accuracy": accuracy}
    if capability == "calendar":
        return {"days": _int_param(params, "days", 1, 14, 1), "limit": _int_param(params, "limit", 1, 25, 10)}
    if capability == "reminders":
        return {"limit": _int_param(params, "limit", 1, 30, 15)}
    if capability == "contacts":
        name = params.get("name")
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 100:
            raise ValueError("params.name: required, 1–100 chars")
        return {"name": name.strip()}
    if capability in PICKERS:
        return {"max": _int_param(params, "max", 1, 4, 1)}
    return {}


@dataclass(frozen=True)
class FileRef:
    blob_id: str
    key: bytes
    name: str
    mime: str


def _file_refs(raw: object, limit: int) -> list[FileRef]:
    if not isinstance(raw, list) or len(raw) > limit:
        raise ProtocolError("invalid files")
    refs = []
    for item in raw:
        if not isinstance(item, dict) or not set(item) <= FILE_KEYS:
            raise ProtocolError("invalid file")
        blob_id = item.get("blob_id")
        wire.b64d(blob_id, length=16)
        key = wire.b64d(item.get("key"), length=32)
        refs.append(FileRef(blob_id, key, _clean_name(item.get("name"), "file"), _clean_mime(item.get("mime"))))
    return refs


def check_data(capability: str, params: dict, data: object) -> tuple[dict, list[FileRef]]:
    """Only the listed top-level keys, ≤ 16 KiB of JSON; raises ProtocolError otherwise."""
    if not isinstance(data, dict) or not set(data) <= DATA_KEYS[capability]:
        raise ProtocolError("invalid data")
    if len(json.dumps(data, separators=(",", ":")).encode()) > MAX_DATA:
        raise ProtocolError("data too large")
    if capability in PICKERS:
        return {}, _file_refs(data.get("files", []), params["max"])
    if capability == "contacts" and (not isinstance(data.get("contacts", []), list) or len(data.get("contacts", [])) > 5):
        raise ProtocolError("too many contacts")
    if capability == "clipboard" and len(str(data.get("text", ""))) > 8000:
        raise ProtocolError("clipboard text too long")
    if capability == "geofence":
        return geofence.check_data(params, data), []
    if capability in phone_write.WRITE_CAPABILITIES:
        return phone_write.check_data(data), []
    return data, []


@dataclass
class Query:
    query_id: str
    capability: str
    params: dict[str, Any]
    targets: set[str]
    expires: int
    answers: dict[str, str] = field(default_factory=dict)
    outcome: asyncio.Future = field(default_factory=lambda: asyncio.get_running_loop().create_future())
    preferred: str | None = None
    # an `ok` from another phone, held back briefly for the preferred phone's answer
    candidate: tuple[dict, list] | None = None
    fallback: asyncio.TimerHandle | None = None


class PhoneService:
    def __init__(self, state: State, relay: RelaySession, channel: Channel) -> None:
        self._state = state
        self._relay = relay
        self._channel = channel
        self._transport = Transport(state, relay, channel)
        # device id → monotonic time of its last message (set by the daemon from the call manager)
        self.recent_activity: Callable[[str], float] | None = None
        self._open: dict[str, Query] = {}
        self._times: deque[float] = deque(maxlen=max(n for _, n in QUERY_LIMITS))
        self.ttl_ms, self.picker_ttl_ms, self.grace_ms = TTL_MS, PICKER_TTL_MS, GRACE_MS

    # ---- local API -------------------------------------------------------

    async def query(self, capability: object, reason: object, params: object = None) -> dict[str, Any]:
        """Asks every paired phone and waits for the outcome. Raises ValueError for bad input."""
        if capability not in DATA_KEYS:
            raise ValueError(f"capability: one of {', '.join(CAPABILITIES)}")
        if not isinstance(reason, str) or not 1 <= len(reason.strip()) <= MAX_REASON:
            raise ValueError(f"reason: required, 1–{MAX_REASON} chars")
        params = parse_params(capability, params)
        preferred = self._most_recent(set(self._state.devices))
        targets = set(self._state.devices)
        if capability in phone_write.WRITE_CAPABILITIES and preferred is not None:
            targets = {preferred}  # a write happens on one phone only
        if not targets:
            return {"status": "no_devices"}
        if len(self._open) >= MAX_OPEN:
            return {"status": "busy"}
        now = time.monotonic()
        if any(sum(now - t < window for t in self._times) >= limit for window, limit in QUERY_LIMITS):
            return {"status": "rate_limited"}
        self._times.append(now)
        ttl = self.picker_ttl_ms if capability in PICKERS else self.ttl_ms
        query = Query(wire.b64e(sodium.random_bytes(16)), capability, params, targets, int(time.time() * 1000) + ttl)
        if len(targets) > 1 and capability not in PICKERS:
            query.preferred = preferred
        self._open[query.query_id] = query
        try:
            result = await self._ask(query, reason.strip(), (ttl + self.grace_ms) / 1000)
        finally:
            self._open.pop(query.query_id, None)
            for device_id in query.targets:
                await self._live(device_id, {"type": "query_done", "query_id": query.query_id})
        log.info("phone query %s %s: %s", query.query_id[:6], capability, result["status"])
        return result

    async def _ask(self, query: Query, reason: str, wait: float) -> dict[str, Any]:
        body = {
            "type": "phone_query",
            "query_id": query.query_id,
            "capability": query.capability,
            "params": query.params,
            "reason": reason,
            "expires": query.expires,
        }
        for device_id in list(query.targets):
            if not await self._mail(device_id, body):
                self._drop(query, device_id)
        try:
            data, files = await asyncio.wait_for(asyncio.shield(query.outcome), wait)
        except TimeoutError:
            return {"status": self._verdict(query)}
        if data is None:
            return {"status": self._verdict(query)}
        if query.capability not in PICKERS:
            return {"status": "ok", "data": data}
        loaded = await self._download(files)
        if files and not loaded:
            return {"status": "unavailable"}
        return {"status": "ok", "files": loaded}

    @staticmethod
    def _verdict(query: Query) -> str:
        for status in ("denied", "unavailable"):
            if status in query.answers.values():
                return status
        return "timeout"

    async def _download(self, files: list[FileRef]) -> list[dict[str, str]]:
        loaded = []
        for ref in files:
            try:
                data = blobs.open_sealed(ref.key, await blobs.download(self._relay, ref.blob_id))
                loaded.append({"name": ref.name, "mime": ref.mime, "data": wire.b64e(data)})
            except (ProtocolError, CryptoError, OSError, TimeoutError) as exc:
                log.warning("picked file unavailable: %s", exc.__class__.__name__)
            finally:
                await self._delete(ref.blob_id)
        return loaded

    # ---- phones → bridge -------------------------------------------------

    async def on_answer(self, device: Device, body: dict[str, Any]) -> None:
        if "mid" not in body:
            raise ProtocolError("phone answers need a mailbox envelope")
        query = self._open.get(body.get("query_id")) if isinstance(body.get("query_id"), str) else None
        late = query is None or int(time.time() * 1000) > query.expires + self.grace_ms
        if late or device.id not in query.targets or query.outcome.done() or device.id in query.answers:
            await self._discard(body.get("data"))  # picked files nobody will fetch
            return
        status = body.get("status") if body.get("status") in ANSWER_STATUSES else "unavailable"
        if status == "ok":
            try:
                data, files = check_data(query.capability, query.params, body.get("data"))
            except ProtocolError as exc:
                log.warning("phone answer %s from %s rejected: %s", query.query_id[:6], device.id[:6], exc)
                await self._discard(body.get("data"))
                status = "unavailable"
            else:
                query.answers[device.id] = "ok"
                self._accept_ok(query, device.id, (data, files))
                return
        query.answers[device.id] = status
        self._settle(query)

    def _most_recent(self, device_ids: set[str]) -> str | None:
        """The phone that sent the newest message (None: no phone has been active since the start)."""
        if self.recent_activity is None or not device_ids:
            return None
        times = {device_id: self.recent_activity(device_id) for device_id in device_ids}
        best = max(sorted(times), key=lambda d: times[d])
        return best if times[best] > float("-inf") else None

    def _accept_ok(self, query: Query, device_id: str, result: tuple[dict, list]) -> None:
        """The most recently active phone's `ok` wins; another phone's `ok` waits PREFER_WAIT for it."""
        if query.preferred is None or device_id == query.preferred:
            self._resolve(query, result)
            return
        if query.candidate is None:
            query.candidate = result
            query.fallback = asyncio.get_running_loop().call_later(PREFER_WAIT, self._resolve, query, result)
        if query.preferred in query.answers:
            self._resolve(query, query.candidate)

    def _resolve(self, query: Query, result: tuple[dict, list]) -> None:
        if query.fallback is not None:
            query.fallback.cancel()
        if not query.outcome.done():
            query.outcome.set_result(result)

    def _settle(self, query: Query) -> None:
        if query.outcome.done():
            return
        if query.candidate is not None and (query.preferred in query.answers or set(query.answers) >= query.targets):
            self._resolve(query, query.candidate)
        elif set(query.answers) >= query.targets:
            query.outcome.set_result((None, []))

    def _drop(self, query: Query, device_id: str) -> None:
        """A phone that cannot be asked (mail failed, unpaired) counts as `unavailable`."""
        query.answers.setdefault(device_id, "unavailable")
        self._settle(query)

    def forget_device(self, device_id: str) -> None:
        for query in list(self._open.values()):
            if device_id in query.targets:
                self._drop(query, device_id)

    async def _discard(self, data: object) -> None:
        """Blobs of an answer that is not used are deleted at once (the relay quota is small)."""
        files = data.get("files") if isinstance(data, dict) else None
        for item in files[:8] if isinstance(files, list) else ():
            blob_id = item.get("blob_id") if isinstance(item, dict) else None
            with contextlib.suppress(ProtocolError):
                wire.b64d(blob_id, length=16)
                await self._delete(blob_id)

    # ---- transport -------------------------------------------------------

    async def _delete(self, blob_id: str) -> None:
        with contextlib.suppress(ProtocolError, TimeoutError):
            await blobs.delete(self._relay, blob_id)

    async def _mail(self, device_id: str, body: dict[str, Any]) -> bool:
        """One attempt only: a query is useless after it expires, so it never waits in an outbox."""
        return await self._transport.mail(device_id, body, alert=True)

    async def _live(self, device_id: str, body: dict[str, Any]) -> None:
        await self._transport.live(device_id, body)
