"""End-to-end encrypted signaling between a bridge and its devices.

Envelope: crypto_box(json) from sender X25519 to recipient X25519 (mutually
authenticated). The plaintext names sender and recipient and carries a strictly
increasing millisecond timestamp, so the relay can neither reflect, redirect
nor replay messages.

Chat messages may arrive days late (relay mailbox, app retries), so they carry
a message id `mid` instead: accepted once within `MAIL_WINDOW_MS`, in any order.
"""

import json
import time
from collections.abc import Callable
from typing import Any

from . import sodium, wire
from .errors import CryptoError, ProtocolError

MAX_SKEW_MS = 120_000
MAX_PLAINTEXT = 40 * 1024
# Longer than the relay mailbox keeps messages (7 days).
MAIL_WINDOW_MS = 8 * 86_400_000
MAX_SEEN_MAIL = 20_000


class Channel:
    """`seen`/`on_seen` let the owner persist each peer's newest timestamp, so a restart does not
    reopen the replay window."""

    def __init__(
        self,
        my_id: str,
        my_box_sk: bytes,
        seen: dict[str, int] | None = None,
        on_seen: Callable[[dict[str, int]], None] | None = None,
        seen_mail: dict[str, int] | None = None,
        on_seen_mail: Callable[[dict[str, int]], None] | None = None,
    ) -> None:
        self.my_id = my_id
        self._sk = my_box_sk
        self._last_sent = 0
        self._last_seen: dict[str, int] = dict(seen or {})
        self._on_seen = on_seen
        self._seen_mail: dict[str, int] = dict(seen_mail or {})
        self._on_seen_mail = on_seen_mail

    def seal(self, to_id: str, to_pk: bytes, body: dict[str, Any], mid: str | None = None) -> str:
        """`mid` (16 random bytes, base64url) marks a mailbox message, see the module docstring."""
        if not isinstance(body.get("type"), str):
            raise ProtocolError("message needs a type")
        self._last_sent = max(int(time.time() * 1000), self._last_sent + 1)
        envelope = {**body, "from": self.my_id, "to": to_id, "ts": self._last_sent}
        if mid is not None:
            wire.b64d(mid, length=16)
            envelope["mid"] = mid
        plaintext = json.dumps(envelope, separators=(",", ":"))
        if len(plaintext) > MAX_PLAINTEXT:
            raise ProtocolError("message too large")
        return wire.b64e(sodium.box_seal(plaintext.encode(), to_pk, self._sk))

    def open(self, from_id: str, from_pk: bytes, data: str) -> dict[str, Any]:
        try:
            body = json.loads(sodium.box_open(wire.b64d(data), from_pk, self._sk))
        except (CryptoError, ValueError) as exc:
            raise ProtocolError("undecryptable message") from exc
        ts = body.get("ts") if isinstance(body, dict) else None
        if (
            not isinstance(ts, int)
            or body.get("from") != from_id
            or body.get("to") != self.my_id
            or not isinstance(body.get("type"), str)
        ):
            raise ProtocolError("invalid envelope")
        if "mid" in body:
            self._accept_mail(body, ts)
            return body
        if abs(ts - int(time.time() * 1000)) > MAX_SKEW_MS or ts <= self._last_seen.get(from_id, 0):
            raise ProtocolError("stale or replayed message")
        self._last_seen[from_id] = ts
        if self._on_seen is not None:
            self._on_seen(dict(self._last_seen))
        return body

    def _accept_mail(self, body: dict[str, Any], ts: int) -> None:
        mid = body["mid"]
        wire.b64d(mid, length=16)
        now = int(time.time() * 1000)
        # Key "" holds the newest timestamp ever evicted: nothing at or below it is accepted again.
        floor = max(now - MAIL_WINDOW_MS, self._seen_mail.get("", 0))
        if not floor < ts <= now + MAX_SKEW_MS or mid in self._seen_mail:
            raise ProtocolError("stale or replayed message")
        seen = {key: value for key, value in self._seen_mail.items() if key and value > now - MAIL_WINDOW_MS}
        seen[mid] = ts
        if len(seen) > MAX_SEEN_MAIL:
            ordered = sorted(seen.items(), key=lambda item: item[1])
            floor = max(floor, ordered[-MAX_SEEN_MAIL - 1][1])
            seen = dict(ordered[-MAX_SEEN_MAIL:])
        if floor > now - MAIL_WINDOW_MS:
            seen[""] = floor
        self._seen_mail = seen
        if self._on_seen_mail is not None:
            self._on_seen_mail(dict(seen))
