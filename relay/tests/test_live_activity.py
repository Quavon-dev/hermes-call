"""Live Activity pushes (M9): per-activity and push-to-start tokens, `live_update` from the bridge."""

import asyncio
import json

import httpx
import pytest

from hermescall_relay import server as relay_server
from hermescall_relay.push import PushResult, live_activity_payload

from .conftest import connect, pair_bridge, pair_device, request
from .test_units import TOKEN, apns_with

LA_TOKEN = "ab" * 32
START_TOKEN = "ef" * 40
STATE = {"step": 2, "total": None, "label": "Working…", "state": "running", "startedAt": 1_790_000_000.5}


async def paired_device(client, relay, register: bool = True):
    bridge = await pair_bridge(client, relay.store.create_relay_code())
    bridge_ws = await connect(client, "bridge", bridge)
    device = await pair_device(client, bridge_ws)
    device_ws = await connect(client, "device", device)
    if register:
        for kind, token in (("liveactivity", LA_TOKEN), ("liveactivity_start", START_TOKEN)):
            reply = await request(device_ws, {"t": "register_push", "token": token, "env": "sandbox", "kind": kind})
            assert reply == {"t": "push_registered", "kind": kind}
    return bridge_ws, device, device_ws


def update(device_id: str, event: str, state: dict | None = None) -> dict:
    return {"t": "live_update", "to": device_id, "event": event, "content_state": state or STATE}


async def test_start_update_end_use_the_right_tokens(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    assert await request(bridge_ws, update(device.id, "start")) == {"t": "live_updated"}
    assert await request(bridge_ws, update(device.id, "update")) == {"t": "live_updated"}
    assert await request(bridge_ws, update(device.id, "end", {**STATE, "state": "done"})) == {"t": "live_updated"}
    assert [(token, event) for token, _, event, _ in push.live] == [
        (START_TOKEN, "start"),
        (LA_TOKEN, "update"),
        (LA_TOKEN, "end"),
    ]
    assert push.live[0][3] == STATE and push.live[0][1] == "sandbox"
    assert push.sent == [] and push.alerts == []


async def test_updates_starts_and_ends_are_rate_limited(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    assert (await request(bridge_ws, update(device.id, "update")))["t"] == "live_updated"
    assert await request(bridge_ws, update(device.id, "update")) == {"t": "error", "code": "rate_limited"}
    assert (await request(bridge_ws, update(device.id, "start")))["t"] == "live_updated"
    assert await request(bridge_ws, update(device.id, "start")) == {"t": "error", "code": "rate_limited"}  # 1 per 30 s
    for _ in range(30):
        assert (await request(bridge_ws, update(device.id, "end")))["t"] == "live_updated"
    assert await request(bridge_ws, update(device.id, "end")) == {"t": "error", "code": "rate_limited"}  # 30 per hour
    assert len(push.live) == 32


async def test_hourly_start_limit(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    short, hourly = relay.live_limits["start"]
    short._window = 0.0  # only the hourly limit applies
    for _ in range(20):
        assert (await request(bridge_ws, update(device.id, "start")))["t"] == "live_updated"
    assert await request(bridge_ws, update(device.id, "start")) == {"t": "error", "code": "rate_limited"}


async def test_missing_token_and_foreign_device(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay, register=False)
    assert await request(bridge_ws, update(device.id, "start")) == {"t": "error", "code": "no_token"}
    other = await pair_bridge(client, relay.store.create_relay_code())
    other_ws = await connect(client, "bridge", other)
    assert await request(other_ws, update(device.id, "start")) == {"t": "error", "code": "unknown_device"}
    assert push.live == []


async def test_invalid_token_is_dropped(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    push.invalid.add(LA_TOKEN)
    assert await request(bridge_ws, update(device.id, "end")) == {"t": "error", "code": "no_token"}
    stored = relay.store.device(device.id)
    assert stored.la_token is None and stored.la_start_token == START_TOKEN
    assert await request(bridge_ws, update(device.id, "end")) == {"t": "error", "code": "no_token"}


@pytest.mark.parametrize(
    "state",
    [
        {**STATE, "args": "secret"},
        {**STATE, "step": 1000},
        {**STATE, "step": True},
        {**STATE, "label": "x" * 61},
        {**STATE, "state": "paused"},
        {**STATE, "startedAt": "now"},
        {**STATE, "total": "3"},
        {k: v for k, v in STATE.items() if k != "label"},
        "not an object",
    ],
)
async def test_content_state_is_validated_strictly(client, relay, push, state) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    reply = await request(bridge_ws, {**update(device.id, "update"), "content_state": state})
    assert reply == {"t": "error", "code": "invalid_content_state"}
    assert push.live == []


async def test_bad_event_is_rejected(client, relay, push) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    assert await request(bridge_ws, update(device.id, "pause")) == {"t": "error", "code": "invalid_content_state"}


async def test_devices_cannot_send_live_updates(client, relay, push) -> None:
    _, device, device_ws = await paired_device(client, relay)
    await device_ws.send_str(json.dumps(update(device.id, "start")))
    await asyncio.sleep(0.1)
    assert push.live == []


async def test_push_disabled(client, relay) -> None:
    bridge_ws, device, _ = await paired_device(client, relay)
    relay.push = None
    assert await request(bridge_ws, update(device.id, "start")) == {"t": "error", "code": "push_disabled"}


def test_payload_shapes() -> None:
    start = json.loads(live_activity_payload("start", STATE, now=1000))
    assert start == {
        "aps": {
            "timestamp": 1000,
            "event": "start",
            "content-state": STATE,
            "attributes-type": "HermesTaskAttributes",
            "attributes": {},
            "alert": {"title": "Working…", "body": ""},
        }
    }
    assert json.loads(live_activity_payload("update", STATE, now=1000)) == {
        "aps": {"timestamp": 1000, "event": "update", "content-state": STATE}
    }
    end = json.loads(live_activity_payload("end", STATE, now=1000))
    assert end["aps"]["dismissal-date"] == 1900 and end["aps"]["event"] == "end"


async def test_apns_live_activity_headers() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200)

    apns, _ = apns_with(handler)
    assert await apns.send_live_activity(TOKEN, "sandbox", "update", STATE) is PushResult.OK
    assert await apns.send_live_activity(TOKEN, "production", "start", STATE) is PushResult.OK
    update_request, start_request = seen
    assert update_request.headers["apns-push-type"] == "liveactivity"
    assert update_request.headers["apns-topic"] == "de.quavon.hermescall.push-type.liveactivity"
    assert update_request.headers["apns-priority"] == "5"
    assert start_request.headers["apns-priority"] == "10"
    assert start_request.url.host == "api.push.apple.com"
    assert json.loads(update_request.content)["aps"]["content-state"] == STATE


async def test_rate_limit_window(client, relay, push) -> None:
    relay.live_limits["update"] = [relay_server.RateLimiter(limit=1, window=0.05)]
    bridge_ws, device, _ = await paired_device(client, relay)
    assert (await request(bridge_ws, update(device.id, "update")))["t"] == "live_updated"
    await asyncio.sleep(0.06)
    assert (await request(bridge_ws, update(device.id, "update")))["t"] == "live_updated"
