"""Health, metrics, graceful shutdown, limits from relay.toml, proxies, CLI and doctor."""

import asyncio
import dataclasses
import ipaddress
import json
import logging
import time
import tomllib
from pathlib import Path

import pytest
from aiohttp import WSCloseCode, WSMsgType

from hermescall_common import wire
from hermescall_relay import cli, doctor, limits, logs, netutil
from hermescall_relay import config as config_mod
from hermescall_relay.store import Store
from hermescall_relay.version import CAPABILITIES, VERSION

from .conftest import HOST, connect, pair_bridge, pair_device, recv, request, send
from .test_chat_relay import mid

TOKEN = "ab" * 32


def test_version_matches_the_package() -> None:
    pyproject = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text())
    assert pyproject["project"]["version"] == VERSION


# ---- limits and config ------------------------------------------------


def test_limits_default_and_override() -> None:
    assert limits.parse(None) == limits.Limits()
    parsed = limits.parse({"max_connections": 1000, "mail_ack_grace": 5, "storage_max_bytes": 1e9})
    assert parsed.max_connections == 1000 and parsed.mail_ack_grace == 5.0 and parsed.storage_max_bytes == 10**9


@pytest.mark.parametrize(
    "section",
    [{"nope": 1}, {"max_connections": 0}, {"max_connections": "10"}, {"max_connections": 1.5}, {"max_connections": True}],
)
def test_limits_reject_bad_values(section) -> None:
    with pytest.raises(ValueError):
        limits.parse(section)


def _write_config(tmp_path: Path, extra: str = "") -> Path:
    path = tmp_path / "relay.toml"
    path.write_text(f'authority = "relay.example.com"\ndb_path = "{tmp_path}/relay.db"\n{extra}')
    return path


def test_config_reads_limits_metrics_logging_and_turn(tmp_path: Path) -> None:
    path = _write_config(
        tmp_path,
        'log_level = "debug"\nlog_format = "json"\n'
        "[limits]\nmax_devices_per_bridge = 3\n"
        "[metrics]\nport = 9743\n"
        '[turn]\nurls = ["turn:relay.example.com:3478?transport=udp", "turns:relay.example.com:443?transport=tcp"]\n',
    )
    config = config_mod.load(path)
    assert config.limits.max_devices_per_bridge == 3
    assert (config.metrics_host, config.metrics_port) == ("127.0.0.1", 9743)
    assert (config.log_level, config.log_format) == ("debug", "json")
    assert config.turn_ttl == config_mod.DEFAULT_TURN_TTL >= 3600 + 600
    assert config.turn_urls[1].startswith("turns:")


@pytest.mark.parametrize(
    "extra",
    ['log_level = "loud"\n', "[limits]\nmax_connections = -1\n", "[turn]\nttl = 30\n", '[turn]\nurls = ["http://x"]\n'],
)
def test_config_rejects_bad_settings(tmp_path: Path, extra: str) -> None:
    with pytest.raises(config_mod.ConfigError):
        config_mod.load(_write_config(tmp_path, extra))


def test_json_logs(capsys) -> None:
    logs.setup("info", "json")
    logging.getLogger("hermescall_relay.test").info("hello %s", "world")
    line = json.loads(capsys.readouterr().err.strip().splitlines()[-1])
    assert line["msg"] == "hello world" and line["level"] == "info"
    logs.setup()


# ---- client addresses behind proxies (Docker, Kubernetes, NPM) ----------

NETS = (ipaddress.ip_network("10.42.0.0/16"),)


@pytest.mark.parametrize(
    ("remote", "forwarded", "expected"),
    [
        ("203.0.113.9", "198.51.100.1", "203.0.113.9"),  # not a proxy: header ignored
        ("10.42.0.7", "198.51.100.1", "198.51.100.1"),
        ("10.42.0.7", "6.6.6.6, 198.51.100.1", "198.51.100.1"),  # client-supplied entry ignored
        ("10.42.0.7", "198.51.100.1, 10.42.3.3", "198.51.100.1"),  # two proxies of ours
        ("::ffff:10.42.0.7", "198.51.100.1", "198.51.100.1"),
        ("10.42.0.7", "garbage", "10.42.0.7"),
        ("127.0.0.1", "2001:db8::1", "2001:db8::1"),
    ],
)
def test_client_ip_walks_trusted_proxies(remote: str, forwarded: str, expected: str) -> None:
    assert netutil.client_ip(remote, forwarded, True, NETS) == expected


def test_client_ip_without_trust() -> None:
    assert netutil.client_ip("127.0.0.1", "198.51.100.1", False, NETS) == "127.0.0.1"


def test_compose_trusts_only_caddy_not_the_bridge_gateway() -> None:
    deploy = Path(__file__).parents[1] / "deploy"
    example = tomllib.loads((deploy / "compose" / "relay.toml.example").read_text())
    trusted = netutil.parse_networks(example["trusted_proxies"])
    compose = (deploy / "docker-compose.yml").read_text()
    caddy = compose.split("ipv4_address:", 1)[1].split()[0]
    subnet = ipaddress.ip_network(compose.split("subnet:", 1)[1].split()[0])
    assert ipaddress.ip_address(caddy) in subnet
    assert [str(net) for net in trusted] == [f"{caddy}/32"]
    assert not netutil.is_trusted(str(subnet.network_address + 1), trusted)  # the gateway
    # Forged X-Forwarded-For from the host (via the gateway) is not believed.
    assert netutil.client_ip(str(subnet.network_address + 1), "6.6.6.6", True, trusted) == str(subnet.network_address + 1)


# ---- health and metrics ---------------------------------------------------


async def test_healthz_reports_checks(client) -> None:
    body = await (await client.get("/healthz")).json()
    assert body == {"status": "ok", "version": VERSION, "checks": {"database": "ok", "disk": "ok", "push": "ok"}}


async def test_healthz_is_503_when_the_disk_is_full(client, relay, monkeypatch) -> None:
    monkeypatch.setattr(Store, "free_bytes_at", staticmethod(lambda path: 1))
    response = await client.get("/healthz")
    assert response.status == 503
    assert (await response.json())["checks"]["disk"] == "low"


async def test_healthz_is_503_when_the_database_is_not_writable(client, relay, monkeypatch) -> None:
    monkeypatch.setattr(relay.store, "writable", lambda: False)
    response = await client.get("/healthz")
    assert response.status == 503 and (await response.json())["status"] == "unhealthy"


async def test_healthz_degraded_when_the_gateway_is_down(client, relay) -> None:
    class Probe:
        async def reachable(self) -> bool:
            return False

    from hermescall_relay.push import GatewayPush

    relay.push = GatewayPush.__new__(GatewayPush)
    relay.gateway_probe = Probe()
    response = await client.get("/healthz")
    assert response.status == 200 and (await response.json())["status"] == "degraded"
    relay.push = None


async def test_metrics_are_only_on_the_metrics_app(aiohttp_client, client, relay) -> None:
    assert (await client.get("/metrics")).status == 404
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    replies = [await request(ws, {"t": "turn"}) for _ in range(7)]
    assert replies[-1]["code"] == "rate_limited"
    metrics = await aiohttp_client(relay.metrics_app())
    text = await (await metrics.get("/metrics")).text()
    assert f'hermescall_relay_build_info{{version="{VERSION}"}} 1' in text
    assert 'hermescall_relay_connections{role="bridge"} 1' in text
    assert 'hermescall_relay_rate_limited_total{limit="turn"} 1' in text
    assert 'hermescall_relay_paired{kind="bridge"} 1' in text
    assert "hermescall_relay_disk_free_bytes " in text
    assert "# TYPE hermescall_relay_push_total counter" in text


async def test_metrics_port_starts_with_the_relay(tmp_path: Path, aiohttp_client, unused_tcp_port) -> None:
    from hermescall_relay.server import Relay

    from .conftest import FakePush, make_config

    config = dataclasses.replace(make_config(tmp_path), metrics_port=unused_tcp_port)
    relay = Relay(config, Store(config.db_path), FakePush(), b"t")
    await aiohttp_client(relay.app())
    reader, writer = await asyncio.open_connection("127.0.0.1", unused_tcp_port)
    writer.write(b"GET /metrics HTTP/1.0\r\n\r\n")
    data = await reader.read()
    writer.close()
    assert b"200 OK" in data and b"hermescall_relay_build_info" in data


# ---- protocol versions ------------------------------------------------------


async def test_ready_carries_the_relay_version_and_caps(client, relay) -> None:
    from hermescall_common import auth

    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await client.ws_connect("/v1/ws")
    challenge = await recv(ws)
    sig = auth.sign_auth(bridge.sign_sk, HOST, "bridge", bridge.id, wire.b64d(challenge["nonce"]))
    hello = {"t": "auth", "role": "bridge", "id": bridge.id, "sig": wire.b64e(sig), "v": 2, "caps": ["x_future", 7, "B!"]}
    await send(ws, hello)
    ready = await recv(ws)
    assert ready == {"t": "ready", "v": 1, "relay": VERSION, "caps": list(CAPABILITIES)}
    assert relay.client_caps[bridge.id] == frozenset({"x_future"})


# ---- limits in action ---------------------------------------------------------


async def test_max_devices_per_bridge(client, relay) -> None:
    relay.limits = dataclasses.replace(relay.limits, max_devices_per_bridge=1)
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    await pair_device(client, ws)
    assert (await request(ws, {"t": "open_slot"}))["code"] == "too_many_devices"


async def test_expiry_sweep_removes_blob_files_and_mail(client, relay) -> None:
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, ws)
    ticket = await request(ws, {"t": "blob_put", "to": device.id, "size": 3})
    await client.put(f"/v1/blobs/{ticket['blob_id']}", data=b"abc", headers={"Authorization": f"Bearer {ticket['token']}"})
    await request(ws, {"t": "mail", "to": device.id, "id": mid(), "data": wire.b64e(b"hi")})
    assert (relay.blob_dir / ticket["blob_id"]).exists()
    relay.store._db.execute("UPDATE blobs SET created = created - ?", (relay.limits.blob_ttl_seconds + 1,))
    relay.store._db.execute("UPDATE mail SET created = created - ?", (relay.limits.mail_ttl_seconds + 1,))
    assert relay.expire_now() == (1, 1)
    assert not (relay.blob_dir / ticket["blob_id"]).exists()
    assert 'hermescall_relay_expired_total{kind="blob"} 1' in relay.metrics.render()


# ---- graceful shutdown ----------------------------------------------------------


async def test_shutdown_closes_sockets_and_sends_pending_alerts(client, relay, push) -> None:
    relay.limits = dataclasses.replace(relay.limits, mail_ack_grace=30.0)
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    await request(device_ws, {"t": "register_push", "token": TOKEN, "env": "production", "kind": "alert"})
    await request(bridge_ws, {"t": "mail", "to": device.id, "id": mid(), "data": wire.b64e(b"x"), "alert": True})
    assert push.alerts == []  # waiting for the phone's ack
    started = time.monotonic()
    await relay._shutdown(client.server.app)
    assert time.monotonic() - started < 5
    assert len(push.alerts) == 1
    message = await device_ws.receive(timeout=5)
    while message.type == WSMsgType.TEXT:
        message = await device_ws.receive(timeout=5)
    assert (message.type, message.data) == (WSMsgType.CLOSE, WSCloseCode.GOING_AWAY)


# ---- CLI --------------------------------------------------------------------------


def test_cli_devices_revoke_stats_backup(tmp_path: Path, capsys) -> None:
    path = _write_config(tmp_path, f'secrets_dir = "{tmp_path}"\n')
    store = Store(tmp_path / "relay.db")
    bridge = store.add_bridge(b"k" * 32)
    device = store.add_device(bridge, b"p" * 32)
    assert cli.main(["--config", str(path), "devices"]) == 0
    assert device in capsys.readouterr().out
    assert cli.main(["--config", str(path), "stats"]) == 0
    assert "bridges 1, devices 1" in capsys.readouterr().out
    assert cli.main(["--config", str(path), "revoke-device", device]) == 0
    assert store.device(device) is None
    assert cli.main(["--config", str(path), "revoke-device", device]) == 1
    archive = tmp_path / "backup" / "relay.tar.gz"
    assert cli.main(["--config", str(path), "backup", str(archive)]) == 0
    assert archive.exists()
    store.delete_bridge(bridge)
    store.close()
    assert cli.main(["--config", str(path), "restore", str(archive)]) == 0
    assert Store(tmp_path / "relay.db").bridge_key(bridge) == b"k" * 32
    assert cli.main(["--config", str(path), "compact"]) == 0


def test_doctor_reports_and_fails_on_failures(tmp_path: Path, capsys) -> None:
    config = config_mod.load(_write_config(tmp_path, f'secrets_dir = "{tmp_path}"\n'))
    results = doctor.run(config, (doctor.check_database, doctor.check_disk, doctor.check_push, lambda c: 1 / 0))
    assert [r.status for r in results[:2]] == ["ok", "ok"]
    assert results[2].status == "fail" and "push_gateway_key missing" in results[2].detail
    assert results[3].status == "fail" and "crashed" in results[3].detail
    assert doctor.report(results) == 1
    assert "FAIL" in capsys.readouterr().out


def test_doctor_flags_clock_skew() -> None:
    from email.utils import formatdate

    assert doctor._clock(formatdate(time.time() - 120, usegmt=True), "https://gw").status == "fail"
    assert doctor._clock(formatdate(time.time(), usegmt=True), "https://gw").status == "ok"


def test_doctor_turn_answers_stun(tmp_path: Path) -> None:
    import socket
    import threading

    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]

    def answer() -> None:
        data, peer = server.recvfrom(64)
        server.sendto(b"\x01\x01\x00\x00" + data[4:20], peer)

    threading.Thread(target=answer, daemon=True).start()
    (tmp_path / "turn_secret").write_text("s")
    config = config_mod.load(
        _write_config(tmp_path, f'secrets_dir = "{tmp_path}"\n[turn]\nurls = ["turn:127.0.0.1:{port}?transport=udp"]\n')
    )
    result = doctor.check_turn(config)
    server.close()
    assert result.status == "ok", result


def test_local_config_overrides_the_installer_file(tmp_path: Path) -> None:
    path = _write_config(tmp_path, '[turn]\nurls = ["turn:a:3478"]\nttl = 600\n[limits]\nmax_connections = 300\n')
    config_mod.local_path(path).write_text('log_format = "json"\n[turn]\nttl = 7200\n[limits]\nmax_devices_per_bridge = 2\n')
    config = config_mod.load(path)
    assert config.turn_ttl == 7200 and config.turn_urls == ("turn:a:3478",)
    assert config.limits.max_connections == 300 and config.limits.max_devices_per_bridge == 2
    assert config.log_format == "json"
