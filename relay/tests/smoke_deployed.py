"""Smoke test against a deployed relay (through Caddy/TLS).

usage: python3 smoke_deployed.py 'hermescall://pair?...'

Pairs a throwaway bridge and device, exercises routing and TURN credentials,
then revokes the device. Uses only the relay's public interface.
"""

import asyncio
import hashlib
import ssl
import sys

import aiohttp
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from hermescall_common import auth, codes, pairing, sodium, wire


def spki_pin(der_cert: bytes) -> str:
    public_key = x509.load_der_x509_certificate(der_cert).public_key()
    spki = public_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return wire.b64e(hashlib.sha256(spki).digest())


def tls_context(pin: str) -> ssl.SSLContext:
    if not pin:
        return ssl.create_default_context()
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


async def open_ws(session: aiohttp.ClientSession, invite: codes.PairingInvite, path: str):
    url = f"wss://{codes.format_authority(invite.host, invite.port)}{path}"
    ws = await session.ws_connect(url, ssl=tls_context(invite.pin))
    if invite.pin:
        der = ws.get_extra_info("ssl_object").getpeercert(binary_form=True)
        if spki_pin(der) != invite.pin:
            await ws.close()
            raise SystemExit("TLS pin mismatch: possible man-in-the-middle")
    return ws


async def recv(ws, kind: str) -> dict:
    while True:
        message = wire.decode((await ws.receive(timeout=10)).data)
        if message["t"] == kind:
            return message
        if message["t"] == "error":
            raise SystemExit(f"relay error: {message}")


async def main(uri: str) -> None:
    invite = codes.parse_uri(uri)
    ctx = pairing.Context("relay", invite.host, invite.port, invite.pin)
    bridge_pk, bridge_sk = sodium.sign_keypair()
    async with aiohttp.ClientSession() as session:
        ws = await open_ws(session, invite, "/v1/pair")
        state, public = pairing.start(ctx, invite.code.secret)
        await ws.send_str(wire.encode({"t": "join", "slot": invite.code.slot, "msg": wire.b64e(public)}))
        keys = pairing.finish(state, wire.b64d((await recv(ws, "cpace"))["msg"]))
        sealed = pairing.seal_initiator(keys, {"sign_pk": wire.b64e(bridge_pk)})
        await ws.send_str(wire.encode({"t": "confirm", "data": wire.b64e(sealed)}))
        bridge_id = pairing.open_responder(keys, wire.b64d((await recv(ws, "paired"))["data"]))["bridge_id"]
        await ws.close()
        print(f"bridge paired: {bridge_id[:6]}…")

        authority = codes.format_authority(invite.host, invite.port)
        bridge = await open_ws(session, invite, "/v1/ws")
        nonce = wire.b64d((await recv(bridge, "challenge"))["nonce"])
        sig = auth.sign_auth(bridge_sk, authority, "bridge", bridge_id, nonce)
        await bridge.send_str(wire.encode({"t": "auth", "role": "bridge", "id": bridge_id, "sig": wire.b64e(sig)}))
        await recv(bridge, "ready")
        await bridge.send_str(wire.encode({"t": "turn"}))
        turn = await recv(bridge, "turn")
        print(f"turn: {turn['urls']} user={turn['username']} cred={turn['credential']}")

        await bridge.send_str(wire.encode({"t": "open_slot"}))
        slot = (await recv(bridge, "slot_opened"))["slot"]
        secret = codes.random_chars(codes.TYPED_SECRET_LEN)
        dctx = pairing.Context("device", invite.host, invite.port, invite.pin)
        device_pk, device_sk = sodium.sign_keypair()
        dev = await open_ws(session, invite, "/v1/pair")
        dstate, dpublic = pairing.start(dctx, secret)
        await dev.send_str(wire.encode({"t": "join", "slot": slot, "msg": wire.b64e(dpublic)}))
        join = await recv(bridge, "pair_join")
        response, bkeys = pairing.respond(dctx, secret, wire.b64d(join["msg"]))
        await bridge.send_str(wire.encode({"t": "pair_msg", "conn": join["conn"], "data": wire.b64e(response)}))
        dkeys = pairing.finish(dstate, wire.b64d((await recv(dev, "pair_msg"))["data"]))
        confirm = pairing.seal_initiator(dkeys, {"sign_pk": wire.b64e(device_pk)})
        await dev.send_str(wire.encode({"t": "pair_msg", "data": wire.b64e(confirm)}))
        payload = pairing.open_initiator(bkeys, wire.b64d((await recv(bridge, "pair_msg"))["data"]))
        done = {"t": "pair_done", "conn": join["conn"], "ok": True, "sign_pk": payload["sign_pk"]}
        await bridge.send_str(wire.encode(done))
        device_id = (await recv(bridge, "pair_registered"))["device_id"]
        final = pairing.seal_responder(bkeys, {"device_id": device_id})
        await bridge.send_str(wire.encode({"t": "pair_final", "conn": join["conn"], "data": wire.b64e(final)}))
        await recv(dev, "pair_final")
        await dev.close()
        print(f"device paired: {device_id[:6]}…")

        device = await open_ws(session, invite, "/v1/ws")
        nonce = wire.b64d((await recv(device, "challenge"))["nonce"])
        sig = auth.sign_auth(device_sk, authority, "device", device_id, nonce)
        await device.send_str(wire.encode({"t": "auth", "role": "device", "id": device_id, "sig": wire.b64e(sig)}))
        await recv(device, "ready")
        await bridge.send_str(wire.encode({"t": "e2e", "to": device_id, "data": wire.b64e(b"ping")}))
        assert wire.b64d((await recv(device, "e2e"))["data"]) == b"ping"
        await bridge.send_str(wire.encode({"t": "revoke_device", "device_id": device_id}))
        await recv(bridge, "revoked")
        print("routing ok, device revoked")
        await bridge.close()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
