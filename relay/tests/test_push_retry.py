"""APNs and push gateway delivery: transient errors are retried with backoff, final answers are not."""

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from hermescall_relay.push import DirectApns, GatewayPush, PushResult

from .test_units import APNS, TOKEN, p8


def _apns(responses: list, stats: dict | None = None) -> tuple[DirectApns, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        item = responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    pem, _ = p8()
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return DirectApns(APNS, pem, client, retry_delays=(0, 0)), seen


@pytest.mark.parametrize(
    "first",
    [
        httpx.Response(429, json={"reason": "TooManyRequests"}),
        httpx.Response(500, json={"reason": "InternalServerError"}),
        httpx.Response(503, json={"reason": "ServiceUnavailable"}),
        httpx.ConnectError("down"),
    ],
)
async def test_apns_retries_transient_errors(first) -> None:
    apns, seen = _apns([first, httpx.Response(200)])
    assert await apns.send_voip(TOKEN, "production", "CALL") is PushResult.OK
    assert len(seen) == 2
    # Each attempt is a fresh request with the same apns-id, so Apple can de-duplicate.
    assert seen[0].headers["apns-id"] == seen[1].headers["apns-id"]


async def test_apns_gives_up_after_the_last_retry() -> None:
    apns, seen = _apns([httpx.Response(503)] * 3)
    assert await apns.send_alert(TOKEN, "sandbox", None) is PushResult.FAILED
    assert len(seen) == 3
    assert apns.stats == {"retry": 2, "failed": 1}


@pytest.mark.parametrize(
    ("response", "result"),
    [
        (httpx.Response(400, json={"reason": "BadDeviceToken"}), PushResult.INVALID_TOKEN),
        (httpx.Response(400, json={"reason": "PayloadTooLarge"}), PushResult.FAILED),
        (httpx.Response(403, json={"reason": "InvalidProviderToken"}), PushResult.FAILED),
        (httpx.Response(410, json={"reason": "Unregistered"}), PushResult.INVALID_TOKEN),
    ],
)
async def test_apns_does_not_retry_final_answers(response, result) -> None:
    apns, seen = _apns([response, httpx.Response(200)])
    assert await apns.send_voip(TOKEN, "production", "CALL") is result
    assert len(seen) == 1


async def test_apns_honours_a_short_retry_after(monkeypatch) -> None:
    slept: list[float] = []

    async def fake_sleep(delay: float) -> None:
        slept.append(delay)

    monkeypatch.setattr("hermescall_relay.push.asyncio.sleep", fake_sleep)
    apns, _ = _apns([httpx.Response(429, headers={"retry-after": "2"}), httpx.Response(200)])
    assert await apns.send_voip(TOKEN, "production", "CALL") is PushResult.OK
    assert slept == [2.0]
    apns, _ = _apns([httpx.Response(429, headers={"retry-after": "3600"}), httpx.Response(200)])
    assert await apns.send_voip(TOKEN, "production", "CALL") is PushResult.FAILED


def _gateway(responses: list) -> tuple[GatewayPush, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        item = responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    pem = Ed25519PrivateKey.generate().private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return GatewayPush("https://gw.test", pem, client, retry_delays=(0, 0)), seen


async def test_gateway_push_retries_outages_with_a_fresh_signature() -> None:
    push, seen = _gateway([httpx.ConnectError("down"), httpx.Response(502), httpx.Response(200, json={"result": "ok"})])
    assert await push.send_voip(TOKEN, "production", "AAAAAAAAAAAAAAAAAAAAAA") is PushResult.OK
    assert len({r.headers["authorization"] for r in seen}) == 3


@pytest.mark.parametrize("status", [400, 401, 403, 413, 429])
async def test_gateway_push_does_not_retry_refusals(status) -> None:
    push, seen = _gateway([httpx.Response(status, json={"error": "x"}), httpx.Response(200, json={"result": "ok"})])
    assert await push.send_voip(TOKEN, "production", "AAAAAAAAAAAAAAAAAAAAAA") is PushResult.FAILED
    assert len(seen) == 1
