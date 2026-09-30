"""Minimal ctypes binding to the system libsodium (>= 1.0.18)."""

import ctypes
import ctypes.util
import os

from .errors import CryptoError

RISTRETTO_BYTES = 32
RISTRETTO_HASHBYTES = 64
AEAD_KEYBYTES = 32
AEAD_NONCEBYTES = 24
AEAD_ABYTES = 16
SIGN_PKBYTES = 32
SIGN_SKBYTES = 64
SIGN_BYTES = 64
BOX_PKBYTES = 32
BOX_SKBYTES = 32
BOX_NONCEBYTES = 24
BOX_MACBYTES = 16


def _load() -> ctypes.CDLL:
    path = os.environ.get("HERMESCALL_LIBSODIUM") or ctypes.util.find_library("sodium")
    candidates = [path] if path else []
    candidates += ["libsodium.so.23", "libsodium.so.26", "libsodium.dylib", "/opt/homebrew/lib/libsodium.dylib"]
    for candidate in candidates:
        try:
            lib = ctypes.CDLL(candidate)
        except OSError:
            continue
        if lib.sodium_init() < 0:
            raise CryptoError("sodium_init failed")
        return lib
    raise CryptoError("libsodium not found")


_P = ctypes.c_char_p
_ULL = ctypes.c_ulonglong
_ULLP = ctypes.POINTER(ctypes.c_ulonglong)
_SIGNATURES = {
    "randombytes_buf": (None, [_P, ctypes.c_size_t]),
    "crypto_core_ristretto255_from_hash": (ctypes.c_int, [_P, _P]),
    "crypto_core_ristretto255_scalar_random": (None, [_P]),
    "crypto_scalarmult_ristretto255": (ctypes.c_int, [_P, _P, _P]),
    "crypto_aead_xchacha20poly1305_ietf_encrypt": (ctypes.c_int, [_P, _ULLP, _P, _ULL, _P, _ULL, _P, _P, _P]),
    "crypto_aead_xchacha20poly1305_ietf_decrypt": (ctypes.c_int, [_P, _ULLP, _P, _P, _ULL, _P, _ULL, _P, _P]),
    "crypto_sign_ed25519_keypair": (ctypes.c_int, [_P, _P]),
    "crypto_sign_ed25519_detached": (ctypes.c_int, [_P, _ULLP, _P, _ULL, _P]),
    "crypto_sign_ed25519_verify_detached": (ctypes.c_int, [_P, _P, _ULL, _P]),
    "crypto_box_keypair": (ctypes.c_int, [_P, _P]),
    "crypto_box_easy": (ctypes.c_int, [_P, _P, _ULL, _P, _P, _P]),
    "crypto_box_open_easy": (ctypes.c_int, [_P, _P, _ULL, _P, _P, _P]),
}


def _bind(lib: ctypes.CDLL) -> ctypes.CDLL:
    for name, (restype, argtypes) in _SIGNATURES.items():
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
    return lib


_lib = _bind(_load())
_ull = _ULL
_buf = ctypes.create_string_buffer


def random_bytes(n: int) -> bytes:
    out = _buf(n)
    _lib.randombytes_buf(out, ctypes.c_size_t(n))
    return out.raw


def ristretto255_from_hash(h: bytes) -> bytes:
    if len(h) != RISTRETTO_HASHBYTES:
        raise CryptoError("bad hash length")
    out = _buf(RISTRETTO_BYTES)
    if _lib.crypto_core_ristretto255_from_hash(out, h) != 0:
        raise CryptoError("from_hash failed")
    return out.raw


def ristretto255_scalar_random() -> bytes:
    out = _buf(RISTRETTO_BYTES)
    _lib.crypto_core_ristretto255_scalar_random(out)
    return out.raw


def scalarmult_ristretto255(scalar: bytes, point: bytes) -> bytes:
    if len(scalar) != RISTRETTO_BYTES or len(point) != RISTRETTO_BYTES:
        raise CryptoError("bad ristretto255 input length")
    out = _buf(RISTRETTO_BYTES)
    if _lib.crypto_scalarmult_ristretto255(out, scalar, point) != 0:
        raise CryptoError("invalid ristretto255 point")
    return out.raw


def aead_encrypt(key: bytes, plaintext: bytes, ad: bytes = b"") -> bytes:
    if len(key) != AEAD_KEYBYTES:
        raise CryptoError("bad key length")
    nonce = random_bytes(AEAD_NONCEBYTES)
    out = _buf(len(plaintext) + AEAD_ABYTES)
    out_len = _ull()
    rc = _lib.crypto_aead_xchacha20poly1305_ietf_encrypt(
        out,
        ctypes.byref(out_len),
        plaintext,
        _ull(len(plaintext)),
        ad,
        _ull(len(ad)),
        None,
        nonce,
        key,
    )
    if rc != 0:
        raise CryptoError("encryption failed")
    return nonce + out.raw[: out_len.value]


def aead_decrypt(key: bytes, sealed: bytes, ad: bytes = b"") -> bytes:
    if len(key) != AEAD_KEYBYTES or len(sealed) < AEAD_NONCEBYTES + AEAD_ABYTES:
        raise CryptoError("decryption failed")
    nonce, ct = sealed[:AEAD_NONCEBYTES], sealed[AEAD_NONCEBYTES:]
    out = _buf(len(ct))
    out_len = _ull()
    rc = _lib.crypto_aead_xchacha20poly1305_ietf_decrypt(
        out,
        ctypes.byref(out_len),
        None,
        ct,
        _ull(len(ct)),
        ad,
        _ull(len(ad)),
        nonce,
        key,
    )
    if rc != 0:
        raise CryptoError("decryption failed")
    return out.raw[: out_len.value]


def sign_keypair() -> tuple[bytes, bytes]:
    pk, sk = _buf(SIGN_PKBYTES), _buf(SIGN_SKBYTES)
    if _lib.crypto_sign_ed25519_keypair(pk, sk) != 0:
        raise CryptoError("keypair generation failed")
    return pk.raw, sk.raw


def sign_detached(sk: bytes, message: bytes) -> bytes:
    if len(sk) != SIGN_SKBYTES:
        raise CryptoError("bad secret key length")
    sig = _buf(SIGN_BYTES)
    if _lib.crypto_sign_ed25519_detached(sig, None, message, _ull(len(message)), sk) != 0:
        raise CryptoError("signing failed")
    return sig.raw


def sign_verify(pk: bytes, message: bytes, sig: bytes) -> bool:
    if len(pk) != SIGN_PKBYTES or len(sig) != SIGN_BYTES:
        return False
    return _lib.crypto_sign_ed25519_verify_detached(sig, message, _ull(len(message)), pk) == 0


def box_keypair() -> tuple[bytes, bytes]:
    pk, sk = _buf(BOX_PKBYTES), _buf(BOX_SKBYTES)
    if _lib.crypto_box_keypair(pk, sk) != 0:
        raise CryptoError("keypair generation failed")
    return pk.raw, sk.raw


def box_seal(plaintext: bytes, their_pk: bytes, my_sk: bytes) -> bytes:
    if len(their_pk) != BOX_PKBYTES or len(my_sk) != BOX_SKBYTES:
        raise CryptoError("bad box key length")
    nonce = random_bytes(BOX_NONCEBYTES)
    out = _buf(len(plaintext) + BOX_MACBYTES)
    if _lib.crypto_box_easy(out, plaintext, _ull(len(plaintext)), nonce, their_pk, my_sk) != 0:
        raise CryptoError("box failed")
    return nonce + out.raw


def box_open(sealed: bytes, their_pk: bytes, my_sk: bytes) -> bytes:
    if len(their_pk) != BOX_PKBYTES or len(my_sk) != BOX_SKBYTES or len(sealed) < BOX_NONCEBYTES + BOX_MACBYTES:
        raise CryptoError("decryption failed")
    nonce, ct = sealed[:BOX_NONCEBYTES], sealed[BOX_NONCEBYTES:]
    out = _buf(len(ct) - BOX_MACBYTES)
    if _lib.crypto_box_open_easy(out, ct, _ull(len(ct)), nonce, their_pk, my_sk) != 0:
        raise CryptoError("decryption failed")
    return out.raw
