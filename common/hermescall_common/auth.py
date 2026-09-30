from . import sodium

NONCE_BYTES = 32
ROLES = ("bridge", "device")


def auth_message(authority: str, role: str, identity: str, nonce: bytes) -> bytes:
    return b"|".join([b"hermescall/v1/auth", authority.encode(), role.encode(), identity.encode(), nonce])


def sign_auth(sign_sk: bytes, authority: str, role: str, identity: str, nonce: bytes) -> bytes:
    return sodium.sign_detached(sign_sk, auth_message(authority, role, identity, nonce))


def verify_auth(sign_pk: bytes, authority: str, role: str, identity: str, nonce: bytes, sig: bytes) -> bool:
    return sodium.sign_verify(sign_pk, auth_message(authority, role, identity, nonce), sig)
