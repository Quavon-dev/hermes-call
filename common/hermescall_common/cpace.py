"""CPace (ristretto255, SHA-512): a line-by-line port of jedisct1/cpace.

Wire-compatible with third_party/cpace/crypto_cpace.c, which the iOS app
compiles directly; tests/test_cpace_interop.py enforces this.
"""

import hashlib
from dataclasses import dataclass

from . import sodium
from .errors import CryptoError

DSI1 = b"CPaceRistretto255-1"
DSI2 = b"CPaceRistretto255-2"
SESSION_ID_BYTES = 16
PUBLIC_DATA_BYTES = SESSION_ID_BYTES + sodium.RISTRETTO_BYTES
RESPONSE_BYTES = sodium.RISTRETTO_BYTES
_HASH_BLOCKSIZE = 128


@dataclass(frozen=True)
class SharedKeys:
    client_sk: bytes
    server_sk: bytes


@dataclass(frozen=True)
class ClientState:
    session_id: bytes
    p: bytes
    r: bytes


def _check_id(value: bytes) -> None:
    if len(value) > 255:
        raise CryptoError("identity too long")


def _ctx_init(session_id: bytes, password: bytes, id_a: bytes, id_b: bytes, ad: bytes) -> tuple[bytes, bytes]:
    _check_id(id_a)
    _check_id(id_b)
    pad_len = (_HASH_BLOCKSIZE - (len(DSI1) + len(password))) % _HASH_BLOCKSIZE
    h = hashlib.sha512(
        DSI1 + password + bytes(pad_len) + session_id + bytes([len(id_a)]) + id_a + bytes([len(id_b)]) + id_b + ad
    ).digest()
    generator = sodium.ristretto255_from_hash(h)
    r = sodium.ristretto255_scalar_random()
    return sodium.scalarmult_ristretto255(r, generator), r


def _ctx_final(session_id: bytes, r: bytes, op: bytes, ya: bytes, yb: bytes) -> SharedKeys:
    p = sodium.scalarmult_ristretto255(r, op)
    h = hashlib.sha512(DSI2 + session_id + p + ya + yb).digest()
    return SharedKeys(client_sk=h[:32], server_sk=h[32:64])


def step1(password: bytes, id_a: bytes, id_b: bytes, ad: bytes) -> tuple[ClientState, bytes]:
    session_id = sodium.random_bytes(SESSION_ID_BYTES)
    p, r = _ctx_init(session_id, password, id_a, id_b, ad)
    return ClientState(session_id, p, r), session_id + p


def step2(public_data: bytes, password: bytes, id_a: bytes, id_b: bytes, ad: bytes) -> tuple[bytes, SharedKeys]:
    if len(public_data) != PUBLIC_DATA_BYTES:
        raise CryptoError("bad CPace public data")
    session_id, ya = public_data[:SESSION_ID_BYTES], public_data[SESSION_ID_BYTES:]
    response, r = _ctx_init(session_id, password, id_a, id_b, ad)
    return response, _ctx_final(session_id, r, ya, ya, response)


def step3(state: ClientState, response: bytes) -> SharedKeys:
    if len(response) != RESPONSE_BYTES:
        raise CryptoError("bad CPace response")
    return _ctx_final(state.session_id, state.r, response, state.p, response)
