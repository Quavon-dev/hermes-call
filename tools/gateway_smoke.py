# SPDX-License-Identifier: MIT
"""External smoke check of a deployed push gateway (stdlib only; the scheduled workflow runs it).

    python3 tools/gateway_smoke.py [https://hermes-push.quavon.de]

Checks, from outside: /healthz answers 200 "ok"; an unsigned push is refused with 401 (the push
path is up and still demands a relay signature); the TLS certificate is valid for at least
MIN_CERT_DAYS more days. Sends nothing that could reach a phone. Exit 1 with one line per failure.
"""

import json
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

DEFAULT_URL = "https://hermes-push.quavon.de"
MIN_CERT_DAYS = 14
TIMEOUT = 15


def fetch(url: str, data: bytes | None = None) -> tuple[int, bytes]:
    headers = {"Content-Type": "application/json", "User-Agent": "hermes-call-smoke"} if data is not None else {}
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")  # noqa: S310
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310
            return response.status, response.read(4096)
    except urllib.error.HTTPError as error:
        return error.code, error.read(4096)


def health_ok(status: int, body: bytes) -> bool:
    """Gateways up to 0.6.2 answer the text "ok"; newer ones JSON with "status": "ok"."""
    if status != 200:
        return False
    text = body.decode(errors="replace").strip()
    if text == "ok":
        return True
    try:
        return json.loads(text).get("status") == "ok"
    except (ValueError, AttributeError):
        return False


def cert_days_left(host: str, port: int) -> float:
    context = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=TIMEOUT) as raw, context.wrap_socket(raw, server_hostname=host) as tls:
        expires = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])
    return (expires - time.time()) / 86_400


def check(base: str) -> list[str]:
    failures = []
    base = base.rstrip("/")
    parts = urlsplit(base)
    if parts.scheme != "https" or not parts.hostname:
        return [f"not an https URL: {base}"]
    try:
        status, body = fetch(f"{base}/healthz")
        if not health_ok(status, body):
            failures.append(f"/healthz: HTTP {status} {body[:200]!r}")
    except OSError as error:
        failures.append(f"/healthz: {error}")
    try:
        status, body = fetch(f"{base}/v1/push", data=b"{}")
        if status != 401:
            failures.append(f"unsigned /v1/push: expected 401, got HTTP {status} {body[:200]!r}")
    except OSError as error:
        failures.append(f"/v1/push: {error}")
    try:
        days = cert_days_left(parts.hostname, parts.port or 443)
        if days < MIN_CERT_DAYS:
            failures.append(f"TLS certificate expires in {days:.1f} days")
    except (OSError, ssl.SSLError) as error:
        failures.append(f"TLS: {error}")
    return failures


def main(argv: list[str]) -> int:
    base = argv[0] if argv else DEFAULT_URL
    failures = check(base)
    for failure in failures:
        print(f"FAIL  {base}: {failure}", file=sys.stderr)
    if not failures:
        print(f"OK    {base}: healthz, signature check, certificate")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
