"""The relay's /healthz and /metrics.

/healthz is public (the installer, Docker and monitoring use it): 200 with {"status": "ok"} or
"degraded" (push gateway unreachable: calls still work while the app is open), 503 "unhealthy"
when the relay cannot do its job (database not writable, disk below the free-space floor). It
carries the version and check names, nothing about bridges or devices.

/metrics (Prometheus text) is served only on the separate metrics listener; see docs/relay.md.
"""

import asyncio
import logging
import time
from typing import TYPE_CHECKING

import httpx

from .metrics import Registry
from .push import DirectApns, GatewayPush
from .version import VERSION

if TYPE_CHECKING:
    from .server import Relay

log = logging.getLogger(__name__)

GATEWAY_PROBE_SECONDS = 60.0
GATEWAY_PROBE_TIMEOUT = 5.0


class GatewayProbe:
    """Remembers for a minute whether the push gateway answered its /healthz."""

    def __init__(self, url: str, client: httpx.AsyncClient | None = None) -> None:
        self._url = f"{url.rstrip('/')}/healthz"
        self._client = client
        self._checked = -GATEWAY_PROBE_SECONDS
        self._ok = True
        self._lock = asyncio.Lock()

    async def reachable(self) -> bool:
        async with self._lock:
            if time.monotonic() - self._checked < GATEWAY_PROBE_SECONDS:
                return self._ok
            client = self._client or httpx.AsyncClient(timeout=GATEWAY_PROBE_TIMEOUT)
            try:
                response = await client.get(self._url)
                self._ok = response.status_code == 200
            except httpx.HTTPError:
                self._ok = False
            finally:
                if self._client is None:
                    await client.aclose()
            self._checked = time.monotonic()
            return self._ok


async def health(relay: "Relay") -> tuple[int, dict]:
    checks = {"database": "ok" if relay.store.writable() else "failed"}
    try:
        free = relay.store.free_bytes()
        checks["disk"] = "ok" if free >= relay.limits.min_free_bytes else "low"
    except OSError:
        checks["disk"] = "failed"
    checks["push"] = await _push_check(relay)
    unhealthy = checks["database"] != "ok" or checks["disk"] != "ok"
    status = "unhealthy" if unhealthy else ("degraded" if checks["push"] == "unreachable" else "ok")
    return (503 if unhealthy else 200), {"status": status, "version": VERSION, "checks": checks}


async def _push_check(relay: "Relay") -> str:
    if relay.push is None:
        return "disabled"
    if isinstance(relay.push, DirectApns):
        return "ok"  # the key was loaded at start, or the relay would not be running
    if isinstance(relay.push, GatewayPush) and relay.gateway_probe is not None:
        return "ok" if await relay.gateway_probe.reachable() else "unreachable"
    return "ok"


def relay_metrics(relay: "Relay") -> Registry:
    registry = Registry("hermescall_relay")
    registry.gauge("build_info", "Relay version.", lambda: {(("version", VERSION),): 1})
    registry.gauge("connections", "Open WebSocket connections by role.", lambda: _connections(relay))
    registry.gauge("paired", "Paired bridges and devices.", lambda: _paired(relay))
    registry.gauge("stored_bytes", "Mailbox and attachment bytes on disk.", lambda: _stored(relay))
    registry.gauge("stored_items", "Mailbox messages and attachments.", lambda: _items(relay))
    registry.gauge("disk_free_bytes", "Free space on the data volume.", lambda: relay.store.free_bytes())
    registry.gauge("blob_transfers", "Attachment transfers in progress.", lambda: _transfers(relay))
    registry.gauge("push_total", "Push results (retry = repeated attempts).", lambda: _push(relay, "stats"), "counter")
    registry.gauge("push_responses_total", "Push HTTP answers by status.", lambda: _push(relay, "statuses"), "counter")
    return registry


def _connections(relay: "Relay") -> dict:
    return {
        (("role", "bridge"),): len(relay.bridges),
        (("role", "device"),): len(relay.devices),
        (("role", "unauthenticated"),): relay.unauthenticated,
    }


def _paired(relay: "Relay") -> dict:
    usage = relay.store.usage()
    return {(("kind", "bridge"),): usage.bridges, (("kind", "device"),): usage.devices}


def _stored(relay: "Relay") -> dict:
    usage = relay.store.usage()
    return {(("kind", "mail"),): usage.mail_bytes, (("kind", "blob"),): usage.blob_bytes}


def _items(relay: "Relay") -> dict:
    usage = relay.store.usage()
    return {(("kind", "mail"),): usage.mail_count, (("kind", "blob"),): usage.blob_count}


def _transfers(relay: "Relay") -> dict:
    return {(("direction", "upload"),): relay.blob_transfers, (("direction", "download"),): relay.blob_downloads}


def _push(relay: "Relay", attribute: str) -> dict:
    counts = getattr(relay.push, attribute, None) or {}
    label = "result" if attribute == "stats" else "status"
    return {((label, str(key)),): value for key, value in counts.items()}
