"""Pairing codes and pairing URIs.

A code is `slot + secret` in Crockford base32. The slot only routes the
attempt at the relay; the secret is the CPace password and never leaves
the two endpoints.
"""

import ipaddress
import re
import secrets
from dataclasses import dataclass
from urllib.parse import parse_qs, urlencode, urlsplit

from .errors import ProtocolError

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
SLOT_LEN = 3
TYPED_SECRET_LEN = 5
QR_SECRET_LEN = 26
URI_SCHEME = "hermescall"
KINDS = ("relay", "device")

_NORMALIZE = str.maketrans({"O": "0", "I": "1", "L": "1", "-": None, " ": None})
_HOST_LABEL = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)\Z")
_PIN = re.compile(r"^[A-Za-z0-9_-]{43}\Z")
_AUTHORITY = re.compile(r"^(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?\Z")


@dataclass(frozen=True)
class Code:
    slot: str
    secret: str

    def display(self) -> str:
        return f"{self.slot}-{self.secret}"


@dataclass(frozen=True)
class PairingInvite:
    kind: str
    host: str
    port: int
    pin: str
    code: Code

    def to_uri(self) -> str:
        query = {"v": "1", "k": self.kind, "r": format_authority(self.host, self.port), "c": self.code.slot + self.code.secret}
        if self.pin:
            query["pin"] = self.pin
        return f"{URI_SCHEME}://pair?{urlencode(query)}"


RELAY_SLOT_PREFIXES = "0123456789"
DEVICE_SLOT_PREFIXES = ALPHABET[10:]


def random_chars(n: int, alphabet: str = ALPHABET) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(n))


def new_relay_slot() -> str:
    return random_chars(1, RELAY_SLOT_PREFIXES) + random_chars(SLOT_LEN - 1)


def new_device_slot() -> str:
    return random_chars(1, DEVICE_SLOT_PREFIXES) + random_chars(SLOT_LEN - 1)


def is_relay_slot(slot: str) -> bool:
    return slot[:1] in RELAY_SLOT_PREFIXES


def new_code(slot: str, secret_len: int = TYPED_SECRET_LEN) -> Code:
    return Code(slot=slot, secret=random_chars(secret_len))


def parse_code(text: str) -> Code:
    normalized = text.upper().translate(_NORMALIZE)
    if not (SLOT_LEN + TYPED_SECRET_LEN <= len(normalized) <= SLOT_LEN + QR_SECRET_LEN):
        raise ProtocolError("invalid code")
    if any(ch not in ALPHABET for ch in normalized):
        raise ProtocolError("invalid code")
    return Code(slot=normalized[:SLOT_LEN], secret=normalized[SLOT_LEN:])


def is_valid_slot(slot: object) -> bool:
    return isinstance(slot, str) and len(slot) == SLOT_LEN and all(ch in ALPHABET for ch in slot)


def validate_host(host: str) -> str:
    host = host.strip().lower().rstrip(".")
    if host.startswith("[") and host.endswith("]"):
        ipaddress.IPv6Address(host[1:-1])
        return host
    try:
        ipaddress.IPv4Address(host)
        return host
    except ValueError:
        pass
    labels = host.split(".")
    if len(host) > 253 or not all(_HOST_LABEL.match(label) for label in labels):
        raise ProtocolError("invalid host")
    return host


def format_authority(host: str, port: int) -> str:
    return host if port == 443 else f"{host}:{port}"


def parse_authority(authority: str) -> tuple[str, int]:
    authority = authority.strip()
    if not _AUTHORITY.match(authority):
        raise ProtocolError("invalid relay address")
    parsed = urlsplit(f"//{authority}")
    try:
        port = parsed.port or 443
        if not 0 < port < 65536:
            raise ValueError
    except ValueError as exc:
        raise ProtocolError("invalid port") from exc
    raw_host = parsed.hostname or ""
    host = f"[{raw_host}]" if ":" in raw_host else raw_host
    try:
        return validate_host(host), port
    except ValueError as exc:
        raise ProtocolError("invalid host") from exc


def validate_pin(pin: str) -> str:
    if pin and not _PIN.match(pin):
        raise ProtocolError("invalid pin")
    return pin


def parse_uri(uri: str) -> PairingInvite:
    try:
        return _parse_uri(uri)
    except ValueError as exc:
        raise ProtocolError("invalid pairing link") from exc


def _parse_uri(uri: str) -> PairingInvite:
    parts = urlsplit(uri.strip())
    if parts.scheme != URI_SCHEME or parts.netloc != "pair":
        raise ProtocolError("not a pairing link")
    query = {key: values[0] for key, values in parse_qs(parts.query, strict_parsing=True).items() if len(values) == 1}
    if query.get("v") != "1" or query.get("k") not in KINDS:
        raise ProtocolError("unsupported pairing link")
    host, port = parse_authority(query.get("r", ""))
    return PairingInvite(
        kind=query["k"],
        host=host,
        port=port,
        pin=validate_pin(query.get("pin", "")),
        code=parse_code(query.get("c", "")),
    )
