"""Starts a real relay (self-signed TLS on 127.0.0.1) and a bridge with fake speech/LLM
services, opens a device pairing invitation and prints it as JSON for the Swift tests."""

import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from aiohttp import web  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402

from bridge.tests.conftest import API_TOKEN, FakeHermes, FakePush, FakeTts, self_signed  # noqa: E402
from hermescall_bridge.daemon import build_bridge  # noqa: E402
from hermescall_bridge.state import StateStore  # noqa: E402
from hermescall_common import codes  # noqa: E402
from hermescall_common.client import pair_as_initiator  # noqa: E402
from hermescall_common.tls import spki_pin  # noqa: E402
from hermescall_relay.config import Config  # noqa: E402
from hermescall_relay.server import Relay  # noqa: E402
from hermescall_relay.store import Store  # noqa: E402


async def main() -> None:
    tmp = Path(tempfile.mkdtemp())
    context = self_signed(tmp)
    pin = spki_pin(x509.load_pem_x509_certificate((tmp / "cert.pem").read_bytes()).public_bytes(serialization.Encoding.DER))
    probe = web.AppRunner(web.Application())
    await probe.setup()
    site = web.TCPSite(probe, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    await probe.cleanup()
    config = Config(
        "127.0.0.1", port, pin, "127.0.0.1", port, tmp / "relay.db", False, ("turn:127.0.0.1:3478?transport=udp",), 600, None
    )
    relay = Relay(config, Store(config.db_path), FakePush(), b"secret")
    runner = web.AppRunner(relay.app())
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port, ssl_context=context).start()

    store = StateStore(tmp / "bridge")
    state = store.load()
    invite = codes.PairingInvite("relay", "127.0.0.1", port, "", relay.store.create_relay_code())
    _, result, observed = await pair_as_initiator(invite, {"sign_pk": state.keys["sign_pk"]}, "paired", allow_self_signed=True)
    state.relay = {"host": "127.0.0.1", "port": port, "pin": observed, "bridge_id": result["bridge_id"]}
    store.save(state)

    async def transcribe(audio) -> str:
        return ""

    bridge = build_bridge(state, store, API_TOKEN, FakeHermes(), FakeTts(), transcribe)
    task = asyncio.ensure_future(bridge.relay.run())
    await asyncio.wait_for(bridge.relay.connected.wait(), 10)
    api = web.AppRunner(bridge.app)
    await api.setup()
    api_site = web.TCPSite(api, "127.0.0.1", 0)
    await api_site.start()
    api_port = api_site._server.sockets[0].getsockname()[1]
    invitation, device_invite = await bridge.devices.invite("swift")
    info = {"port": port, "pin": pin, "code": invitation.code.display(), "link": device_invite.to_uri()}
    print(json.dumps({**info, "api_port": api_port, "api_token": API_TOKEN}), flush=True)
    await asyncio.get_running_loop().run_in_executor(None, sys.stdin.read)
    task.cancel()


asyncio.run(main())
