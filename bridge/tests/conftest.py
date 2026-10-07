import asyncio
import datetime
import ipaddress
import ssl
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import pytest
from aiohttp import web
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from hermescall_bridge.daemon import Bridge, build_bridge
from hermescall_bridge.hermes import ApprovalRequest, TextDelta, ToolProgress
from hermescall_bridge.state import StateStore
from hermescall_common import codes
from hermescall_common.client import pair_as_initiator
from hermescall_relay.config import Config as RelayConfig
from hermescall_relay.push import PushResult
from hermescall_relay.server import Relay
from hermescall_relay.store import Store

API_TOKEN = "t" * 43
CALL_TOKEN = "c" * 43


def self_signed(tmp_path: Path) -> ssl.SSLContext:
    return self_signed_for(tmp_path, "127.0.0.1")


def self_signed_for(tmp_path: Path, host: str) -> ssl.SSLContext:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "relay-test")])
    now = datetime.datetime.now(datetime.UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(host))]), critical=False)
        .sign(key, hashes.SHA256())
    )
    (tmp_path / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (tmp_path / "key.pem").write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(tmp_path / "cert.pem", tmp_path / "key.pem")
    return context


class FakePush:
    def __init__(self) -> None:
        self.sent: list[str] = []
        self.alerts: list[str | None] = []
        self.live: list[tuple[str, str, dict]] = []

    async def send_voip(self, token: str, env: str, call_id: str) -> PushResult:
        self.sent.append(call_id)
        return PushResult.OK

    async def send_alert(self, token: str, env: str, ciphertext: str | None) -> PushResult:
        self.alerts.append(ciphertext)
        return PushResult.OK

    async def send_live_activity(self, token: str, env: str, event: str, content_state: dict) -> PushResult:
        self.live.append((token, event, content_state))
        return PushResult.OK

    async def close(self) -> None:
        pass


class FakeHermes:
    def __init__(self) -> None:
        self.turns: list[tuple[str, str]] = []
        self.images: list[list[bytes]] = []
        self.approvals: list[str] = []
        self.ask_approval = False
        self.tools: list[ToolProgress] = []
        self.sessions: list[str | None] = []

    async def turn(self, system: str, text: str, images: list[bytes] = (), session_id: str | None = None) -> AsyncIterator:
        self.turns.append((system, text))
        self.sessions.append(session_id)
        self.images.append(list(images))
        if self.ask_approval:
            yield ApprovalRequest("run1", "req1", "rm -rf /tmp/x", "delete files")
        for event in self.tools:
            yield event
        for piece in ("Sure, ", "I heard you. ", "Anything else?"):
            yield TextDelta(piece)

    async def answer_approval(self, request: ApprovalRequest, choice: str) -> str:
        self.approvals.append(choice)
        return choice


class FakeTts:
    def __init__(self) -> None:
        self.spoken: list[str] = []
        self.prepared: list[str] = []

    async def prepare(self, text: str) -> None:
        self.prepared.append(text)

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        self.spoken.append(text)
        t = np.arange(2400) / 24000
        yield (np.sin(2 * np.pi * 440 * t) * 8000).astype(np.int16).tobytes()


class Harness:
    def __init__(self, relay: Relay, bridge: Bridge, port: int, push: FakePush, hermes: FakeHermes, tts: FakeTts):
        self.relay, self.bridge, self.port, self.push, self.hermes, self.tts = relay, bridge, port, push, hermes, tts


@pytest.fixture
async def harness(tmp_path: Path) -> AsyncIterator[Harness]:
    context = self_signed(tmp_path)
    runner_probe = web.AppRunner(web.Application())
    await runner_probe.setup()
    site = web.TCPSite(runner_probe, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    await runner_probe.cleanup()

    config = RelayConfig(
        host="127.0.0.1",
        port=port,
        tls_pin="",
        listen_host="127.0.0.1",
        listen_port=port,
        db_path=tmp_path / "relay.db",
        trust_proxy=False,
        turn_urls=("turn:127.0.0.1:3478?transport=udp",),
        turn_ttl=600,
        apns=None,
    )
    from hermescall_common.tls import spki_pin

    pem = (tmp_path / "cert.pem").read_bytes()
    der = x509.load_pem_x509_certificate(pem).public_bytes(serialization.Encoding.DER)
    config = RelayConfig(**{**config.__dict__, "tls_pin": spki_pin(der)})
    push = FakePush()
    relay = Relay(config, Store(config.db_path), push, b"turn-secret")
    runner = web.AppRunner(relay.app())
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port, ssl_context=context).start()

    code = relay.store.create_relay_code()
    invite = codes.PairingInvite("relay", "127.0.0.1", port, "", code)
    store = StateStore(tmp_path / "bridge")
    state = store.load()
    _, result, pin = await pair_as_initiator(invite, {"sign_pk": state.keys["sign_pk"]}, "paired", allow_self_signed=True)
    state.relay = {"host": "127.0.0.1", "port": port, "pin": pin, "bridge_id": result["bridge_id"]}
    store.save(state)

    hermes, tts = FakeHermes(), FakeTts()

    async def transcribe(audio: np.ndarray) -> str:
        return "hello hermes"

    bridge = build_bridge(state, store, API_TOKEN, hermes, tts, transcribe, CALL_TOKEN)
    task = asyncio.ensure_future(bridge.relay.run())
    await asyncio.wait_for(bridge.relay.connected.wait(), 10)
    try:
        yield Harness(relay, bridge, port, push, hermes, tts)
    finally:
        bridge.relay.stop()
        task.cancel()
        await runner.cleanup()
