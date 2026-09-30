"""Signed requests from a relay to the push gateway.

Each relay has its own Ed25519 key (`push_gateway_key`, created by the installer); its public key
is the relay's identity at the gateway, so there is no sign-up step. The header is

    Authorization: HC-Relay <public key>.<unix time>.<nonce>.<signature>   (base64url)

over `hermescall-push-v1\\n<unix time>\\n<nonce>\\n<sha256(body)>`. The random nonce keeps two
identical pushes apart (Ed25519 signatures are deterministic). TLS protects the request in transit;
the time window and the gateway's replay cache stop a captured request from being sent again.
"""

import hashlib
import os
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from hermescall_common.errors import ProtocolError
from hermescall_common.wire import b64d, b64e

SCHEME = "HC-Relay"
CONTEXT = b"hermescall-push-v1\n"
MAX_SKEW_SECONDS = 60
NONCE_BYTES = 16


class AuthError(Exception):
    pass


def load_key(pem: bytes) -> Ed25519PrivateKey:
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("push gateway key must be an Ed25519 key")
    return key


def relay_id(key: Ed25519PrivateKey) -> str:
    return b64e(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))


def _signing_input(timestamp: int, nonce: bytes, body: bytes) -> bytes:
    return CONTEXT + str(timestamp).encode() + b"\n" + nonce + b"\n" + hashlib.sha256(body).digest()


def sign(key: Ed25519PrivateKey, body: bytes, now: float | None = None) -> str:
    timestamp = int(time.time() if now is None else now)
    nonce = os.urandom(NONCE_BYTES)
    signature = key.sign(_signing_input(timestamp, nonce, body))
    return f"{SCHEME} {relay_id(key)}.{timestamp}.{b64e(nonce)}.{b64e(signature)}"


def verify(header: str, body: bytes, now: float | None = None) -> tuple[str, bytes]:
    """Returns (relay id, signature) or raises AuthError."""
    now = time.time() if now is None else now
    scheme, _, credentials = header.partition(" ")
    parts = credentials.split(".")
    if scheme != SCHEME or len(parts) != 4 or not (parts[1].isascii() and parts[1].isdigit()) or len(parts[1]) > 12:
        raise AuthError("malformed authorization")
    timestamp = int(parts[1])
    if abs(now - timestamp) > MAX_SKEW_SECONDS:
        raise AuthError("stale request")
    try:
        public = b64d(parts[0], length=32)
        nonce = b64d(parts[2], length=NONCE_BYTES)
        signature = b64d(parts[3], length=64)
        Ed25519PublicKey.from_public_bytes(public).verify(signature, _signing_input(timestamp, nonce, body))
    except (ProtocolError, ValueError, InvalidSignature) as exc:
        raise AuthError("bad signature") from exc
    return parts[0], signature
