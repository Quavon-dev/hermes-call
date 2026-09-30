"""Push gateway abuse protection: soft token binding, persistent replay cache, blocklist reload, health."""

import dataclasses
import json
import time
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from hermescall_relay import gateway_state, pushauth
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
    assert (await client.get("/healthz")).status == 503
