"""`hermescall-relay doctor`: checks the things that break a relay in practice.

Each check prints `ok`, `warn` or `FAIL` with a short reason; the exit code is 1 when any check
failed. Nothing here changes state, and nothing secret is printed.
"""

import datetime
import email.utils
import os
import socket
import ssl
import struct
import time
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

import httpx
from cryptography import x509

from . import schema
from .config import Config, ConfigError
from .push import APNS_HOSTS, load_apns_key
from .pushauth import MAX_SKEW_SECONDS
from .store import Store

CERT_WARN_DAYS = 14
TIMEOUT = 5.0
_STUN_MAGIC = 0x2112A442


@dataclass(frozen=True)
class Result:
    status: str  # ok, warn, fail
    name: str
    detail: str


def _ok(name: str, detail: str) -> Result:
    return Result("ok", name, detail)


def _warn(name: str, detail: str) -> Result:
    return Result("warn", name, detail)


def _fail(name: str, detail: str) -> Result:
    return Result("fail", name, detail)


def check_database(config: Config) -> Result:
    try:
        store = Store(config.db_path, config.limits)
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        return _fail("database", f"cannot open {config.db_path}: {exc.__class__.__name__}")
    try:
        integrity = store._db.execute("PRAGMA quick_check").fetchone()[0]
        if integrity != "ok":
            return _fail("database", "integrity check failed; restore a backup")
        if not store.writable():
            return _fail("database", "not writable (permissions or a full disk?)")
        usage = store.usage()
        paired = f"{usage.bridges} bridge(s), {usage.devices} device(s)"
        return _ok("database", f"schema {store.schema_version}/{schema.LATEST}, {paired}")
    finally:
        store.close()


def check_disk(config: Config) -> Result:
    try:
        free = Store.free_bytes_at(config.db_path)
    except OSError as exc:
        return _fail("disk", str(exc))
    mib = free // (1024 * 1024)
    if free < config.limits.min_free_bytes:
        return _fail("disk", f"{mib} MiB free, below the {config.limits.min_free_bytes // (1024 * 1024)} MiB floor")
    return _ok("disk", f"{mib} MiB free")


def check_dns(config: Config) -> Result:
    host = config.host
    try:
        socket.inet_pton(socket.AF_INET6 if ":" in host else socket.AF_INET, host)
        return _ok("dns", f"{host} is an address")
    except OSError:
        pass
    try:
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, config.port, proto=socket.IPPROTO_TCP)})
    except OSError as exc:
        return _fail("dns", f"{host} does not resolve ({exc.strerror or exc})")
    return _ok("dns", f"{host} -> {', '.join(addresses)}")


def check_tls(config: Config) -> Result:
    """The certificate phones see: expiry, and the pin for self-signed relays."""
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with (
            socket.create_connection((config.host, config.port), timeout=TIMEOUT) as raw,
            context.wrap_socket(raw, server_hostname=config.host) as tls,
        ):
            der = tls.getpeercert(binary_form=True)
    except OSError as exc:
        return _warn("tls", f"cannot reach {config.authority} from here ({exc.__class__.__name__}); check from outside")
    if not der:
        return _fail("tls", "no certificate")
    cert = x509.load_der_x509_certificate(der)
    expires = cert.not_valid_after_utc if hasattr(cert, "not_valid_after_utc") else cert.not_valid_after
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.UTC)
    days = (expires - datetime.datetime.now(datetime.UTC)).days
    if days < 0:
        return _fail("tls", f"certificate expired {-days} day(s) ago")
    if days < CERT_WARN_DAYS:
        return _warn("tls", f"certificate expires in {days} day(s)")
    return _ok("tls", f"certificate valid for {days} more day(s)")


def check_listener(config: Config) -> Result:
    host = "127.0.0.1" if config.listen_host in ("0.0.0.0", "", "::") else config.listen_host  # noqa: S104
    url = f"http://{host}:{config.listen_port}/healthz"
    try:
        response = httpx.get(url, timeout=TIMEOUT)
    except httpx.HTTPError as exc:
        return _fail("relay", f"not answering on {host}:{config.listen_port} ({exc.__class__.__name__}); is the service running?")
    try:
        body = response.json()
    except ValueError:
        body = {}
    status = body.get("status", response.status_code)
    if response.status_code != 200:
        return _fail("relay", f"healthz {response.status_code}: {body.get('checks', {})}")
    return (_ok if status == "ok" else _warn)("relay", f"healthz {status}, version {body.get('version', '?')}")


def _stun_binding(host: str, port: int) -> bool:
    transaction = os.urandom(12)
    request = struct.pack("!HHI", 0x0001, 0, _STUN_MAGIC) + transaction
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(TIMEOUT)
        sock.sendto(request, (host, port))
        data, _ = sock.recvfrom(2048)
    return len(data) >= 20 and data[:2] == b"\x01\x01" and data[8:20] == transaction


def check_turn(config: Config) -> Result:
    urls = [url for url in config.turn_urls if url.startswith("turn:")]
    if not urls:
        return _warn("turn", "no turn: URLs configured; calls fail behind strict NATs")
    if not _secret_present(config, "turn_secret"):
        return _fail("turn", "turn_secret missing")
    target = urlsplit(urls[0].split("?")[0].replace("turn:", "turn://", 1))
    host, port = target.hostname or config.host, target.port or 3478
    try:
        if _stun_binding(host, port):
            return _ok("turn", f"coturn answers on {host}:{port}/udp")
        return _fail("turn", f"unexpected answer from {host}:{port}/udp")
    except OSError as exc:
        return _warn("turn", f"no STUN answer from {host}:{port}/udp ({exc.__class__.__name__}); check the port forward")


def _secret_present(config: Config, name: str) -> bool:
    try:
        return bool(config.secret(name))
    except ConfigError:
        return False


def check_push(config: Config) -> Result:
    if config.apns is not None:
        try:
            load_apns_key(config.secret("apns_key"))
        except (ConfigError, ValueError) as exc:
            return _fail("push", f"APNs key: {exc}")
        return _reach("push", APNS_HOSTS["production"], "own APNs key loaded")
    if not config.push_gateway:
        return _warn("push", "disabled: incoming calls ring only while the app is open")
    if not _secret_present(config, "push_gateway_key"):
        return _fail("push", "push_gateway_key missing")
    try:
        response = httpx.get(f"{config.push_gateway}/healthz", timeout=TIMEOUT)
    except httpx.HTTPError as exc:
        return _fail("push", f"gateway {config.push_gateway} unreachable ({exc.__class__.__name__})")
    if response.status_code != 200:
        return _fail("push", f"gateway answered {response.status_code}")
    return _clock(response.headers.get("date"), config.push_gateway)


def _clock(date_header: str | None, gateway: str) -> Result:
    """The gateway refuses requests more than 60 s off: an unsynced clock silently kills pushes."""
    if not date_header:
        return _ok("push", f"gateway {gateway} reachable")
    try:
        remote = email.utils.parsedate_to_datetime(date_header).timestamp()
    except (TypeError, ValueError):
        return _ok("push", f"gateway {gateway} reachable")
    skew = time.time() - remote
    if abs(skew) > MAX_SKEW_SECONDS / 2:
        return _fail("push", f"clock is {skew:+.0f} s off (gateway allows ±{MAX_SKEW_SECONDS} s); enable NTP (timedatectl)")
    return _ok("push", f"gateway {gateway} reachable, clock within {abs(skew):.0f} s")


def _reach(name: str, url: str, detail: str) -> Result:
    """A TLS handshake with a verified certificate (APNs speaks only HTTP/2, so no request)."""
    host = urlsplit(url).hostname or url
    try:
        context = ssl.create_default_context()
        with (
            socket.create_connection((host, 443), timeout=TIMEOUT) as raw,
            context.wrap_socket(raw, server_hostname=host),
        ):
            pass
    except OSError as exc:
        return _fail(name, f"{detail}, but {host} unreachable ({exc.__class__.__name__})")
    return _ok(name, f"{detail}, {host} reachable")


CHECKS: tuple[Callable[[Config], Result], ...] = (
    check_database,
    check_disk,
    check_listener,
    check_dns,
    check_tls,
    check_turn,
    check_push,
)


def run(config: Config, checks: tuple[Callable[[Config], Result], ...] = CHECKS) -> list[Result]:
    results = []
    for check in checks:
        try:
            results.append(check(config))
        except Exception as exc:  # noqa: BLE001 - a broken check is a finding, not a crash
            results.append(_fail(check.__name__.removeprefix("check_"), f"check crashed: {exc.__class__.__name__}"))
    return results


def report(results: list[Result]) -> int:
    labels = {"ok": "ok  ", "warn": "warn", "fail": "FAIL"}
    for result in results:
        print(f"{labels[result.status]}  {result.name:<9} {result.detail}")
    return 1 if any(result.status == "fail" for result in results) else 0
