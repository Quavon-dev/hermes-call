"""CPace pairing handshake shared by relay, bridge and (in Swift) the iOS app.

initiator -> responder : cpace public data (48 bytes)
responder -> initiator : cpace response (32 bytes)
initiator -> responder : AEAD(client_sk, initiator payload)
responder -> initiator : AEAD(server_sk, responder payload)

The associated data binds the handshake to the relay authority and, for
self-signed relays, the TLS SPKI pin each side believes in. A TLS
man-in-the-middle therefore breaks key agreement instead of learning keys.
"""

import json
from dataclasses import dataclass
from typing import Any

from . import cpace, sodium
from .codes import format_authority
from .errors import CryptoError, ProtocolError

MAX_PAYLOAD_BYTES = 4096
_IDS = {"relay": (b"bridge", b"relay"), "device": (b"device", b"bridge")}
_AD_CLIENT = b"hermescall/v1/pair/initiator"
_AD_SERVER = b"hermescall/v1/pair/responder"


@dataclass(frozen=True)
class Context:
    kind: str
    host: str
    port: int
    pin: str

    def ids(self) -> tuple[bytes, bytes]:
        if self.kind not in _IDS:
            raise ProtocolError("unknown pairing kind")
        return _IDS[self.kind]

    def ad(self) -> bytes:
        return f"hermescall/v1/{self.kind}-pair|{format_authority(self.host, self.port)}|{self.pin}".encode()


def start(ctx: Context, secret: str) -> tuple[cpace.ClientState, bytes]:
    id_a, id_b = ctx.ids()
    return cpace.step1(secret.encode(), id_a, id_b, ctx.ad())


def respond(ctx: Context, secret: str, public_data: bytes) -> tuple[bytes, cpace.SharedKeys]:
    id_a, id_b = ctx.ids()
    return cpace.step2(public_data, secret.encode(), id_a, id_b, ctx.ad())


def finish(state: cpace.ClientState, response: bytes) -> cpace.SharedKeys:
    return cpace.step3(state, response)


def _seal(key: bytes, ad: bytes, payload: dict[str, Any]) -> bytes:
    data = json.dumps(payload, separators=(",", ":")).encode()
    if len(data) > MAX_PAYLOAD_BYTES:
        raise ProtocolError("payload too large")
    return sodium.aead_encrypt(key, data, ad)


def _open(key: bytes, ad: bytes, sealed: bytes) -> dict[str, Any]:
    if len(sealed) > MAX_PAYLOAD_BYTES + 64:
        raise CryptoError("decryption failed")
    payload = json.loads(sodium.aead_decrypt(key, sealed, ad))
    if not isinstance(payload, dict):
        raise ProtocolError("invalid payload")
    return payload


def seal_initiator(keys: cpace.SharedKeys, payload: dict[str, Any]) -> bytes:
    return _seal(keys.client_sk, _AD_CLIENT, payload)


def open_initiator(keys: cpace.SharedKeys, sealed: bytes) -> dict[str, Any]:
    return _open(keys.client_sk, _AD_CLIENT, sealed)


def seal_responder(keys: cpace.SharedKeys, payload: dict[str, Any]) -> bytes:
    return _seal(keys.server_sk, _AD_SERVER, payload)


def open_responder(keys: cpace.SharedKeys, sealed: bytes) -> dict[str, Any]:
    return _open(keys.server_sk, _AD_SERVER, sealed)
