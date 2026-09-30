"""Push gateway abuse protection: soft token binding, persistent replay cache, blocklist reload, health."""

import dataclasses
import json
import time
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from hermescall_relay import gateway_state, observability, pushauth
from hermescall_relay.gateway import PushGateway, load_gateway
from hermescall_relay.gateway_state import GatewayState

from .conftest import FakePush
from .test_push_gateway import CALL_ID, TOKEN, gateway_config, post


def voip(token: str = TOKEN, **extra) -> dict:
    return {"kind": "voip", "token": token, "env": "production", "call_id": CALL_ID, **extra}


@pytest.fixture
async def gw(aiohttp_client, tmp_path: Path):
    sent = FakePush()
    config = dataclasses.replace(gateway_config(), state_path=tmp_path / "gateway.db")
    gateway = PushGateway(config, sent)
    return gateway, await aiohttp_client(gateway.app()), sent


async def test_legacy_token_allows_a_few_relays_then_refuses(gw) -> None:
    gateway, client, sent = gw
    relays = [Ed25519PrivateKey.generate() for _ in range(gateway_state.MAX_RELAYS_PER_TOKEN + 1)]
    statuses = [(await post(client, key, voip())).status for key in relays]
    assert statuses == [200] * gateway_state.MAX_RELAYS_PER_TOKEN + [403]
    response = await post(client, relays[-1], voip())
    assert (await response.json()) == {"error": "token_bound"}
    # The relays that already use it keep working.
    assert (await post(client, relays[0], voip())).status == 200
    assert len(sent.sent) == gateway_state.MAX_RELAYS_PER_TOKEN + 1


def test_relay_slots_free_up_after_the_window(tmp_path: Path) -> None:
    state = GatewayState(tmp_path / "gateway.db")
    for n in range(gateway_state.MAX_RELAYS_PER_TOKEN):
        assert state.check_token(TOKEN, f"relay{n}", now=1000).allowed
    assert not state.check_token(TOKEN, "late", now=2000).allowed
    assert state.check_token(TOKEN, "relay0", now=2000).allowed
    later = 1000 + gateway_state.RELAY_WINDOW + 1
    assert state.check_token(TOKEN, "late", now=later).allowed


async def test_rate_limited_push_records_no_binding(gw) -> None:
    gateway, client, sent = gw
    first = Ed25519PrivateKey.generate()
    assert [(await post(client, first, voip())).status for _ in range(10)] == [200] * 10
    before = gateway.state._db.execute("SELECT relay, last_used FROM token_relays").fetchall()
    assert (await post(client, Ed25519PrivateKey.generate(), voip())).status == 429
    assert (await post(client, first, voip())).status == 429
    assert gateway.state._db.execute("SELECT relay, last_used FROM token_relays").fetchall() == before


def test_a_relay_that_delivered_replaces_the_oldest_stale_binding() -> None:
    state = GatewayState(None)
    for n in range(gateway_state.MAX_RELAYS_PER_TOKEN):
        assert state.check_token(TOKEN, f"relay{n}", now=1000 + n).allowed
    fresh = 1000 + gateway_state.STALE_BINDING - 10
    state.mark_delivered("moved", now=fresh)
    assert not state.token_allowed(TOKEN, "moved", now=fresh).allowed  # nothing stale yet
    later = 1000 + gateway_state.STALE_BINDING + 1
    assert not state.token_allowed(TOKEN, "unproven", now=later).allowed
    state.mark_delivered("moved", now=later)
    assert state.token_allowed(TOKEN, "moved", now=later).allowed
    state.record_token(TOKEN, "moved", now=later)
    relays = {row[0] for row in state._db.execute("SELECT relay FROM token_relays")}
    assert relays == {"relay1", "relay2", "relay3", "relay4", "moved"}  # relay0 was the oldest
    # A relay whose pushes to this token failed (410) has no delivery to show.
    state.forget(TOKEN)
    assert state.counts()["tokens"] == 0


async def test_unknown_fields_are_refused(gw) -> None:
    _, client, sent = gw
    relay = Ed25519PrivateKey.generate()
    assert (await post(client, relay, {**voip(), "bind": {}})).status == 400
    assert not sent.sent


async def test_replay_cache_survives_a_restart(aiohttp_client, tmp_path: Path) -> None:
    config = dataclasses.replace(gateway_config(), state_path=tmp_path / "gateway.db")
    key = Ed25519PrivateKey.generate()
    body = json.dumps(voip()).encode()
    header = {"Authorization": pushauth.sign(key, body)}
    first = await aiohttp_client(PushGateway(config, FakePush()).app())
    assert (await first.post("/v1/push", data=body, headers=header)).status == 200
    await first.close()
    restarted = await aiohttp_client(PushGateway(config, FakePush()).app())
    response = await restarted.post("/v1/push", data=body, headers=header)
    assert response.status == 401 and (await response.json()) == {"error": "replayed"}


def test_invalid_tokens_are_forgotten() -> None:
    state = GatewayState(None)
    for n in range(gateway_state.MAX_RELAYS_PER_TOKEN):
        state.check_token(TOKEN, f"relay{n}", now=1)
    state.forget(TOKEN)
    assert state.check_token(TOKEN, "other", now=2).allowed
    assert state.counts()["tokens"] == 1


def test_state_stores_no_raw_tokens(tmp_path: Path) -> None:
    path = tmp_path / "gateway.db"
    state = GatewayState(path)
    state.check_token(TOKEN, "relay", now=time.time())
    state.close()
    assert TOKEN.encode() not in path.read_bytes()


def test_prune_forgets_old_rows(tmp_path: Path) -> None:
    state = GatewayState(None)
    state.check_token(TOKEN, "r", now=1)
    state.remember_signature(b"s" * 64, now=1)
    state.prune(now=1 + gateway_state.FORGET_AFTER + 1)
    assert state.counts() == {"tokens": 0, "seen_signatures": 0}


async def test_blocklist_reloads_from_file(aiohttp_client, tmp_path: Path) -> None:
    config_path = tmp_path / "gateway.toml"
    blocklist = tmp_path / "blocked.txt"
    config_path.write_text(
        f'blocklist_path = "{blocklist}"\n[apns]\nkey_id = "KEY1234567"\nteam_id = "TEAM123456"\ntopic = "a.b.voip"\n'
    )
    config = load_gateway(config_path)
    gateway = PushGateway(config, FakePush())
    client = await aiohttp_client(gateway.app())
    bad = Ed25519PrivateKey.generate()
    assert (await post(client, bad, voip())).status == 200
    blocklist.write_text(f"# abuse report 2026-09-30\n{pushauth.relay_id(bad)}\n")
    gateway._reload_if_changed()
    assert (await post(client, bad, voip())).status == 403
    config_path.write_text(config_path.read_text().replace("[apns]", f'blocked_relays = ["{"A" * 43}"]\n[apns]'))
    gateway.reload_blocklist()  # what SIGHUP does
    assert "A" * 43 in gateway.blocked and pushauth.relay_id(bad) in gateway.blocked


async def test_gateway_health_and_metrics(gw, aiohttp_client, monkeypatch) -> None:
    gateway, client, _ = gw
    body = await (await client.get("/healthz")).json()
    assert body["status"] == "ok" and body["checks"] == {"state": "ok"}
    await post(client, Ed25519PrivateKey.generate(), voip())
    metrics = await aiohttp_client(gateway.metrics_app())
    text = await (await metrics.get("/metrics")).text()
    assert 'hermescall_gateway_requests_total{outcome="ok"} 1' in text
    assert 'hermescall_gateway_state_rows{kind="tokens"} 1' in text
    assert (await client.get("/metrics")).status == 404
    monkeypatch.setattr(gateway.state, "writable", lambda: False)
    assert (await client.get("/healthz")).status == 200  # cached for a few seconds
    monkeypatch.setattr(gateway, "health_cache", observability.HealthCache())
    assert (await client.get("/healthz")).status == 503


async def test_gateway_healthz_is_cached_rate_limited_and_hides_the_version(gw, monkeypatch) -> None:
    from hermescall_relay import observability
    from hermescall_relay.version import VERSION

    gateway, client, _ = gw
    calls = []
    real = gateway.state.writable
    monkeypatch.setattr(gateway.state, "writable", lambda: calls.append(1) or real())
    proxied = {"X-Forwarded-For": "198.51.100.7"}
    public = await (await client.get("/healthz", headers=proxied)).json()
    assert public == {"status": "ok", "checks": {"state": "ok"}}
    assert (await (await client.get("/healthz")).json())["version"] == VERSION  # local probe
    assert len(calls) == 1
    limit = observability.HEALTH_RATE[1]
    statuses = [(await client.get("/healthz", headers={"X-Forwarded-For": "198.51.100.8"})).status for _ in range(limit + 1)]
    assert statuses == [200] * limit + [429]


async def test_unreadable_blocklist_keeps_the_previous_one(tmp_path: Path) -> None:
    blocklist = tmp_path / "blocked.txt"
    blocklist.write_text("A" * 43 + "\n")
    config = dataclasses.replace(gateway_config(), blocklist_path=blocklist)
    gateway = PushGateway(config, FakePush())
    assert "A" * 43 in gateway.blocked
    blocklist.write_bytes(b"\xff\xfe broken")
    assert not gateway.reload_blocklist()
    assert "A" * 43 in gateway.blocked


async def test_missing_blocklist_keeps_the_previous_one_and_logs_an_error(tmp_path: Path, caplog) -> None:
    blocklist = tmp_path / "blocked.txt"
    blocklist.write_text("A" * 43 + "\n")
    gateway = PushGateway(dataclasses.replace(gateway_config(), blocklist_path=blocklist), FakePush())
    blocklist.unlink()
    assert not gateway.reload_blocklist()
    assert "A" * 43 in gateway.blocked
    assert any(record.levelname == "ERROR" and "blocklist" in record.getMessage() for record in caplog.records)


def test_gateway_starts_with_a_missing_blocklist_but_says_so(tmp_path: Path, caplog) -> None:
    config = dataclasses.replace(gateway_config(frozenset({"B" * 43})), blocklist_path=tmp_path / "missing")
    gateway = PushGateway(config, FakePush())
    assert gateway.blocked == {"B" * 43}
    assert any(record.levelname == "ERROR" and "blocklist" in record.getMessage() for record in caplog.records)


def test_unblock_replaces_the_blocklist_atomically(tmp_path: Path) -> None:
    import shutil
    import subprocess

    script = Path(__file__).parents[1] / "push-gateway-install.sh"
    function = script.read_text().split("\ncmd_unblock() {", 1)[1].split("\n}\n", 1)[0]
    blocklist = tmp_path / "blocked_relays"
    keep, drop = "A" * 43, "B" * 43
    blocklist.write_text(f"# reported\n{keep}\n{drop}\n")
    inode = blocklist.stat().st_ino
    harness = f"""
set -Eeuo pipefail
ETC={tmp_path}; SERVICE_USER=$(id -gn)
need_root() {{ :; }}; die() {{ echo "$*" >&2; exit 1; }}; log() {{ :; }}
chown() {{ :; }}; systemctl() {{ :; }}
cmd_unblock() {{{function}
}}
cmd_unblock {drop}
"""
    subprocess.run([shutil.which("bash") or "/bin/bash", "-c", harness], check=True)
    assert blocklist.read_text() == f"# reported\n{keep}\n"
    assert blocklist.stat().st_ino != inode  # a new file moved into place, never truncated in place
    assert oct(blocklist.stat().st_mode & 0o777) == "0o640"
    assert not list(tmp_path.glob(".blocked_relays.*"))


# ---- replay cache pressure (a signed flood must not lock out everyone) -----------------------


def gateway_limiter(limit: int):
    from hermescall_relay.ratelimit import RateLimiter

    return RateLimiter(limit=limit, window=gateway_state.REPLAY_SECONDS, evict=True)


async def test_invalid_bodies_are_not_remembered(gw) -> None:
    gateway, client, sent = gw
    relay = Ed25519PrivateKey.generate()
    for body in ({**voip(), "bind": {}}, {"kind": "voip"}, [1]):
        assert (await post(client, relay, body)).status == 400
    assert gateway.state.counts()["seen_signatures"] == 0 and not sent.sent


def test_replay_cache_is_large_and_stores_short_hashes() -> None:
    assert gateway_state.MAX_SEEN >= 2_000_000
    state = GatewayState(None)
    assert state.remember_signature(b"s" * 64, now=1) == "new"
    assert state.remember_signature(b"s" * 64, now=2) == "replayed"
    assert [len(row[0]) for row in state._db.execute("SELECT sig FROM seen")] == [gateway_state.SEEN_HASH_BYTES]
    assert state.seen_count == 1


def test_replay_cache_from_schema_1_still_detects_replays(tmp_path: Path) -> None:
    import hashlib
    import sqlite3

    path = tmp_path / "gateway.db"
    old = sqlite3.connect(path, isolation_level=None)
    old.execute("CREATE TABLE seen(sig BLOB PRIMARY KEY, expires INTEGER NOT NULL) WITHOUT ROWID")
    old.execute("INSERT INTO seen VALUES(?, ?)", (hashlib.sha256(b"s" * 64).digest(), 500))
    old.execute("PRAGMA user_version = 1")
    old.close()
    state = GatewayState(path)
    assert state.seen_signature(b"s" * 64, now=100) and state.remember_signature(b"s" * 64, now=100) == "replayed"
    assert state.seen_count == 1


async def test_under_pressure_only_relays_that_delivered_get_in(gw, monkeypatch) -> None:
    gateway, client, sent = gw
    monkeypatch.setattr(gateway_state, "PRESSURE_SEEN", 3)
    proven = Ed25519PrivateKey.generate()
    assert (await post(client, proven, voip())).status == 200  # a real delivery
    flood = Ed25519PrivateKey.generate()
    sent.invalid.update(f"{n:064x}" for n in range(4))  # made-up tokens: APNs never accepts them
    statuses = [(await post(client, flood, voip(f"{n:064x}"))).status for n in range(4)]
    assert statuses == [200, 200, 503, 503]
    assert (await post(client, Ed25519PrivateKey.generate(), voip())).status == 503
    assert (await post(client, proven, voip())).status == 200  # not locked out
    assert gateway.state.seen_count == 4


async def test_replay_entries_are_capped_per_relay_and_per_prefix(gw, monkeypatch) -> None:
    gateway, client, sent = gw
    monkeypatch.setattr(gateway, "seen_per_relay", gateway_limiter(2))
    monkeypatch.setattr(gateway, "seen_per_prefix", gateway_limiter(3))
    relay = Ed25519PrivateKey.generate()
    statuses = [(await post(client, relay, voip(f"{n:064x}"))).status for n in range(3)]
    assert statuses == [200, 200, 429]
    other = Ed25519PrivateKey.generate()
    statuses = [(await post(client, other, voip(f"{n:064x}"))).status for n in range(10, 13)]
    assert statuses == [200, 429, 429]  # 127.0.0.1's prefix already has 2 of 3
    assert gateway.state.seen_count == 3


def test_prefix_key_groups_ipv4_by_24_and_ipv6_by_48() -> None:
    from hermescall_relay.netutil import key

    assert key("203.0.113.9", 48, 24) == key("203.0.113.200", 48, 24) == "203.0.113.0/24"
    assert key("2001:db8:1:2::1", 48, 24) == "2001:db8:1::/48"
    assert key("203.0.113.9", 48) == "203.0.113.9"
