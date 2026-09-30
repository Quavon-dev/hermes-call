"""Relay: authenticated routing of opaque E2E messages, pairing rendezvous,
TURN credentials, VoIP push fan-out, a ciphertext mailbox for chat messages
and a store for encrypted attachments. It never sees plaintext.

One process, one SQLite database: the relay is single-writer by design and does not scale out
horizontally (docs/relay.md, "Limits and scaling")."""

import asyncio
import logging
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from aiohttp import WSCloseCode, WSMsgType, web

from hermescall_common import auth, codes, pairing, sodium, wire
from hermescall_common.errors import CryptoError, ProtocolError

from . import netutil, observability, turn
from .attachments import AttachmentsMixin, BlobTicket, _refuse_upload  # noqa: F401 - re-exported
from .config import Config
from .mailbox import MAX_E2E_BLOB, MailboxMixin
from .metrics import CONTENT_TYPE
from .push import LIVE_EVENTS, GatewayPush, PushResult, PushSender
from .ratelimit import FailureLimiter, RateLimiter
from .store import LIVE_KINDS, PUSH_ENVS, Store, new_id
from .version import CAPABILITIES, VERSION

log = logging.getLogger(__name__)

MAX_PAIR_BLOB = 4096
MAX_PAIR_MESSAGES = 4
# On SIGTERM: how long pending chat alerts may take before the process exits.
SHUTDOWN_PUSH_SECONDS = 5.0
_ID = re.compile(r"^[A-Za-z0-9_-]{22}\Z")
_PUSH_TOKEN = re.compile(r"^[0-9a-f]{64,200}\Z")
_CAP = re.compile(r"^[a-z0-9_]{1,32}\Z")
MAX_CAPS = 32
PUSH_KINDS = ("voip", "alert", "liveactivity", "liveactivity_start")
# Live Activity pushes per device: routine updates at most every 3 s; a new activity (start) at most
# every 30 s and 20 per hour; ends 30 per hour. A compromised bridge token cannot spam Apple pushes.
LIVE_UPDATE_SECONDS = 3.0
LIVE_START_LIMITS = ((30.0, 1), (3600.0, 20))
LIVE_END_LIMITS = ((3600.0, 30),)
MAX_LIVE_LABEL = 60
MAX_LIVE_STEP = 999
LIVE_STATES = ("running", "done", "failed")

client_key = netutil.key


def short(identity: str) -> str:
    return identity[:6]


def _live_int(value: object, allow_none: bool = False) -> bool:
    if value is None:
        return allow_none
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= MAX_LIVE_STEP


def valid_content_state(state: object) -> bool:
    """Only what the Lock Screen needs, all of it plaintext to Apple: never tool arguments or text."""
    if not isinstance(state, dict) or set(state) - {"step", "total", "label", "state", "startedAt"}:
        return False
    started = state.get("startedAt")
    return (
        _live_int(state.get("step"))
        and _live_int(state.get("total"), allow_none=True)
        and isinstance(state.get("label"), str)
        and len(state["label"]) <= MAX_LIVE_LABEL
        and state.get("state") in LIVE_STATES
        and isinstance(started, (int, float))
        and not isinstance(started, bool)
        and 0 <= started < 1e11
    )


def valid_id(value: object) -> str:
    if not isinstance(value, str) or not _ID.match(value):
        raise ProtocolError("invalid id")
    return value


def client_caps(message: dict) -> tuple[int, frozenset[str]]:
    """Optional `v` and `caps` of an `auth` (hello): recorded, never required; junk is ignored."""
    version = message.get("v")
    caps = message.get("caps")
    if not isinstance(version, int) or isinstance(version, bool) or not 0 < version < 1000:
        version = 1
    if not isinstance(caps, list):
        return version, frozenset()
    return version, frozenset(c for c in caps[:MAX_CAPS] if isinstance(c, str) and _CAP.match(c))


@dataclass
class Slot:
    bridge_id: str
    expires: float
    attempts: int = 0


@dataclass
class PairSession:
    conn: str
    slot: str
    bridge_id: str
    ip_key: str
    device_ws: web.WebSocketResponse
    device_id: str | None = None
    done: asyncio.Event = field(default_factory=asyncio.Event)


class Relay(AttachmentsMixin, MailboxMixin):
    def __init__(self, config: Config, store: Store, push: PushSender | None, turn_secret: bytes | None) -> None:
        self.config = config
        self.limits = config.limits
        self.store = store
        self.push = push
        self.turn_secret = turn_secret
        limits = self.limits
        self.failures = FailureLimiter()
        self.wide_failures = FailureLimiter(max_failures=30)
        self.turn_rate = RateLimiter(limit=limits.turn_requests_per_minute, window=60)
        self.pair_rate = RateLimiter(limit=limits.pair_per_minute, window=60)
        self.ring_rate = RateLimiter(limit=limits.rings_per_minute, window=60)
        self.live_rate = RateLimiter(limit=1, window=LIVE_UPDATE_SECONDS)
        self.live_limits = {
            "update": [self.live_rate],
            "start": [RateLimiter(limit=n, window=w) for w, n in LIVE_START_LIMITS],
            "end": [RateLimiter(limit=n, window=w) for w, n in LIVE_END_LIMITS],
        }
        self.bridges: dict[str, web.WebSocketResponse] = {}
        self.devices: dict[str, web.WebSocketResponse] = {}
        self.client_caps: dict[str, frozenset[str]] = {}
        self.slots: dict[str, Slot] = {}
        self.sessions: dict[str, PairSession] = {}
        self.message_rate = RateLimiter(limit=limits.messages_per_window, window=limits.message_window_seconds)
        self.connections = 0
        self.unauthenticated = 0
        self.connections_per_ip: dict[str, int] = {}
        self.mail_rate = RateLimiter(limit=limits.mails_per_minute, window=60)
        self.alert_rate = RateLimiter(limit=limits.alerts_per_window, window=limits.alert_window_seconds)
        self.blob_upload_rate = RateLimiter(limit=limits.blob_uploads_per_hour, window=3600)
        self.blob_ticket_rate = RateLimiter(limit=limits.blob_tickets_per_hour, window=3600)
        self.blob_tickets: dict[str, BlobTicket] = {}
        self.blob_transfers = 0
        self.blob_downloads = 0
        self._tasks: set[asyncio.Task] = set()
        self._alert_tasks: set[asyncio.Task] = set()
        self._stopping = asyncio.Event()
        self._shutting_down = False
        self.gateway_probe = observability.GatewayProbe(config.push_gateway) if isinstance(push, GatewayPush) else None
        self.metrics = observability.relay_metrics(self)
        self.rate_limited = self.metrics.counter("rate_limited_total", "Requests refused by a limit, by limit name.")
        self.transfers_total = self.metrics.counter("blob_transfers_total", "Finished attachment transfers.")
        self.maintenance_total = self.metrics.counter("expired_total", "Expired mailbox messages and attachments removed.")

    _valid_id = staticmethod(valid_id)

    def _spawn(self, coro: Awaitable) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _count_limit(self, name: str) -> None:
        self.rate_limited.inc(limit=name)

    def _allow(self, limiter: RateLimiter, key: str, name: str) -> bool:
        if limiter.allow(key):
            return True
        self._count_limit(name)
        return False

    # ---- HTTP plumbing -------------------------------------------------

    def app(self) -> web.Application:
        app = web.Application(client_max_size=4096)
        app.router.add_get("/healthz", self.healthz)
        app.router.add_get("/v1/pair", self.pair_endpoint)
        app.router.add_get("/v1/ws", self.ws_endpoint)
        app.router.add_put("/v1/blobs/{blob_id}", self.blob_upload)
        app.router.add_get("/v1/blobs/{blob_id}", self.blob_download)
        app.on_startup.append(self._start_background)
        app.on_shutdown.append(self._shutdown)
        app.on_cleanup.append(self._cleanup)
        return app

    def metrics_app(self) -> web.Application:
        app = web.Application()
        app.router.add_get("/metrics", self.metrics_endpoint)
        return app

    async def _start_background(self, app: web.Application) -> None:
        self.blob_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        app["sweeper"] = asyncio.create_task(self._revocation_sweeper())
        app["expiry"] = asyncio.create_task(self._expiry_sweeper())
        app["metrics"] = None
        if self.config.metrics_port:
            runner = web.AppRunner(self.metrics_app(), access_log=None)
            await runner.setup()
            await web.TCPSite(runner, self.config.metrics_host, self.config.metrics_port).start()
            app["metrics"] = runner

    async def _shutdown(self, app: web.Application) -> None:
        """SIGTERM: tell clients to reconnect elsewhere/later, then send the chat alerts still pending."""
        self._shutting_down = True
        sockets = list(self.bridges.values()) + list(self.devices.values())
        sockets += [session.device_ws for session in self.sessions.values()]
        log.info("shutting down: closing %d connection(s)", len(sockets))
        await asyncio.gather(
            *(ws.close(code=WSCloseCode.GOING_AWAY, message=b"relay restarting") for ws in sockets),
            return_exceptions=True,
        )
        await self._flush_alerts(SHUTDOWN_PUSH_SECONDS)

    async def _cleanup(self, app: web.Application) -> None:
        for name in ("sweeper", "expiry"):
            app[name].cancel()
        if app["metrics"] is not None:
            await app["metrics"].cleanup()
        if self.push:
            await self.push.close()

    async def healthz(self, request: web.Request) -> web.Response:
        status, body = await observability.health(self)
        return web.json_response(body, status=status, headers={"Cache-Control": "no-store"})

    async def metrics_endpoint(self, request: web.Request) -> web.Response:
        return web.Response(body=self.metrics.render().encode(), headers={"Content-Type": CONTENT_TYPE})

    def client_ip(self, request: web.Request) -> str:
        """The client's address as the nearest untrusted hop saw it (see netutil.client_ip)."""
        return netutil.client_ip(
            request.remote or "",
            request.headers.get("X-Forwarded-For", ""),
            self.config.trust_proxy,
            self.config.trusted_proxies,
        )

    def _locked_out(self, ip: str) -> bool:
        return self.failures.is_locked(client_key(ip)) or self.wide_failures.is_locked(client_key(ip, 48))

    def _fail(self, ip: str) -> None:
        self.failures.fail(client_key(ip))
        if ":" in client_key(ip):
            self.wide_failures.fail(client_key(ip, 48))

    def _admit(self, ip_key: str) -> bool:
        limits = self.limits
        if (
            self.connections >= limits.max_connections
            or self.unauthenticated >= limits.max_unauthenticated
            or self.connections_per_ip.get(ip_key, 0) >= limits.max_connections_per_ip
        ):
            self._count_limit("connections")
            return False
        self.connections += 1
        self.unauthenticated += 1
        self.connections_per_ip[ip_key] = self.connections_per_ip.get(ip_key, 0) + 1
        return True

    def _release(self, ip_key: str, authenticated: bool = False) -> None:
        self.connections -= 1
        if not authenticated:
            self.unauthenticated -= 1
        remaining = self.connections_per_ip[ip_key] - 1
        if remaining:
            self.connections_per_ip[ip_key] = remaining
        else:
            del self.connections_per_ip[ip_key]

    @staticmethod
    async def _open_ws(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(heartbeat=30.0, max_msg_size=wire.MAX_MESSAGE_BYTES)
        await ws.prepare(request)
        return ws

    @staticmethod
    async def _receive(ws: web.WebSocketResponse, limit: float) -> dict[str, Any]:
        msg = await asyncio.wait_for(ws.receive(), limit)
        if msg.type != WSMsgType.TEXT:
            raise ProtocolError("connection closed")
        return wire.decode(msg.data)

    @staticmethod
    async def _send(ws: web.WebSocketResponse, message: dict[str, Any]) -> bool:
        if ws.closed:
            return False
        try:
            await ws.send_str(wire.encode(message))
            return True
        except (ConnectionError, RuntimeError):
            return False

    # ---- Pairing rendezvous (unauthenticated) --------------------------

    async def pair_endpoint(self, request: web.Request) -> web.StreamResponse:
        ip = self.client_ip(request)
        ip_key = client_key(ip)
        if self._locked_out(ip) or not self._allow(self.pair_rate, ip_key, "pairing"):
            return web.Response(status=429, text="try again later")
        if not self._admit(ip_key):
            return web.Response(status=503)
        ws = None
        try:
            ws = await self._open_ws(request)
            await self._pair(ws, ip_key)
        except (TimeoutError, ProtocolError, CryptoError):
            self._fail(ip)
            if ws is not None:
                await self._send(ws, {"t": "error", "code": "pairing_failed"})
        finally:
            self._release(ip_key)
            if ws is not None:
                await ws.close(code=self._close_code())
        return ws

    async def _pair(self, ws: web.WebSocketResponse, ip_key: str) -> None:
        join = await self._receive(ws, self.limits.handshake_timeout)
        if join["t"] != "join" or not codes.is_valid_slot(join.get("slot")):
            raise ProtocolError("bad join")
        public_data = wire.b64d(join.get("msg"), length=48)
        slot = join["slot"]
        if codes.is_relay_slot(slot):
            await self._pair_bridge(ws, slot, public_data)
        elif slot in self.slots:
            await self._pair_device(ws, ip_key, slot, public_data)
        else:
            raise ProtocolError("unknown code")

    async def _pair_bridge(self, ws: web.WebSocketResponse, slot: str, public_data: bytes) -> None:
        secret = self.store.consume_relay_code_attempt(slot)
        if secret is None:
            raise ProtocolError("unknown code")
        ctx = pairing.Context("relay", self.config.host, self.config.port, self.config.tls_pin)
        response, keys = pairing.respond(ctx, secret, public_data)
        await self._send(ws, {"t": "cpace", "msg": wire.b64e(response)})
        confirm = await self._receive(ws, self.limits.handshake_timeout)
        if confirm["t"] != "confirm":
            raise ProtocolError("bad confirm")
        payload = pairing.open_initiator(keys, wire.b64d(confirm.get("data"), max_length=MAX_PAIR_BLOB))
        sign_pk = wire.b64d(payload.get("sign_pk"), length=sodium.SIGN_PKBYTES)
        bridge_id = self.store.add_bridge(sign_pk)
        self.store.delete_relay_code(slot)
        sealed = pairing.seal_responder(keys, {"bridge_id": bridge_id, "authority": self.config.authority})
        await self._send(ws, {"t": "paired", "data": wire.b64e(sealed)})
        log.info("bridge paired id=%s", short(bridge_id))

    async def _pair_device(self, ws: web.WebSocketResponse, ip_key: str, slot_id: str, public_data: bytes) -> None:
        slot = self.slots[slot_id]
        bridge_ws = self.bridges.get(slot.bridge_id)
        if slot.expires <= time.monotonic() or bridge_ws is None:
            self.slots.pop(slot_id, None)
            raise ProtocolError("slot unavailable")
        slot.attempts += 1
        if slot.attempts >= self.limits.max_slot_attempts:
            self.slots.pop(slot_id, None)
        session = PairSession(new_id(), slot_id, slot.bridge_id, ip_key, ws)
        self.sessions[session.conn] = session
        try:
            await self._send(bridge_ws, {"t": "pair_join", "slot": slot_id, "conn": session.conn, "msg": wire.b64e(public_data)})
            await asyncio.wait_for(self._pump_device(session), self.limits.pair_session_timeout)
        finally:
            self.sessions.pop(session.conn, None)
            bridge_ws = self.bridges.get(session.bridge_id)
            if bridge_ws is not None and not session.done.is_set():
                await self._send(bridge_ws, {"t": "pair_abort", "conn": session.conn})

    async def _pump_device(self, session: PairSession) -> None:
        receiver = asyncio.create_task(self._forward_device_to_bridge(session))
        finished = asyncio.create_task(session.done.wait())
        try:
            await asyncio.wait({receiver, finished}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            receiver.cancel()
            finished.cancel()
        if not session.done.is_set() and receiver.done() and not receiver.cancelled() and receiver.exception():
            raise receiver.exception()

    async def _forward_device_to_bridge(self, session: PairSession) -> None:
        for _ in range(MAX_PAIR_MESSAGES):
            message = await self._receive(session.device_ws, self.limits.pair_session_timeout)
            if message["t"] != "pair_msg":
                raise ProtocolError("unexpected message")
            data = wire.b64d(message.get("data"), max_length=MAX_PAIR_BLOB)
            bridge_ws = self.bridges.get(session.bridge_id)
            if bridge_ws is None:
                session.done.set()
                return
            await self._send(bridge_ws, {"t": "pair_msg", "conn": session.conn, "data": wire.b64e(data)})
        raise ProtocolError("too many pairing messages")

    # ---- Authenticated connections -------------------------------------

    async def ws_endpoint(self, request: web.Request) -> web.StreamResponse:
        ip = self.client_ip(request)
        ip_key = client_key(ip)
        if self._locked_out(ip):
            return web.Response(status=429, text="try again later")
        if not self._admit(ip_key):
            return web.Response(status=503)
        try:
            ws = await self._open_ws(request)
        except Exception:
            self._release(ip_key)
            raise
        role, identity = "", ""
        try:
            role, identity = await self._authenticate(ws, ip_key)
            self.unauthenticated -= 1
            await self._serve(ws, role, identity)
        except (TimeoutError, ProtocolError, CryptoError) as exc:
            if not identity:
                self._fail(ip)
            await self._send(ws, {"t": "error", "code": "protocol_error"})
            log.info("connection closed: %s", exc.__class__.__name__)
        finally:
            self._release(ip_key, authenticated=bool(identity))
            self._unregister(role, identity, ws)
            await ws.close(code=self._close_code())
        return ws

    def _close_code(self) -> int:
        # aiohttp < 3.9 lets the handler's own close() win the race with _shutdown's.
        return WSCloseCode.GOING_AWAY if self._shutting_down else WSCloseCode.OK

    async def _authenticate(self, ws: web.WebSocketResponse, ip_key: str) -> tuple[str, str]:
        nonce = sodium.random_bytes(auth.NONCE_BYTES)
        await self._send(ws, {"t": "challenge", "nonce": wire.b64e(nonce), "v": 1})
        message = await self._receive(ws, self.limits.handshake_timeout)
        role = message.get("role")
        if message["t"] != "auth" or role not in auth.ROLES:
            raise ProtocolError("bad auth")
        identity = valid_id(message.get("id"))
        sig = wire.b64d(message.get("sig"), length=sodium.SIGN_BYTES)
        key = self._identity_key(role, identity)
        if key is None or not auth.verify_auth(key, self.config.authority, role, identity, nonce, sig):
            raise ProtocolError("authentication failed")
        self._register(role, identity, ws)
        self.client_caps[identity] = client_caps(message)[1]
        await self._send(ws, {"t": "ready", "v": 1, "relay": VERSION, "caps": list(CAPABILITIES)})
        return role, identity

    def _identity_key(self, role: str, identity: str) -> bytes | None:
        if role == "bridge":
            return self.store.bridge_key(identity)
        device = self.store.device(identity)
        return device.sign_pk if device else None

    def _register(self, role: str, identity: str, ws: web.WebSocketResponse) -> None:
        table = self.bridges if role == "bridge" else self.devices
        previous = table.get(identity)
        table[identity] = ws
        if previous is not None and not previous.closed:
            self._spawn(previous.close())
        if role == "device":
            self._spawn(self._presence(identity, True))

    def _unregister(self, role: str, identity: str, ws: web.WebSocketResponse) -> None:
        table = self.bridges if role == "bridge" else self.devices
        if identity and table.get(identity) is ws:
            del table[identity]
            self.client_caps.pop(identity, None)
            if role == "device":
                self._spawn(self._presence(identity, False))
            else:
                self._drop_bridge_slots(identity)

    def _drop_bridge_slots(self, bridge_id: str) -> None:
        for slot_id in [s for s, slot in self.slots.items() if slot.bridge_id == bridge_id]:
            del self.slots[slot_id]
        for session in [s for s in self.sessions.values() if s.bridge_id == bridge_id]:
            session.done.set()

    async def _presence(self, device_id: str, online: bool) -> None:
        device = self.store.device(device_id)
        bridge_ws = self.bridges.get(device.bridge_id) if device else None
        if bridge_ws is not None:
            await self._send(bridge_ws, {"t": "presence", "device_id": device_id, "online": online})

    async def _serve(self, ws: web.WebSocketResponse, role: str, identity: str) -> None:
        handlers = self._bridge_handlers() if role == "bridge" else self._device_handlers()
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                break
            if not self.message_rate.allow(identity):
                self._count_limit("messages")
                raise ProtocolError("message rate exceeded")
            message = wire.decode(msg.data)
            handler = handlers.get(message["t"])
            if handler is None:
                # A newer client (or bridge) talking to this relay: say so and keep the session.
                reply: dict | None = {"t": "error", "code": "unsupported"}
                if _CAP.match(message["t"]):
                    reply["type"] = message["t"]
            else:
                try:
                    reply = await handler(identity, message)
                except (TypeError, KeyError, ValueError) as exc:
                    raise ProtocolError("malformed request") from exc
            if reply is not None:
                if "rid" in message and isinstance(message["rid"], (int, str)):
                    reply["rid"] = message["rid"]
                await self._send(ws, reply)

    # ---- Background maintenance ----------------------------------------

    async def _revocation_sweeper(self) -> None:
        rounds = 0
        while True:
            await asyncio.sleep(self.limits.sweep_seconds)
            rounds += 1
            try:
                await self._sweep(rounds)
            except Exception:
                # One bad round (e.g. a locked database) must not end revocation for good.
                log.exception("sweep failed; retrying next round")

    async def _sweep(self, rounds: int) -> None:
        self._drop_expired_slots()
        for role, table in (("bridge", self.bridges), ("device", self.devices)):
            for identity, ws in list(table.items()):
                if not self.store.identity_exists(role, identity):
                    log.info("closing revoked %s id=%s", role, short(identity))
                    await ws.close()

    async def _expiry_sweeper(self) -> None:
        """Expired mail and attachments go even when nobody sends new ones; free pages go back to disk."""
        while True:
            try:
                self.expire_now()
            except Exception:
                log.exception("expiry sweep failed; retrying next round")
            await asyncio.sleep(self.limits.expiry_sweep_seconds)

    def expire_now(self) -> tuple[int, int]:
        mails = self.store.expire()
        blobs = self._sweep_blobs()
        self.maintenance_total.inc(mails, kind="mail")
        self.maintenance_total.inc(blobs, kind="blob")
        self.store.vacuum_step()
        if mails or blobs:
            log.info("expired %d mail(s) and %d attachment(s)", mails, blobs)
        return mails, blobs

    # ---- Bridge messages -----------------------------------------------

    def _bridge_handlers(self) -> dict[str, Callable[[str, dict], Awaitable[dict | None]]]:
        return {
            "open_slot": self.b_open_slot,
            "close_slot": self.b_close_slot,
            "pair_msg": self.b_pair_msg,
            "pair_done": self.b_pair_done,
            "pair_final": self.b_pair_final,
            "list_devices": self.b_list_devices,
            "revoke_device": self.b_revoke_device,
            "e2e": self.b_e2e,
            "ring": self.b_ring,
            "mail": self.b_mail,
            "live_update": self.b_live_update,
            "turn": self.x_turn,
            "blob_put": self.x_blob_put,
            "blob_get": self.x_blob_get,
            "blob_delete": self.x_blob_delete,
        }

    def _drop_expired_slots(self) -> None:
        now = time.monotonic()
        for slot_id in [s for s, slot in self.slots.items() if slot.expires <= now]:
            del self.slots[slot_id]

    async def b_open_slot(self, bridge_id: str, message: dict) -> dict:
        self._drop_expired_slots()
        if sum(1 for slot in self.slots.values() if slot.bridge_id == bridge_id) >= self.limits.max_slots_per_bridge:
            return {"t": "error", "code": "too_many_slots"}
        if self.store.device_count(bridge_id) >= self.limits.max_devices_per_bridge:
            self._count_limit("devices")
            return {"t": "error", "code": "too_many_devices"}
        slot_id = codes.new_device_slot()
        while slot_id in self.slots:
            slot_id = codes.new_device_slot()
        self.slots[slot_id] = Slot(bridge_id, time.monotonic() + self.limits.slot_ttl)
        return {"t": "slot_opened", "slot": slot_id, "ttl": int(self.limits.slot_ttl)}

    async def b_close_slot(self, bridge_id: str, message: dict) -> dict:
        slot = self.slots.get(message.get("slot"))
        if slot is not None and slot.bridge_id == bridge_id:
            del self.slots[message["slot"]]
        return {"t": "slot_closed"}

    def _session(self, bridge_id: str, message: dict) -> PairSession:
        session = self.sessions.get(message.get("conn"))
        if session is None or session.bridge_id != bridge_id:
            raise LookupError
        return session

    async def b_pair_msg(self, bridge_id: str, message: dict) -> dict | None:
        try:
            session = self._session(bridge_id, message)
        except LookupError:
            return {"t": "error", "code": "no_session"}
        data = wire.b64d(message.get("data"), max_length=MAX_PAIR_BLOB)
        await self._send(session.device_ws, {"t": "pair_msg", "data": wire.b64e(data)})
        return None

    async def b_pair_done(self, bridge_id: str, message: dict) -> dict:
        try:
            session = self._session(bridge_id, message)
        except LookupError:
            return {"t": "error", "code": "no_session"}
        if message.get("ok") is not True:
            self.failures.fail(session.ip_key)
            await self._send(session.device_ws, {"t": "error", "code": "pairing_failed"})
            session.done.set()
            return {"t": "pair_closed", "conn": session.conn}
        if session.device_id is not None:
            return {"t": "error", "code": "already_registered"}
        if self.store.device_count(bridge_id) >= self.limits.max_devices_per_bridge:
            await self._send(session.device_ws, {"t": "error", "code": "too_many_devices"})
            session.done.set()
            return {"t": "error", "code": "too_many_devices"}
        sign_pk = wire.b64d(message.get("sign_pk"), length=sodium.SIGN_PKBYTES)
        session.device_id = self.store.add_device(bridge_id, sign_pk)
        self.slots.pop(session.slot, None)
        log.info("device paired id=%s bridge=%s", short(session.device_id), short(bridge_id))
        return {"t": "pair_registered", "conn": session.conn, "device_id": session.device_id}

    async def b_pair_final(self, bridge_id: str, message: dict) -> dict:
        try:
            session = self._session(bridge_id, message)
        except LookupError:
            return {"t": "error", "code": "no_session"}
        if session.device_id is None:
            return {"t": "error", "code": "not_registered"}
        data = wire.b64d(message.get("data"), max_length=MAX_PAIR_BLOB)
        await self._send(session.device_ws, {"t": "pair_final", "device_id": session.device_id, "data": wire.b64e(data)})
        session.done.set()
        return {"t": "pair_closed", "conn": session.conn}

    async def b_list_devices(self, bridge_id: str, message: dict) -> dict:
        devices = [
            {"device_id": d.id, "push": d.push_env or "", "online": d.id in self.devices, "created": d.created}
            for d in self.store.devices_of(bridge_id)
        ]
        return {"t": "devices", "devices": devices}

    async def b_revoke_device(self, bridge_id: str, message: dict) -> dict:
        device_id = valid_id(message.get("device_id"))
        if not self.store.delete_device(bridge_id, device_id):
            return {"t": "error", "code": "unknown_device"}
        ws = self.devices.get(device_id)
        if ws is not None:
            await ws.close()
        log.info("device revoked id=%s", short(device_id))
        return {"t": "revoked", "device_id": device_id}

    async def b_e2e(self, bridge_id: str, message: dict) -> dict | None:
        device_id = valid_id(message.get("to"))
        data = wire.b64d(message.get("data"), max_length=MAX_E2E_BLOB)
        device = self.store.device(device_id)
        ws = self.devices.get(device_id)
        if device is None or device.bridge_id != bridge_id:
            return {"t": "error", "code": "unknown_device"}
        if ws is None or not await self._send(ws, {"t": "e2e", "data": wire.b64e(data)}):
            return {"t": "error", "code": "offline", "device_id": device_id}
        return None

    async def b_ring(self, bridge_id: str, message: dict) -> dict:
        call_id = message.get("call_id")
        wire.b64d(call_id, length=16)
        if not self._allow(self.ring_rate, bridge_id, "rings"):
            return {"t": "error", "code": "rate_limited"}
        targets = self._ring_targets(bridge_id, message.get("devices"))
        if self.push is None:
            return {"t": "error", "code": "push_disabled"}
        results = await asyncio.gather(*(self.push.send_voip(d.push_token, d.push_env, call_id) for d in targets))
        pushed = []
        for device, result in zip(targets, results, strict=True):
            if result is PushResult.OK:
                pushed.append(device.id)
            elif result is PushResult.INVALID_TOKEN:
                self.store.set_push_token(device.id, None, None)
        return {"t": "rang", "call_id": call_id, "pushed": pushed}

    async def b_live_update(self, bridge_id: str, message: dict) -> dict:
        device = self.store.device(valid_id(message.get("to")))
        if device is None or device.bridge_id != bridge_id:
            return {"t": "error", "code": "unknown_device"}
        event, state = message.get("event"), message.get("content_state")
        if event not in LIVE_EVENTS or not valid_content_state(state):
            return {"t": "error", "code": "invalid_content_state"}
        if self.push is None:
            return {"t": "error", "code": "push_disabled"}
        kind = "liveactivity_start" if event == "start" else "liveactivity"
        token_column, env_column = LIVE_KINDS[kind]
        token, env = getattr(device, token_column), getattr(device, env_column)
        if not token or env not in PUSH_ENVS:
            return {"t": "error", "code": "no_token"}
        if not all(limiter.allow(device.id) for limiter in self.live_limits[event]):
            self._count_limit("live_activity")
            return {"t": "error", "code": "rate_limited"}
        result = await self.push.send_live_activity(token, env, event, state)
        if result is PushResult.INVALID_TOKEN:
            self.store.set_live_token(device.id, kind, None, None)
            return {"t": "error", "code": "no_token"}
        if result is not PushResult.OK:
            return {"t": "error", "code": "push_failed"}
        return {"t": "live_updated"}

    def _ring_targets(self, bridge_id: str, selector: object) -> list:
        devices = [d for d in self.store.devices_of(bridge_id) if d.push_token and d.push_env in PUSH_ENVS]
        if selector == "all":
            return devices
        if not isinstance(selector, list) or not 0 < len(selector) <= 32:
            raise ProtocolError("invalid device selector")
        wanted = {valid_id(item) for item in selector}
        return [d for d in devices if d.id in wanted]

    # ---- Device messages -----------------------------------------------

    def _device_handlers(self) -> dict[str, Callable[[str, dict], Awaitable[dict | None]]]:
        return {
            "register_push": self.d_register_push,
            "e2e": self.d_e2e,
            "turn": self.x_turn,
            "mail_fetch": self.d_mail_fetch,
            "mail_ack": self.d_mail_ack,
            "blob_put": self.x_blob_put,
            "blob_get": self.x_blob_get,
            "blob_delete": self.x_blob_delete,
        }

    async def d_register_push(self, device_id: str, message: dict) -> dict:
        token = message.get("token")
        env = message.get("env")
        kind = message.get("kind", "voip")
        if not isinstance(token, str) or not _PUSH_TOKEN.match(token) or env not in PUSH_ENVS or kind not in PUSH_KINDS:
            raise ProtocolError("invalid push registration")
        if kind == "voip":
            self.store.set_push_token(device_id, token, env)
        elif kind == "alert":
            self.store.set_alert_token(device_id, token, env)
        else:
            self.store.set_live_token(device_id, kind, token, env)
        return {"t": "push_registered", "kind": kind}

    async def d_e2e(self, device_id: str, message: dict) -> dict | None:
        data = wire.b64d(message.get("data"), max_length=MAX_E2E_BLOB)
        device = self.store.device(device_id)
        ws = self.bridges.get(device.bridge_id) if device else None
        if ws is None or not await self._send(ws, {"t": "e2e", "from": device_id, "data": wire.b64e(data)}):
            return {"t": "error", "code": "offline"}
        return None

    async def x_turn(self, identity: str, message: dict) -> dict:
        if not self.turn_secret or not self.config.turn_urls:
            return {"t": "error", "code": "turn_disabled"}
        if not self._allow(self.turn_rate, identity, "turn"):
            return {"t": "error", "code": "rate_limited"}
        return {"t": "turn", **turn.credentials(self.turn_secret, self.config.turn_urls, self.config.turn_ttl)}
