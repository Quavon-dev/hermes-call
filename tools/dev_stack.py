"""Local development stack: relay (self-signed TLS) + bridge with real Whisper/Kokoro.

For trying the app in the Simulator or on a phone in the same Wi-Fi without a server:

  docker run -d --name kokoro -p 127.0.0.1:8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu
  docker run -d --name hc-turn -p 3478:3478/udp -p 49160-49200:49160-49200/udp coturn/coturn \\
      -n --use-auth-secret --static-auth-secret=devsecret --realm=dev --min-port=49160 --max-port=49200 \\
      --external-ip=<this Mac's LAN IP> --no-tls --no-dtls --fingerprint
  uv run python tools/dev_stack.py --host <this Mac's LAN IP or 127.0.0.1>

Without --hermes-url a fake Hermes answers "You asked: …". Unless --no-chat-bot, a stand-in for the
Hermes chat adapter answers chat messages: an echo, "approve" asks for a Face ID approval, "photo" and
"file" send attachments, "where" asks the phone for its location (phone context; answers with the
result JSON), "places" shows three sample restaurants in Munich as presentation cards (images are
generated locally, no internet), "task" runs five fake tools (tasks ring / Live Activity), "remind"
adds a place reminder (geofence, "Rewe" near the phone). A voice note sent with voice replies on is
answered by voice (needs Kokoro). In calls, saying "search" makes the fake Hermes report tool
progress. Development only.
"""

import argparse
import asyncio
import contextlib
import json
import logging
import secrets
import shutil
import ssl
import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from aiohttp import web  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from faster_whisper import download_model  # noqa: E402

from bridge.tests.conftest import FakePush, self_signed_for  # noqa: E402
from hermescall_bridge.daemon import build_bridge  # noqa: E402
from hermescall_bridge.hermes import HermesClient  # noqa: E402
from hermescall_bridge.state import StateStore  # noqa: E402
from hermescall_bridge.stt import Transcriber  # noqa: E402
from hermescall_bridge.tasks import Progress  # noqa: E402
from hermescall_bridge.tts import KokoroTts  # noqa: E402
from hermescall_common import codes  # noqa: E402
from hermescall_common.client import pair_as_initiator  # noqa: E402
from hermescall_common.tls import spki_pin  # noqa: E402
from hermescall_relay.config import ApnsConfig, Config  # noqa: E402
from hermescall_relay.push import DirectApns  # noqa: E402
from hermescall_relay.server import Relay  # noqa: E402
from hermescall_relay.store import Store  # noqa: E402


async def main(args: argparse.Namespace) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("aioice").setLevel(logging.WARNING)
    tmp = Path(args.state_dir).expanduser() / args.host
    tmp.mkdir(parents=True, exist_ok=True)
    if (tmp / "cert.pem").exists():
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(tmp / "cert.pem", tmp / "key.pem")
    else:
        context = self_signed_for(tmp, args.host)
    pin = spki_pin(x509.load_pem_x509_certificate((tmp / "cert.pem").read_bytes()).public_bytes(serialization.Encoding.DER))
    config = Config(
        args.host,
        args.port,
        pin,
        "0.0.0.0",
        args.port,
        tmp / "relay.db",
        False,  # noqa: S104
        (f"turn:{args.turn_host or args.host}:3478?transport=udp",),
        600,
        None,
    )
    push = FakePush()
    if args.apns_key:
        apns = ApnsConfig(args.apns_key_id, args.team_id, f"{args.bundle_id}.voip")
        push = DirectApns(apns, Path(args.apns_key).expanduser().read_bytes())
    relay = Relay(config, Store(config.db_path), push, args.turn_secret.encode())
    runner = web.AppRunner(relay.app())
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", args.port, ssl_context=context).start()  # noqa: S104

    fake = None
    hermes_url, hermes_key = args.hermes_url, args.hermes_key
    if not hermes_url:
        hermes_url, hermes_key = "http://127.0.0.1:8642", "devkey"
        fake = subprocess.Popen([sys.executable, str(ROOT / "bridge/tests/fake_hermes.py"), hermes_key, str(tmp / "hermes.log")])

    store = StateStore(tmp / "bridge")
    state = store.load()
    if not state.paired:
        invite = codes.PairingInvite("relay", args.host, args.port, "", relay.store.create_relay_code())
        _, result, observed = await pair_as_initiator(
            invite, {"sign_pk": state.keys["sign_pk"]}, "paired", allow_self_signed=True
        )
        state.relay = {"host": args.host, "port": args.port, "pin": observed, "bridge_id": result["bridge_id"]}
        store.save(state)

    model = download_model(args.stt_model, cache_dir=str(Path.home() / ".cache/hermescall-dev"))
    stt = Transcriber(model, threads=4)
    hermes = HermesClient(hermes_url, hermes_key, "hermes-call-dev")
    tts = KokoroTts("http://127.0.0.1:8880", args.voice)
    bridge = build_bridge(state, store, "dev", hermes, tts, stt.transcribe, image_fetcher=_dev_image)
    task = asyncio.ensure_future(bridge.relay.run())
    await asyncio.wait_for(bridge.relay.connected.wait(), 10)
    api = web.AppRunner(bridge.app)
    await api.setup()
    await web.TCPSite(api, "127.0.0.1", 8765).start()

    bot = None if args.no_chat_bot else asyncio.ensure_future(chat_bot(bridge))
    invitation, link = await bridge.devices.invite("dev phone")
    print(f"\nRelay {args.host}:{args.port}  pairing code: {invitation.code.display()}\nLink: {link.to_uri()}\n", flush=True)
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", link.to_uri()], check=False)
    print("Local API token: dev (curl -H 'Authorization: Bearer dev' 127.0.0.1:8765/v1/status). Ctrl-C to stop.", flush=True)
    try:
        await task
    finally:
        if bot:
            bot.cancel()
        if fake:
            fake.terminate()


def _png(width: int = 64, height: int = 64) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + b"".join(bytes((x * 4 % 256, y * 4 % 256, 200)) for x in range(width)) for y in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


async def _dev_image(url: str) -> bytes:
    """Presentation images in the dev stack: generated here, never fetched from the internet."""
    return _png(256, 160)


PLACES = {
    "title": "Restaurants near you",
    "kind": "places",
    "text": "Three places open now (sample data).",
    "items": [
        {
            "title": "Trattoria Sample",
            "subtitle": "Italian · 4.6 ★ · 350 m",
            "detail": "Wood-fired pizza, terrace. Open until 23:00.",
            "url": "https://example.com/trattoria",
            "image_url": "https://example.com/trattoria.jpg",
            "lat": 48.1374,
            "lon": 11.5755,
            "actions": [
                {"label": "Call", "tel": "+49 89 1234567"},
                {"label": "Route", "maps": True},
                {"label": "Menu", "url": "https://example.com/trattoria/menu"},
            ],
        },
        {
            "title": "Wirtshaus Beispiel",
            "subtitle": "Bavarian · 4.4 ★ · 600 m",
            "detail": "Beer garden, Schweinsbraten.",
            "image_url": "https://example.com/wirtshaus.jpg",
            "lat": 48.1351,
            "lon": 11.5820,
            "actions": [{"label": "Call", "tel": "+49 89 7654321"}, {"label": "Route", "maps": True}],
        },
        {
            "title": "Ramen Muster",
            "subtitle": "Japanese · 4.7 ★ · 900 m",
            "url": "https://example.com/ramen",
            "image_url": "https://example.com/ramen.jpg",
            "lat": 48.1420,
            "lon": 11.5680,
            "actions": [{"label": "Route", "maps": True}, {"label": "Website", "url": "https://example.com/ramen"}],
        },
    ],
}


async def chat_bot(bridge) -> None:
    """Stands in for the Hermes chat adapter (hermes-integration/hermes-call/adapter.py)."""
    cursor = 0
    while True:
        cursor, events = await bridge.chat.poll(cursor, 25)
        for event in events:
            with contextlib.suppress(Exception):
                await _answer(bridge, event)


async def _answer(bridge, event: dict) -> None:
    chat = bridge.chat
    if event["type"] == "approval":
        await chat.send_text(f"Approval answer: **{event['choice']}**")
        return
    text = event.get("text", "")
    await chat.typing()
    await asyncio.sleep(1.2)
    lowered = text.lower()
    if "task" in lowered:
        await _fake_task(bridge, event.get("id") or "dev")
    elif "remind" in lowered:
        params = {"action": "add", "title": "Buy milk", "place": {"query": "Rewe"}}
        result = await bridge.phone.query("geofence", "Dev bot: place reminder test", params)
        await chat.send_text(f"Geofence result:\n```\n{json.dumps(result, indent=1)}\n```")
    elif "where" in lowered:
        result = await bridge.phone.query("location", "Dev bot test", {})
        await chat.send_text(f"Location query result:\n```\n{json.dumps(result, indent=1)}\n```")
    elif "places" in lowered:
        result = await bridge.presenter.present(PLACES)
        await chat.send_text(f"Sent {result['images']} images with the cards.")
    elif "approve" in lowered:
        await chat.request_approval(f"dev-{secrets.token_hex(4)}", "rm -rf ~/tmp/old-builds", "Delete old build folders")
    elif "photo" in lowered:
        await chat.send_file(_png(), "chart.png", "image/png", "photo", "Here is a **chart**.")
    elif "file" in lowered:
        await chat.send_file(b"Hermes Call dev report\n", "report.txt", "text/plain", "file", "The report:")
    else:
        files = ", ".join(f"{a['kind']} {a['name']}" for a in event.get("attachments", []))
        await chat.send_text(f"You wrote: *{text or '(nothing)'}*" + (f"\n\nAttachments: `{files}`" if files else ""))


FAKE_TOOLS = (
    ("web_search", "hermes call live activity"),
    ("web_extract", "https://example.com/article"),
    ("terminal", "pytest -q"),
    ("patch", "bridge/tasks.py"),
    ("browser_navigate", "https://example.com"),
)


async def _fake_task(bridge, turn_id: str) -> None:
    """Five tools, 2.5 s each: the tasks ring fills, the Live Activity counts steps."""
    for index, (tool, preview) in enumerate(FAKE_TOOLS):
        await bridge.tasks.report(Progress(turn_id, tool, index, "started", preview=preview))
        await asyncio.sleep(2.5)
        await bridge.tasks.report(Progress(turn_id, tool, index, "finished", ok=True, duration=2.5))
    await bridge.chat.send_text("Done: five fake tools ran.")
    await bridge.tasks.report(Progress(turn_id, "", 0, "done"))


def app_identity() -> dict[str, str]:
    """HC_TEAM / HC_BUNDLE_ID from the iOS project's Identity.xcconfig (a local override wins)."""
    values: dict[str, str] = {}
    config = Path(__file__).resolve().parent.parent / "ios" / "Config"
    for name in ("Identity.xcconfig", "Identity.local.xcconfig"):
        path = config / name
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not line.lstrip().startswith("//"):
                values[key.strip()] = value.strip()
    return values


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--turn-host")
    parser.add_argument("--turn-secret", default="devsecret")
    parser.add_argument("--hermes-url")
    parser.add_argument("--hermes-key")
    parser.add_argument("--stt-model", default="base.en")
    parser.add_argument("--voice", default="bm_george")
    parser.add_argument("--apns-key", help="AuthKey_XXXX.p8: send real VoIP pushes (else pushes are only recorded)")
    parser.add_argument("--apns-key-id")
    identity = app_identity()
    parser.add_argument("--team-id", default=identity.get("HC_TEAM"), help="default: ios/Config/Identity*.xcconfig")
    parser.add_argument("--bundle-id", default=identity.get("HC_BUNDLE_ID"), help="default: ios/Config/Identity*.xcconfig")
    parser.add_argument("--state-dir", default="~/.cache/hermescall-dev/stack")
    parser.add_argument("--no-chat-bot", action="store_true", help="do not answer chat messages (use a real Hermes adapter)")
    asyncio.run(main(parser.parse_args()))
