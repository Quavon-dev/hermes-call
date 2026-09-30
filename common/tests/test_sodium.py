import pytest

from hermescall_common import auth, sodium, wire
from hermescall_common.errors import CryptoError, ProtocolError


def test_aead_roundtrip_and_tamper() -> None:
    key = sodium.random_bytes(32)
    sealed = sodium.aead_encrypt(key, b"hello", b"ad")
    assert sodium.aead_decrypt(key, sealed, b"ad") == b"hello"
    tampered = sealed[:-1] + bytes([sealed[-1] ^ 1])
    for args in ((key, tampered, b"ad"), (key, sealed, b"other"), (sodium.random_bytes(32), sealed, b"ad"), (key, b"x", b"")):
        with pytest.raises(CryptoError):
            sodium.aead_decrypt(*args)


def test_box_roundtrip_is_mutually_authenticated() -> None:
    a_pk, a_sk = sodium.box_keypair()
    b_pk, b_sk = sodium.box_keypair()
    m_pk, m_sk = sodium.box_keypair()
    sealed = sodium.box_seal(b"sdp", b_pk, a_sk)
    assert sodium.box_open(sealed, a_pk, b_sk) == b"sdp"
    with pytest.raises(CryptoError):
        sodium.box_open(sealed, m_pk, b_sk)


def test_auth_signature_binds_all_fields() -> None:
    pk, sk = sodium.sign_keypair()
    nonce = sodium.random_bytes(32)
    sig = auth.sign_auth(sk, "relay.example.com", "device", "id1", nonce)
    assert auth.verify_auth(pk, "relay.example.com", "device", "id1", nonce, sig)
    assert not auth.verify_auth(pk, "relay.example.com", "bridge", "id1", nonce, sig)
    assert not auth.verify_auth(pk, "other.example.com", "device", "id1", nonce, sig)
    assert not auth.verify_auth(pk, "relay.example.com", "device", "id1", sodium.random_bytes(32), sig)
    assert not auth.verify_auth(pk, "relay.example.com", "device", "id1", nonce, b"short")


def test_wire_validation() -> None:
    assert wire.b64d(wire.b64e(b"abc")) == b"abc"
    for bad in (None, 5, "***", "a" * 200_000):
        with pytest.raises(ProtocolError):
            wire.b64d(bad)
    with pytest.raises(ProtocolError):
        wire.b64d(wire.b64e(b"abc"), length=4)
    for raw in ("[]", "{}", '{"t": 1}', "nope", "x" * (wire.MAX_MESSAGE_BYTES + 1)):
        with pytest.raises(ProtocolError):
            wire.decode(raw)
    assert wire.decode('{"t":"x"}') == {"t": "x"}
