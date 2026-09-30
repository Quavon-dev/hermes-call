"""Service health for `/healthz`, `doctor` and systemd (sd_notify, no python-systemd needed)."""

import asyncio
import logging
import os
import socket
import time
from dataclasses import dataclass

import httpx

log = logging.getLogger(__name__)

PROBE_TIMEOUT = 3.0
CACHE_SECONDS = 10.0
# Kokoro-FastAPI and the Hermes API server both answer GET /health.
HEALTH_PATH = "/health"


@dataclass(frozen=True)
class Probe:
    ok: bool
    detail: str


async def probe_http(base_url: str, path: str = HEALTH_PATH, timeout: float = PROBE_TIMEOUT) -> Probe:
    """GET a loopback health URL (no auth, no proxies from the environment)."""
    try:
        async with httpx.AsyncClient(base_url=base_url, timeout=timeout, trust_env=False) as client:
            response = await client.get(path)
    except httpx.HTTPError as exc:
        return Probe(False, exc.__class__.__name__)
    return Probe(response.status_code < 500, f"HTTP {response.status_code}")


class HealthChecker:
    """Probes Hermes and Kokoro at most every CACHE_SECONDS; the relay state is read live."""

    def __init__(self, hermes_url: str, tts_url: str, relay_connected) -> None:
        self._hermes_url = hermes_url
        self._tts_url = tts_url
        self._relay_connected = relay_connected
        self._cached: tuple[float, Probe, Probe] | None = None
        self._lock = asyncio.Lock()

    async def check(self) -> dict:
        async with self._lock:
            if self._cached is None or time.monotonic() - self._cached[0] > CACHE_SECONDS:
                hermes, kokoro = await asyncio.gather(probe_http(self._hermes_url), probe_http(self._tts_url))
                self._cached = (time.monotonic(), hermes, kokoro)
            _, hermes, kokoro = self._cached
        relay = bool(self._relay_connected())
        return {"ok": relay and hermes.ok and kokoro.ok, "relay": relay, "hermes": hermes.ok, "kokoro": kokoro.ok}


def sd_notify(message: str) -> bool:
    """Tell systemd (Type=notify, WatchdogSec) about readiness / liveness. False when not under systemd."""
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return False
    if address.startswith("@"):
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(address)
            sock.sendall(message.encode())
    except OSError as exc:
        log.warning("sd_notify failed: %s", exc)
        return False
    return True


def watchdog_interval() -> float | None:
    """Half of systemd's WatchdogSec (WATCHDOG_USEC), or None when no watchdog is set for this process."""
    usec, pid = os.environ.get("WATCHDOG_USEC"), os.environ.get("WATCHDOG_PID")
    if not usec or (pid and pid != str(os.getpid())):
        return None
    try:
        return int(usec) / 2_000_000
    except ValueError:
        return None


async def watchdog(interval: float) -> None:
    """Pings systemd while the event loop runs; a stuck loop stops the pings and systemd restarts us."""
    while True:
        sd_notify("WATCHDOG=1")
        await asyncio.sleep(interval)
