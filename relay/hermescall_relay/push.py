"""VoIP, alert and Live Activity push delivery.

`DirectApns` talks to Apple with the relay's own .p8 key. `GatewayPush` is for
relays without one: it forwards the same opaque fields to the push gateway
(`gateway.py`, run by the app's publisher), which holds the app's key. VoIP payloads are always `{"c": call_id}`;
chat alerts carry a generic text plus, when it fits, the E2E ciphertext that
only the phone's notification extension can open. Live Activity pushes are
plaintext to Apple: the bridge sends only step, total, state, start time and a
label (generic unless the owner allows details), and the relay checks exactly
those keys.
"""

import asyncio
import enum
import json
import logging
import time
import uuid
from collections import Counter
from typing import Protocol

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from hermescall_common.wire import b64e

from . import pushauth
from .config import ApnsConfig

log = logging.getLogger(__name__)

APNS_HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
JWT_LIFETIME_SECONDS = 40 * 60
PUSH_EXPIRY_SECONDS = 30
ALERT_EXPIRY_SECONDS = 7 * 86_400
# APNs allows 4 KiB of payload; the rest of the JSON needs about 250 bytes.
MAX_ALERT_CIPHERTEXT = 3600
LIVE_EVENTS = ("start", "update", "end")
LIVE_ATTRIBUTES_TYPE = "HermesTaskAttributes"
LIVE_START_ALERT = {"title": "Working…", "body": ""}
# How long an ended activity stays on the Lock Screen.
LIVE_DISMISS_SECONDS = 900
LIVE_EXPIRY_SECONDS = {"start": 3600, "update": 600, "end": 3600}
_INVALID_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}
# Transient failures are retried after these pauses (a VoIP push expires after 30 s, so the whole
# budget stays short). APNs 400/403/404/410/413 and gateway refusals are final and never retried.
RETRY_DELAYS = (0.25, 1.0)
APNS_RETRY_STATUSES = frozenset({429, 500, 503})
GATEWAY_RETRY_STATUSES = frozenset({500, 502, 503, 504})
# A Retry-After longer than this means "not now": give up instead of holding the ring.
MAX_RETRY_AFTER = 5.0


class PushResult(enum.Enum):
    OK = "ok"
    INVALID_TOKEN = "invalid_token"  # noqa: S105
    FAILED = "failed"


def _retry_after(response: httpx.Response, default: float) -> float | None:
    """The pause before the next attempt, or None when the server asks for more than we can wait."""
    header = response.headers.get("retry-after", "")
    if not header.isdigit():
        return default
    delay = float(header)
    return delay if delay <= MAX_RETRY_AFTER else None


class _Retrying:
    """Shared retry loop; subclasses send one attempt and say whether it may be repeated."""

    def __init__(self, retry_delays: tuple[float, ...]) -> None:
        self._delays = retry_delays
        # Outcome counters for /metrics: result names, plus "retry" per repeated attempt.
        self.stats: Counter[str] = Counter()
        # Last-attempt HTTP status (or "error") per push, for /metrics.
        self.statuses: Counter[str] = Counter()

    async def _with_retries(self, attempt) -> PushResult:
        for index in range(len(self._delays) + 1):
            result, retry_in = await attempt()
            if result is not None:
                self.stats[result.value] += 1
                return result
            if index == len(self._delays) or retry_in is None:
                break
            self.stats["retry"] += 1
            await asyncio.sleep(max(retry_in, self._delays[index]) if retry_in else self._delays[index])
        self.stats[PushResult.FAILED.value] += 1
        return PushResult.FAILED


class PushSender(Protocol):
    async def send_voip(self, token: str, env: str, call_id: str) -> PushResult: ...

    async def send_alert(self, token: str, env: str, ciphertext: str | None) -> PushResult: ...

    async def send_live_activity(self, token: str, env: str, event: str, content_state: dict) -> PushResult: ...

    async def close(self) -> None: ...


def voip_payload(call_id: str) -> bytes:
    return json.dumps({"c": call_id}, separators=(",", ":")).encode()


def alert_payload(ciphertext: str | None) -> bytes:
    """Apple sees only this generic text; the phone replaces it after decrypting `e`."""
    body: dict = {
        "aps": {
            "alert": {"title": "New message", "body": "Open Hermes Call to read it."},
            "sound": "default",
            "mutable-content": 1,
            "thread-id": "chat",
        }
    }
    if ciphertext and len(ciphertext) <= MAX_ALERT_CIPHERTEXT:
        body["e"] = ciphertext
    return json.dumps(body, separators=(",", ":")).encode()


def live_activity_payload(event: str, content_state: dict, now: int | None = None) -> bytes:
    """ActivityKit push: `start` (push-to-start token) creates the activity, `update`/`end` change it."""
    now = int(time.time()) if now is None else now
    aps: dict = {"timestamp": now, "event": event, "content-state": content_state}
    if event == "start":
        aps.update({"attributes-type": LIVE_ATTRIBUTES_TYPE, "attributes": {}, "alert": LIVE_START_ALERT})
    elif event == "end":
        aps["dismissal-date"] = now + LIVE_DISMISS_SECONDS
    return json.dumps({"aps": aps}, separators=(",", ":"), ensure_ascii=False).encode()


class DirectApns(_Retrying):
    def __init__(
        self,
        config: ApnsConfig,
        key_pem: bytes,
        client: httpx.AsyncClient | None = None,
        retry_delays: tuple[float, ...] = RETRY_DELAYS,
    ) -> None:
        super().__init__(retry_delays)
        key = serialization.load_pem_private_key(key_pem, password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
            raise ValueError("APNs key must be an ES256 (.p8) key")
        self._config = config
        self._key = key
        self._client = client or httpx.AsyncClient(http2=True, timeout=10.0)
        self._jwt = ""
        self._jwt_issued = 0.0

    def _token(self) -> str:
        now = time.time()
        if now - self._jwt_issued < JWT_LIFETIME_SECONDS:
            return self._jwt
        header = b64e(json.dumps({"alg": "ES256", "kid": self._config.key_id}).encode())
        claims = b64e(json.dumps({"iss": self._config.team_id, "iat": int(now)}).encode())
        signing_input = f"{header}.{claims}".encode()
        r, s = decode_dss_signature(self._key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
        self._jwt = f"{header}.{claims}.{b64e(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
        self._jwt_issued = now
        return self._jwt

    async def send_voip(self, token: str, env: str, call_id: str) -> PushResult:
        return await self._post(token, env, voip_payload(call_id), "voip", self._config.topic, PUSH_EXPIRY_SECONDS)

    async def send_alert(self, token: str, env: str, ciphertext: str | None) -> PushResult:
        topic = self._config.topic.removesuffix(".voip")
        return await self._post(token, env, alert_payload(ciphertext), "alert", topic, ALERT_EXPIRY_SECONDS)

    async def send_live_activity(self, token: str, env: str, event: str, content_state: dict) -> PushResult:
        topic = f"{self._config.topic.removesuffix('.voip')}.push-type.liveactivity"
        payload = live_activity_payload(event, content_state)
        # Apple budgets priority 10; routine updates go at 5.
        priority = 5 if event == "update" else 10
        return await self._post(token, env, payload, "liveactivity", topic, LIVE_EXPIRY_SECONDS[event], priority)

    async def _post(
        self, token: str, env: str, payload: bytes, kind: str, topic: str, expiry: int, priority: int = 10
    ) -> PushResult:
        # The same apns-id on every attempt: Apple reports it back, and logs can match retries.
        push_id = str(uuid.uuid4())
        expiration = str(int(time.time()) + expiry)
        url = f"{APNS_HOSTS[env]}/3/device/{token}"

        async def attempt() -> tuple[PushResult | None, float | None]:
            headers = {
                "authorization": f"bearer {self._token()}",
                "apns-id": push_id,
                "apns-topic": topic,
                "apns-push-type": kind,
                "apns-priority": str(priority),
                "apns-expiration": expiration,
            }
            try:
                response = await self._client.post(url, content=payload, headers=headers)
            except httpx.HTTPError as exc:
                log.warning("apns request failed: %s", type(exc).__name__)
                self.statuses["error"] += 1
                return None, 0.0
            self.statuses[str(response.status_code)] += 1
            if response.status_code == 200:
                return PushResult.OK, None
            reason = _reason(response)
            log.warning("apns rejected push: status=%s reason=%s", response.status_code, reason)
            if response.status_code in APNS_RETRY_STATUSES:
                return None, _retry_after(response, 0.0)
            if response.status_code == 410 or reason in _INVALID_TOKEN_REASONS:
                return PushResult.INVALID_TOKEN, None
            return PushResult.FAILED, None

        return await self._with_retries(attempt)

    async def close(self) -> None:
        await self._client.aclose()


class GatewayPush(_Retrying):
    """Sends pushes through the push gateway, each request signed with the relay's gateway key."""

    def __init__(
        self,
        url: str,
        key_pem: bytes,
        client: httpx.AsyncClient | None = None,
        retry_delays: tuple[float, ...] = RETRY_DELAYS,
    ) -> None:
        super().__init__(retry_delays)
        self._url = f"{url.rstrip('/')}/v1/push"
        self._key = pushauth.load_key(key_pem)
        self._client = client or httpx.AsyncClient(http2=True, timeout=10.0)

    @property
    def relay_id(self) -> str:
        return pushauth.relay_id(self._key)

    async def send_voip(self, token: str, env: str, call_id: str) -> PushResult:
        return await self._post({"kind": "voip", "token": token, "env": env, "call_id": call_id})

    async def send_alert(self, token: str, env: str, ciphertext: str | None) -> PushResult:
        return await self._post({"kind": "alert", "token": token, "env": env, "ciphertext": ciphertext})

    async def send_live_activity(self, token: str, env: str, event: str, content_state: dict) -> PushResult:
        body = {"kind": "liveactivity", "token": token, "env": env, "event": event, "content_state": content_state}
        return await self._post(body)

    async def _post(self, body: dict) -> PushResult:
        data = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()

        async def attempt() -> tuple[PushResult | None, float | None]:
            # A fresh signature per attempt: the gateway refuses one it has seen before.
            headers = {"authorization": pushauth.sign(self._key, data), "content-type": "application/json"}
            try:
                response = await self._client.post(self._url, content=data, headers=headers)
            except httpx.HTTPError as exc:
                log.warning("push gateway request failed: %s", type(exc).__name__)
                self.statuses["error"] += 1
                return None, 0.0
            self.statuses[str(response.status_code)] += 1
            if response.status_code in GATEWAY_RETRY_STATUSES:
                log.warning("push gateway unavailable: status=%s", response.status_code)
                return None, _retry_after(response, 0.0)
            if response.status_code != 200:
                error = _gateway_error(response)
                log.warning("push gateway rejected push: status=%s error=%s", response.status_code, error)
                if error == "unauthorized":
                    log.warning("check this relay's clock: the gateway accepts requests within 60 s")
                return PushResult.FAILED, None
            try:
                return PushResult(response.json().get("result")), None
            except (ValueError, AttributeError):
                return PushResult.FAILED, None

        return await self._with_retries(attempt)

    async def close(self) -> None:
        await self._client.aclose()


def _gateway_error(response: httpx.Response) -> str:
    try:
        error = response.json().get("error", "")
    except (ValueError, AttributeError):
        return "unknown"
    return error if isinstance(error, str) and error.replace("_", "").isalnum() and len(error) < 40 else "unknown"


def _reason(response: httpx.Response) -> str:
    try:
        reason = response.json().get("reason", "")
    except ValueError:
        return "unknown"
    return reason if isinstance(reason, str) and reason.isalnum() else "unknown"
