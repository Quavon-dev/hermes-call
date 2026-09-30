import base64
import hashlib
import hmac
import json
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from hermescall_common.wire import b64d
from hermescall_relay import config as config_mod
from hermescall_relay import turn
from hermescall_relay.config import ApnsConfig, ConfigError
from hermescall_relay.push import DirectApns, PushResult
from hermescall_relay.ratelimit import FailureLimiter, RateLimiter
from hermescall_relay.store import Store

APNS = ApnsConfig("ABC123DEFG", "TEAM123456", "de.quavon.hermescall.voip")
TOKEN = "cd" * 32


def p8(curve: ec.EllipticCurve = ec.SECP256R1()) -> tuple[bytes, ec.EllipticCurvePrivateKey]:
    key = ec.generate_private_key(curve)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return pem, key


def apns_with(handler) -> tuple[DirectApns, ec.EllipticCurvePrivateKey]:
    pem, key = p8()
    return DirectApns(APNS, pem, httpx.AsyncClient(transport=httpx.MockTransport(handler))), key


async def test_apns_request_shape_and_jwt() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200)

    apns, key = apns_with(handler)
    assert await apns.send_voip(TOKEN, "sandbox", "CALLID") is PushResult.OK
    request = seen[0]
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{TOKEN}"
    assert json.loads(request.content) == {"c": "CALLID"}
    assert request.headers["apns-push-type"] == "voip"
    assert request.headers["apns-topic"] == APNS.topic
    header, claims, sig = request.headers["authorization"].removeprefix("bearer ").split(".")
    assert json.loads(b64d(header)) == {"alg": "ES256", "kid": APNS.key_id}
    assert json.loads(b64d(claims))["iss"] == APNS.team_id
    raw = b64d(sig, length=64)
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key.public_key().verify(der, f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))
    await apns.send_voip(TOKEN, "production", "X")
    assert seen[1].url.host == "api.push.apple.com"
    assert seen[1].headers["authorization"] == request.headers["authorization"]


@pytest.mark.parametrize(
    "status,body,expected",
    [
        (410, {"reason": "Unregistered"}, PushResult.INVALID_TOKEN),
        (400, {"reason": "BadDeviceToken"}, PushResult.INVALID_TOKEN),
        (403, {"reason": "InvalidProviderToken"}, PushResult.FAILED),
        (500, None, PushResult.FAILED),
    ],
)
async def test_apns_errors(status: int, body: dict | None, expected: PushResult) -> None:
    apns, _ = apns_with(lambda request: httpx.Response(status, json=body) if body else httpx.Response(status, text="x"))
    assert await apns.send_voip(TOKEN, "sandbox", "X") is expected


async def test_apns_network_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    apns, _ = apns_with(handler)
    assert await apns.send_voip(TOKEN, "sandbox", "X") is PushResult.FAILED


def test_apns_rejects_non_p256_key() -> None:
    pem, _ = p8(ec.SECP384R1())
    with pytest.raises(ValueError):
        DirectApns(APNS, pem)


def test_turn_credentials_match_coturn_rest_scheme() -> None:
    creds = turn.credentials(b"secret", ("turn:x:3478",), 600, now=1000)
    expiry, _ = creds["username"].split(":")
    assert int(expiry) == 1600
    expected = base64.b64encode(hmac.new(b"secret", creds["username"].encode(), hashlib.sha1).digest()).decode()
    assert creds["credential"] == expected


def test_store_code_expiry_and_attempts(tmp_path: Path) -> None:
    store = Store(tmp_path / "db")
    code = store.create_relay_code(now=0)
    assert store.consume_relay_code_attempt(code.slot) is None
    code = store.create_relay_code()
    assert [store.consume_relay_code_attempt(code.slot) for _ in range(4)] == [code.secret] * 3 + [None]


def test_store_bridge_delete_cascades(tmp_path: Path) -> None:
    store = Store(tmp_path / "db")
    bridge = store.add_bridge(b"k" * 32)
    device = store.add_device(bridge, b"d" * 32)
    assert not store.delete_device("other", device)
    assert store.delete_bridge(bridge)
    assert store.device(device) is None


def test_failure_limiter() -> None:
    limiter = FailureLimiter(max_failures=3, window=10, lockout=5)
    for t in (0, 1):
        limiter.fail("ip", now=t)
    assert not limiter.is_locked("ip", now=2)
    limiter.fail("ip", now=2)
    assert limiter.is_locked("ip", now=3)
    assert not limiter.is_locked("ip", now=8)


def test_failure_limiter_window_expires() -> None:
    limiter = FailureLimiter(max_failures=2, window=10, lockout=5)
    limiter.fail("ip", now=1)
    limiter.fail("ip", now=20)
    assert not limiter.is_locked("ip", now=20)


def test_rate_limiter_and_key_cap() -> None:
    limiter = RateLimiter(limit=2, window=10, max_keys=2)
    assert limiter.allow("a", now=1) and limiter.allow("a", now=2)
    assert not limiter.allow("a", now=3)
    assert limiter.allow("a", now=12)
    assert limiter.allow("b", now=12)
    assert not limiter.allow("c", now=12)


def write_config(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "relay.toml"
    path.write_text(body)
    return path


def test_config_load(tmp_path: Path) -> None:
    (tmp_path / "turn_secret").write_text("s3cret\n")
    path = write_config(
        tmp_path,
        f"""
authority = "relay.example.com:8443"
secrets_dir = "{tmp_path}"
[turn]
urls = ["turn:relay.example.com:3478?transport=udp"]
[apns]
enabled = true
key_id = "ABC123DEFG"
team_id = "TEAM123456"
topic = "de.quavon.hermescall.voip"
""",
    )
    cfg = config_mod.load(path)
    assert cfg.authority == "relay.example.com:8443" and cfg.apns == APNS
    assert cfg.secret("turn_secret") == b"s3cret"
    with pytest.raises(ConfigError):
        cfg.secret("missing")


@pytest.mark.parametrize(
    "body",
    [
        "",
        'authority = "bad host"',
        'authority = "a.example"\n[apns]\nenabled = true\nkey_id = "x"\nteam_id = "y"\ntopic = "no-voip-suffix"',
        'authority = "a.example"\ntls_pin = "short"',
    ],
)
def test_config_rejects(tmp_path: Path, body: str) -> None:
    with pytest.raises(ConfigError):
        config_mod.load(write_config(tmp_path, body))


def test_client_keys_unmap_ipv4_and_group_ipv6() -> None:
    from hermescall_relay.server import client_key

    assert client_key("::ffff:203.0.113.7") == "203.0.113.7"
    assert client_key("2001:db8:1:2:3:4:5:6") == "2001:db8:1:2::/64"
    assert client_key("2001:db8:1:2:3:4:5:6", 48) == "2001:db8:1::/48"


def test_failure_limiter_prune_keeps_recent_lockouts() -> None:
    limiter = FailureLimiter(max_failures=1, window=10, lockout=100, max_keys=4)
    limiter.fail("victim", now=0)
    for n in range(10):
        limiter.fail(f"noise{n}", now=1 + n)
    assert limiter.is_locked("victim", now=50)


def test_unauthenticated_connections_leave_room_for_paired_clients(tmp_path) -> None:
    from hermescall_relay import server
    from hermescall_relay.store import Store

    from .conftest import make_config

    config = make_config(tmp_path)
    relay = server.Relay(config, Store(config.db_path), None, None)
    limits = config.limits
    admitted = sum(relay._admit(f"10.0.{n // 250}.{n % 250}") for n in range(limits.max_unauthenticated + 50))
    assert admitted == limits.max_unauthenticated
    assert relay.connections < limits.max_connections


def test_client_ip_behind_an_external_proxy(tmp_path) -> None:
    import ipaddress
    from dataclasses import replace
    from types import SimpleNamespace

    from hermescall_relay.server import Relay
    from hermescall_relay.store import Store

    from .conftest import FakePush, make_config

    config = replace(make_config(tmp_path), trusted_proxies=(ipaddress.ip_network("192.168.0.0/16"),))
    relay = Relay(config, Store(config.db_path), FakePush(), b"t")

    def req(remote: str):
        return SimpleNamespace(remote=remote, headers={"X-Forwarded-For": "6.6.6.6, 203.0.113.9"})

    assert relay.client_ip(req("192.168.0.50")) == "203.0.113.9"  # NPM on the LAN
    assert relay.client_ip(req("::ffff:192.168.0.50")) == "203.0.113.9"
    assert relay.client_ip(req("127.0.0.1")) == "203.0.113.9"  # own Caddy
    assert relay.client_ip(req("10.0.0.7")) == "10.0.0.7"  # not trusted: header ignored


def test_config_trusted_proxies(tmp_path) -> None:
    from hermescall_relay.config import ConfigError, load

    path = tmp_path / "relay.toml"
    path.write_text('authority = "relay.test"\ntrusted_proxies = ["192.168.0.0/24", "fd00::/8"]\n')
    assert [str(n) for n in load(path).trusted_proxies] == ["192.168.0.0/24", "fd00::/8"]
    path.write_text('authority = "relay.test"\ntrusted_proxies = ["nope"]\n')
    import pytest

    with pytest.raises(ConfigError):
        load(path)
