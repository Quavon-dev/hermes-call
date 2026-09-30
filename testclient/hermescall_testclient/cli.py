"""hermescall-testclient: a stand-in for the iPhone app (device role) for M2 testing.

pair '<hermescall://pair?...>' | pair <relay> <code>
call  [--wav speech.wav --record reply.wav] [--seconds 30]
listen [--wav ... --record ...]          answer the agent's calls
chat  [text]                             send a chat message (or read messages with no text)
"""

import argparse
import asyncio
import contextlib
import json
import logging
import os
import sys
from collections.abc import Awaitable, Callable
from pathlib import Path

from hermescall_bridge.calls import new_call_id
from hermescall_bridge.webrtc import peer_connection
from hermescall_common import blobs, codes, sodium, wire
from hermescall_common.client import RelayEndpoint, RelaySession, new_identity_keys, pair_as_initiator
from hermescall_common.e2e import Channel
from hermescall_common.errors import ProtocolError

from .media import MicTrack, WavTrack, consume, load_wav

STATE = Path(os.environ.get("HERMESCALL_TESTCLIENT_STATE", Path.home() / ".config/hermescall-testclient/state.json"))


def load_state() -> dict:
    if not STATE.exists():
        raise SystemExit("not paired; run: hermescall-testclient pair '<link>'")
    return json.loads(STATE.read_text())


def save_state(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1))
    tmp.chmod(0o600)
    tmp.replace(STATE)


async def pair(args: list[str], name: str, trust_self_signed: bool = False) -> None:
    if len(args) == 1:
        invite = codes.parse_uri(args[0])
    else:
        host, port = codes.parse_authority(args[0])
        invite = codes.PairingInvite("device", host, port, "", codes.parse_code(args[1]))
    keys = new_identity_keys()
    payload = {"sign_pk": keys["sign_pk"], "box_pk": keys["box_pk"], "name": name}
    final, result, pin = await pair_as_initiator(invite, payload, "pair_final", allow_self_signed=trust_self_signed)
    if result.get("device_id") != final.get("device_id"):
        raise ProtocolError("device id mismatch")
    relay = result["relay"]
    if relay["pin"] != pin or relay["host"] != invite.host:
        raise ProtocolError("bridge reports a different relay identity")
    save_state({"keys": keys, "device_id": result["device_id"], "bridge": result, "relay": relay})
    print(f"paired with {result['bridge_name']} via {invite.host} as device {result['device_id'][:6]}…")


# phone_query body → answer {status, data?} (None: leave the query in the inbox)
QueryAnswerer = Callable[[dict], Awaitable[dict | None]]


class Device:
    def __init__(self, state: dict, approve: str | None, answer_queries: QueryAnswerer | None = None) -> None:
        self.state = state
        relay = state["relay"]
        self.bridge_id = state["bridge"]["bridge_id"]
        self.bridge_pk = wire.b64d(state["bridge"]["bridge_box_pk"], length=32)
        self.channel = Channel(state["device_id"], wire.b64d(state["keys"]["box_sk"]))
        self.inbox: asyncio.Queue[dict] = asyncio.Queue()
        self.approve = approve
        self.answer_queries = answer_queries
        self.session = RelaySession(
            RelayEndpoint(relay["host"], relay["port"], relay["pin"]),
            "device",
            state["device_id"],
            wire.b64d(state["keys"]["sign_sk"]),
            self.on_event,
        )

    async def on_event(self, message: dict) -> None:
        if message["t"] == "mail":
            body = self.channel.open(self.bridge_id, self.bridge_pk, message["data"])
            await self.session.send({"t": "mail_ack", "ids": [message["id"]]})
        elif message["t"] == "e2e":
            body = self.channel.open(self.bridge_id, self.bridge_pk, message["data"])
        else:
            return
        if body["type"] == "approval_request" and ("call_id" in body or self.approve is not None):
            await self.answer_approval(body)
        elif body["type"] == "phone_query" and self.answer_queries is not None:
            answer = await self.answer_queries(body)
            if answer is None:
                await self.inbox.put(body)
            else:
                await self.answer_query(body, **answer)
        else:
            await self.inbox.put(body)

    async def answer_approval(self, body: dict) -> None:
        print(f"\nThe agent asks for approval:\n  command: {body['command']}\n  {body['description']}")
        choice = self.approve
        if choice is None:
            reply = await asyncio.get_running_loop().run_in_executor(None, input, "approve once? [y/N] ")
            choice = "once" if reply.strip().lower() == "y" else "deny"
        answer = {"type": "approval", "request_id": body["request_id"], "choice": choice}
        if "call_id" in body:
            answer["call_id"] = body["call_id"]
        await self.send(answer, mail=bool(body.get("chat")))

    async def answer_query(self, query: dict, status: str, data: dict | None = None) -> None:
        answer = {"type": "phone_answer", "query_id": query["query_id"], "status": status}
        if data is not None:
            answer["data"] = data
        await self.send(answer, mail=True)

    async def upload(self, data: bytes) -> tuple[str, str]:
        """An encrypted blob for the bridge: (blob_id, key)."""
        key, sealed = blobs.seal(data)
        return await blobs.upload(self.session, sealed), wire.b64e(key)

    async def send(self, body: dict, mail: bool = False) -> None:
        mid = wire.b64e(sodium.random_bytes(16)) if mail else None
        await self.session.send({"t": "e2e", "data": self.channel.seal(self.bridge_id, self.bridge_pk, body, mid=mid)})

    async def send_chat(self, text: str, files: list[tuple[str, str, str, bytes]] = ()) -> str:
        """files: (kind, name, mime, data). Returns the message id."""
        attachments = []
        for kind, name, mime, data in files:
            blob_id, key = await self.upload(data)
            attachments.append({"kind": kind, "blob_id": blob_id, "key": key, "name": name, "mime": mime})
        message_id = wire.b64e(sodium.random_bytes(16))
        await self.send({"type": "chat", "id": message_id, "text": text, "attachments": attachments}, mail=True)
        return message_id

    async def fetch_attachment(self, ref: dict) -> bytes:
        data = blobs.open_sealed(wire.b64d(ref["key"], length=32), await blobs.download(self.session, ref["blob_id"]))
        await blobs.delete(self.session, ref["blob_id"])
        return data

    async def expect(self, call_id: str, *types: str, timeout: float) -> dict:
        while True:
            body = await asyncio.wait_for(self.inbox.get(), timeout)
            if body.get("call_id") == call_id and body["type"] in types:
                return body

    async def call(self, call_id: str, wav: str | None, record: str | None, seconds: float, delay: float = 1.0) -> None:
        turn = await self.session.request({"t": "turn"})
        pc = peer_connection(turn)
        source = WavTrack(load_wav(wav), delay) if wav else MicTrack()
        pc.addTrack(source)
        sink: asyncio.Future = asyncio.get_running_loop().create_future()

        @pc.on("track")
        def on_track(track) -> None:
            sink.set_result(asyncio.ensure_future(consume(track, record, source)))

        await pc.setLocalDescription(await pc.createOffer())
        await self.send({"type": "offer", "call_id": call_id, "sdp": pc.localDescription.sdp})
        reply = await self.expect(call_id, "answer", "busy", "cancel", timeout=30)
        if reply["type"] != "answer":
            print(f"call not accepted: {reply['type']} {reply.get('why', '')}")
            await pc.close()
            return
        await pc.setRemoteDescription(type(pc.localDescription)(sdp=reply["sdp"], type="answer"))
        kinds = sorted({line.split(" typ ")[1].split()[0] for line in reply["sdp"].splitlines() if " typ " in line})
        print(f"connected; bridge offered ICE candidate types: {', '.join(kinds)}. Ctrl-C to hang up.")
        with contextlib.suppress(TimeoutError):
            await self.expect(call_id, "hangup", timeout=seconds)
            print("the agent hung up")
        await self.send({"type": "hangup", "call_id": call_id})
        await pc.close()
        if sink.done():
            try:
                latencies = await asyncio.wait_for(sink.result(), 5)
            except TimeoutError:
                print("no audio received from the agent")
                return
            for n, value in enumerate(latencies, 1):
                print(f"latency {n}: end of my speech → first agent audio {value * 1000:.0f} ms")


async def run(command: str, args: argparse.Namespace) -> None:
    device = Device(load_state(), args.approve)
    runner = asyncio.ensure_future(device.session.run())
    try:
        await asyncio.wait_for(device.session.connected.wait(), 20)
        if command == "chat":
            await chat(device, args.text)
            return
        if command == "call":
            await device.call(new_call_id(), args.wav, args.record, args.seconds, args.delay)
            return
        print("waiting for the agent to call…")
        while True:
            body = await device.inbox.get()
            if body["type"] == "invite":
                print(f"incoming call from the agent — reason: {body.get('reason') or '-'}")
                await device.call(body["call_id"], args.wav, args.record, args.seconds, args.delay)
                if args.once:
                    return
    finally:
        device.session.stop()
        runner.cancel()


async def chat(device: Device, text: str) -> None:
    await device.session.request({"t": "mail_fetch"})
    if text:
        await device.send_chat(text)
        print("sent; waiting 60 s for replies (Ctrl-C to stop)…")
    with contextlib.suppress(TimeoutError):
        while True:
            body = await asyncio.wait_for(device.inbox.get(), 60)
            if body["type"] == "chat":
                print(f"[{body.get('role')}] {body.get('text', '')}")
            elif body["type"] == "chat_ack":
                print(f"  ({body.get('state')}{': ' + body['transcript'] if body.get('transcript') else ''})")
            elif body["type"] == "typing":
                print("  (typing…)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermescall-testclient")
    sub = parser.add_subparsers(dest="command", required=True)
    pair_cmd = sub.add_parser("pair")
    pair_cmd.add_argument("invite", nargs="+")
    pair_cmd.add_argument("--name", default="Test client")
    pair_cmd.add_argument("--trust-self-signed", action="store_true", help="accept a self-signed relay key (dev relays)")
    for name in ("call", "listen"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--wav", help="16-bit WAV to speak instead of the microphone")
        cmd.add_argument("--record", help="write the agent's audio to this WAV instead of the speaker")
        cmd.add_argument("--seconds", type=float, default=300)
        cmd.add_argument("--delay", type=float, default=1.0, help="seconds before the WAV starts")
        cmd.add_argument("--approve", choices=("once", "deny"), help="answer approval requests automatically")
        cmd.add_argument("--once", action="store_true", help="listen: exit after one call")
    chat_cmd = sub.add_parser("chat")
    chat_cmd.add_argument("text", nargs="?", default="")
    chat_cmd.add_argument("--approve", choices=("once", "deny"), help="answer approval requests automatically")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    try:
        if args.command == "pair":
            asyncio.run(pair(args.invite, args.name, args.trust_self_signed))
        else:
            asyncio.run(run(args.command, args))
    except (ProtocolError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
