# SPDX-License-Identifier: MIT
"""What each paired phone said about itself (E2E `hello`): protocol version, app version, caps.

The app sends `hello` after every relay connect; the bridge answers with its own. A phone that never
sent one (older apps) supports none of the optional features, so everything behaves as before.
Kept in memory only: the phone repeats it on the next connect.
"""

import logging
import re
from dataclasses import dataclass
from typing import Any

from .version import PROTOCOL_VERSION, VERSION

log = logging.getLogger(__name__)

# Optional features this bridge offers (docs/protocol.md, "App ↔ bridge versions").
BRIDGE_CAPS: tuple[str, ...] = ("unsupported", "call_resume", "history")
NAME = re.compile(r"[a-z0-9_]{1,32}")
MAX_CAPS = 32
MAX_APP_VERSION = 40


@dataclass(frozen=True)
class PeerInfo:
    v: int
    app: str
    caps: frozenset[str]


def valid_name(value: object) -> bool:
    return isinstance(value, str) and NAME.fullmatch(value) is not None


def parse_hello(body: dict[str, Any]) -> PeerInfo:
    """Lenient: bad fields are dropped, never an error (a newer app may send more)."""
    v = body.get("v")
    raw_caps = body.get("caps")
    caps = frozenset(c for c in raw_caps[:MAX_CAPS] if valid_name(c)) if isinstance(raw_caps, list) else frozenset()
    app = body.get("app")
    app_version = "".join(ch for ch in app if ch.isprintable())[:MAX_APP_VERSION] if isinstance(app, str) else ""
    return PeerInfo(v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 1, app_version, caps)


def hello_body() -> dict[str, Any]:
    return {"type": "hello", "v": PROTOCOL_VERSION, "bridge": VERSION, "caps": list(BRIDGE_CAPS)}


def unsupported_body(kind: object) -> dict[str, Any]:
    """The answer to an E2E type this bridge does not know; the name only when it is a valid one."""
    body: dict[str, Any] = {"type": "unsupported"}
    if valid_name(kind):
        body["unknown"] = kind
    return body


class Peers:
    def __init__(self) -> None:
        self._info: dict[str, PeerInfo] = {}

    def on_hello(self, device_id: str, body: dict[str, Any]) -> PeerInfo:
        info = parse_hello(body)
        if self._info.get(device_id) != info:
            caps = ",".join(sorted(info.caps))
            log.info("phone %s: protocol v%d, app %s, caps %s", device_id[:6], info.v, info.app or "?", caps)
        self._info[device_id] = info
        return info

    def info(self, device_id: str) -> PeerInfo | None:
        return self._info.get(device_id)

    def supports(self, device_id: str, cap: str) -> bool:
        info = self._info.get(device_id)
        return info is not None and cap in info.caps

    def forget(self, device_id: str) -> None:
        self._info.pop(device_id, None)
