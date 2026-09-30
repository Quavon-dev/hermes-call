import json
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from hermescall_common.wire import b64e
from hermescall_relay import cli, pushauth
from hermescall_relay.config import DEFAULT_PUSH_GATEWAY, ApnsConfig, ConfigError, load
from hermescall_relay.gateway import GatewayConfig, PushGateway, load_gateway
from hermescall_relay.push import GatewayPush, PushResult

from .conftest import FakePush

TOKEN = "ab" * 32
CALL_ID = b64e(b"c" * 16)
STATE = {"step": 1, "total": 3, "label": "Working", "state": "running", "startedAt": 1_700_000_000}


def pem(key: Ed25519PrivateKey) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def gateway_config(blocked: frozenset[str] = frozenset()) -> GatewayConfig:
    return GatewayConfig(
        "127.0.0.1", 0, True, ApnsConfig("KEY1234567", "TEAM123456", "app.test.voip"), blocked, Path("/nonexistent")
    )


@pytest.fixture
def key() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


@pytest.fixture
def sent() -> FakePush:
    return FakePush()


@pytest.fixture
async def gw(aiohttp_client, sent: FakePush):
    gateway = PushGateway(gateway_config(), sent)
    return gateway, await aiohttp_client(gateway.app())


async def post(client, key: Ed25519PrivateKey, body: dict, now: float | None = None, raw: bytes | None = None):
    data = raw if raw is not None else json.dumps(body).encode()
    return await client.post("/v1/push", data=data, headers={"Authorization": pushauth.sign(key, data, now)})


# ---- signing ---------------------------------------------------------


def test_sign_verify_roundtrip_and_tamper(key: Ed25519PrivateKey) -> None:
    header = pushauth.sign(key, b"body", now=1000)
    assert header != pushauth.sign(key, b"body", now=1000)  # nonce
    relay, signature = pushauth.verify(header, b"body", now=1010)
    assert relay == pushauth.relay_id(key) and len(signature) == 64
    for bad_body, now in ((b"other", 1010), (b"body", 1000 + pushauth.MAX_SKEW_SECONDS + 1)):
        with pytest.raises(pushauth.AuthError):
            pushauth.verify(header, bad_body, now=now)
    other = pushauth.sign(Ed25519PrivateKey.generate(), b"body", now=1000)
    forged = ".".join(header.split(".")[:3] + other.split(".")[3:])
    for bad in ("", "Bearer x", "HC-Relay a.b", "HC-Relay a.1000.b.c", forged):
        with pytest.raises(pushauth.AuthError):
            pushauth.verify(bad, b"body", now=1000)


def test_load_key_rejects_other_key_types() -> None:
    from cryptography.hazmat.primitives.asymmetric import ec

    ec_pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    with pytest.raises(ValueError, match="Ed25519"):
        pushauth.load_key(ec_pem)


# ---- gateway ---------------------------------------------------------


async def test_gateway_sends_the_three_shapes(gw, sent: FakePush, key: Ed25519PrivateKey) -> None:
    _, client = gw
    for body in (
        {"kind": "voip", "token": TOKEN, "env": "production", "call_id": CALL_ID},
        {"kind": "alert", "token": TOKEN, "env": "sandbox", "ciphertext": b64e(b"x" * 40)},
        {"kind": "alert", "token": TOKEN, "env": "sandbox", "ciphertext": None},
        {"kind": "liveactivity", "token": TOKEN, "env": "production", "event": "update", "content_state": STATE},
    ):
        response = await post(client, key, body)
        assert response.status == 200 and (await response.json()) == {"result": "ok"}
    assert sent.sent == [(TOKEN, "production", CALL_ID)]
    assert sent.alerts == [(TOKEN, "sandbox", b64e(b"x" * 40)), (TOKEN, "sandbox", None)]
    assert sent.live == [(TOKEN, "production", "update", STATE)]


async def test_gateway_reports_invalid_token(gw, sent: FakePush, key: Ed25519PrivateKey) -> None:
    _, client = gw
    sent.invalid.add(TOKEN)
    response = await post(client, key, {"kind": "voip", "token": TOKEN, "env": "sandbox", "call_id": CALL_ID})
    assert (await response.json()) == {"result": "invalid_token"}


@pytest.mark.parametrize(
    "body",
    [
        {"kind": "voip", "token": TOKEN, "env": "sandbox", "call_id": CALL_ID, "text": "hello"},
        {"kind": "voip", "token": "XYZ", "env": "sandbox", "call_id": CALL_ID},
        {"kind": "voip", "token": TOKEN, "env": "dev", "call_id": CALL_ID},
        {"kind": "voip", "token": TOKEN, "env": "sandbox", "call_id": "short"},
        {"kind": "alert", "token": TOKEN, "env": "sandbox", "ciphertext": "not base64!"},
        {"kind": "liveactivity", "token": TOKEN, "env": "sandbox", "event": "update", "content_state": {"x": 1}},
        {"kind": "liveactivity", "token": TOKEN, "env": "sandbox", "event": "boom", "content_state": STATE},
        {"kind": "raw", "token": TOKEN, "env": "sandbox", "payload": {"aps": {}}},
        [1, 2],
    ],
)
async def test_gateway_rejects_unknown_shapes(gw, sent: FakePush, key: Ed25519PrivateKey, body) -> None:
    _, client = gw
    response = await post(client, key, body)
    assert response.status == 400
    assert not (sent.sent or sent.alerts or sent.live)


async def test_gateway_rejects_bad_auth_replay_and_blocked(aiohttp_client, sent: FakePush, key) -> None:
    blocked = Ed25519PrivateKey.generate()
    client = await aiohttp_client(PushGateway(gateway_config(frozenset({pushauth.relay_id(blocked)})), sent).app())
    body = json.dumps({"kind": "voip", "token": TOKEN, "env": "sandbox", "call_id": CALL_ID}).encode()
    assert (await client.post("/v1/push", data=body)).status == 401
    header = {"Authorization": pushauth.sign(key, body)}
    assert (await client.post("/v1/push", data=body + b" ", headers=header)).status == 401
    assert (await client.post("/v1/push", data=body, headers=header)).status == 200
    assert (await client.post("/v1/push", data=body, headers=header)).status == 401  # replay
    assert (await post(client, key, {}, now=0, raw=body)).status == 401  # stale
    assert (await post(client, blocked, {}, raw=body)).status == 403
    assert len(sent.sent) == 1


async def test_gateway_limits_per_token_and_new_relays_per_ip(gw, sent: FakePush, key) -> None:
    _, client = gw
    body = {"kind": "voip", "token": TOKEN, "env": "sandbox", "call_id": CALL_ID}
    statuses = [(await post(client, key, body)).status for _ in range(11)]
    assert statuses == [200] * 10 + [429]
    # A second relay cannot keep ringing the same phone.
    assert (await post(client, Ed25519PrivateKey.generate(), body)).status == 429
    other = {**body, "token": "cd" * 32}
    statuses = [(await post(client, Ed25519PrivateKey.generate(), other)).status for _ in range(10)]
    assert statuses[-1] == 429 and statuses.count(200) == 8  # 10 new keys per IP per hour, 2 used


async def test_gateway_rejects_oversized_body(gw, key: Ed25519PrivateKey) -> None:
    _, client = gw
    assert (await post(client, key, {}, raw=b"x" * 20_000)).status == 413


def test_load_gateway(tmp_path: Path) -> None:
    path = tmp_path / "gateway.toml"
    path.write_text('blocked_relays = ["abc"]\n[apns]\nkey_id = "KEY1234567"\nteam_id = "TEAM123456"\ntopic = "a.b.voip"\n')
    config = load_gateway(path)
    assert config.blocked_relays == {"abc"} and config.listen_port == 8744
    path.write_text('[apns]\nkey_id = "K"\nteam_id = "T"\ntopic = "a.b"\n')
    with pytest.raises(ConfigError):
        load_gateway(path)
    with pytest.raises(ConfigError, match="apns_key"):
        config.apns_key()


# ---- relay side ------------------------------------------------------


async def test_gateway_push_end_to_end(aiohttp_server, sent: FakePush, key: Ed25519PrivateKey) -> None:
    server = await aiohttp_server(PushGateway(gateway_config(), sent).app())
    push = GatewayPush(str(server.make_url("/")), pem(key), httpx.AsyncClient())
    assert await push.send_voip(TOKEN, "sandbox", CALL_ID) is PushResult.OK
    assert await push.send_alert(TOKEN, "production", None) is PushResult.OK
    assert await push.send_live_activity(TOKEN, "production", "end", STATE) is PushResult.OK
    sent.invalid.add(TOKEN)
    assert await push.send_voip(TOKEN, "sandbox", CALL_ID) is PushResult.INVALID_TOKEN
    assert await push.send_voip("bad", "sandbox", CALL_ID) is PushResult.FAILED
    await push.close()
    assert len(sent.sent) == 2 and sent.live == [(TOKEN, "production", "end", STATE)]


async def test_gateway_push_unreachable(key: Ed25519PrivateKey) -> None:
    push = GatewayPush("https://127.0.0.1:9", pem(key), httpx.AsyncClient(timeout=2))
    assert await push.send_voip(TOKEN, "sandbox", CALL_ID) is PushResult.FAILED
    await push.close()


def _relay_toml(tmp_path: Path, extra: str = "") -> Path:
    path = tmp_path / "relay.toml"
    path.write_text(f'authority = "relay.test"\nsecrets_dir = "{tmp_path}"\n{extra}')
    return path


def test_config_uses_gateway_without_own_key(tmp_path: Path) -> None:
    assert load(_relay_toml(tmp_path)).push_gateway == DEFAULT_PUSH_GATEWAY
    assert load(_relay_toml(tmp_path, "[apns]\nenabled = false\n")).push_gateway == DEFAULT_PUSH_GATEWAY
    assert load(_relay_toml(tmp_path, "[push_gateway]\nenabled = false\n")).push_gateway is None
    own = '[apns]\nenabled = true\nkey_id = "K1"\nteam_id = "T1"\ntopic = "a.b.voip"\n'
    assert load(_relay_toml(tmp_path, own)).push_gateway is None
    custom = '[push_gateway]\nurl = "https://push.example.com/"\n'
    assert load(_relay_toml(tmp_path, custom)).push_gateway == "https://push.example.com"
    with pytest.raises(ConfigError, match="https"):
        load(_relay_toml(tmp_path, '[push_gateway]\nurl = "http://push.example.com"\n'))


async def test_cli_make_push_and_push_id(tmp_path: Path, capsys, key: Ed25519PrivateKey) -> None:
    config = load(_relay_toml(tmp_path))
    push, mode = cli.make_push(config)
    assert push is None and "no gateway key" in mode
    assert cli.push_id(config) == 1
    (tmp_path / "push_gateway_key").write_bytes(pem(key))
    push, mode = cli.make_push(config)
    assert isinstance(push, GatewayPush) and DEFAULT_PUSH_GATEWAY in mode
    await push.close()
    assert cli.push_id(config) == 0
    assert capsys.readouterr().out.strip() == pushauth.relay_id(key)
    assert cli.make_push(load(_relay_toml(tmp_path, "[push_gateway]\nenabled = false\n"))) == (None, "disabled")


def test_cli_silences_httpx_request_log(tmp_path: Path) -> None:
    import logging

    logging.getLogger("httpx").setLevel(logging.NOTSET)
    cli.main(["--config", str(_relay_toml(tmp_path)), "check-config"])
    assert logging.getLogger("httpx").getEffectiveLevel() == logging.WARNING


def test_non_ascii_timestamp_is_unauthorized(key: Ed25519PrivateKey) -> None:
    parts = pushauth.sign(key, b"body").split(".")
    with pytest.raises(pushauth.AuthError):
        pushauth.verify(".".join([parts[0], "²", *parts[2:]]), b"body")


def test_evicting_limiter_never_locks_out_newcomers() -> None:
    from hermescall_relay.ratelimit import RateLimiter

    limiter = RateLimiter(limit=1, window=3600, max_keys=3, evict=True)
    assert all(limiter.allow(f"junk{i}", now=0) for i in range(10))
    assert limiter.allow("victim", now=1) and not limiter.allow("victim", now=2)
    strict = RateLimiter(limit=1, window=3600, max_keys=3)
    assert all(strict.allow(f"junk{i}", now=0) for i in range(3)) and not strict.allow("victim", now=1)


def test_expiring_set_prunes_and_caps() -> None:
    from hermescall_relay.gateway import ExpiringSet

    seen = ExpiringSet(ttl=10, max_keys=2)
    assert seen.add("a", 0) and seen.add("b", 5) and not seen.add("c", 6)
    assert seen.contains("a", 9) and not seen.contains("a", 10) and len(seen) == 1
    assert seen.add("c", 10)
    seen.evict_oldest()
    assert not seen.contains("b", 11) and seen.contains("c", 11)


async def test_gateway_limits_new_tokens_per_relay(gw, sent: FakePush, key: Ed25519PrivateKey) -> None:
    _, client = gw
    statuses = [
        (await post(client, key, {"kind": "voip", "token": f"{i:064x}", "env": "sandbox", "call_id": CALL_ID})).status
        for i in range(61)
    ]
    assert statuses == [200] * 60 + [429]
    # Known tokens keep working.
    body = {"kind": "voip", "token": f"{0:064x}", "env": "sandbox", "call_id": CALL_ID}
    assert (await post(client, key, body)).status == 200


def test_client_ip_trusts_only_configured_proxies() -> None:
    import ipaddress
    from dataclasses import replace
    from types import SimpleNamespace

    config = replace(gateway_config(), trusted_proxies=(ipaddress.ip_network("10.42.0.0/16"),))
    gateway = PushGateway(config, FakePush())

    def request(remote: str, forwarded: str = "198.51.100.7, 203.0.113.9"):
        return SimpleNamespace(remote=remote, headers={"X-Forwarded-For": forwarded})

    assert gateway.client_ip(request("10.42.3.4")) == "203.0.113.9"  # Traefik pod
    assert gateway.client_ip(request("127.0.0.1")) == "203.0.113.9"  # Caddy on the host
    assert gateway.client_ip(request("192.0.2.1")) == "192.0.2.1"  # anyone else: header ignored
    assert gateway.client_ip(request("not-an-ip")) == "not-an-ip"


def test_load_gateway_trusted_proxies(tmp_path: Path) -> None:
    path = tmp_path / "gateway.toml"
    path.write_text(
        'trusted_proxies = ["10.42.0.0/16"]\n[apns]\nkey_id = "KEY1234567"\nteam_id = "TEAM123456"\ntopic = "a.b.voip"\n'
    )
    assert [str(n) for n in load_gateway(path).trusted_proxies] == ["10.42.0.0/16"]
    path.write_text('trusted_proxies = ["nope"]\n[apns]\nkey_id = "K1"\nteam_id = "T1"\ntopic = "a.b.voip"\n')
    with pytest.raises(ConfigError):
        load_gateway(path)
