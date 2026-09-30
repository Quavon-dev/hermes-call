import base64
import binascii
import json
import re
from typing import Any

from .errors import ProtocolError

MAX_MESSAGE_BYTES = 64 * 1024
_B64URL = re.compile(r"^[A-Za-z0-9_-]*\Z")


def b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64d(text: object, length: int | None = None, max_length: int = MAX_MESSAGE_BYTES) -> bytes:
    if not isinstance(text, str) or len(text) > max_length * 4 // 3 + 4 or not _B64URL.match(text):
        raise ProtocolError("invalid base64 field")
    try:
        data = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (binascii.Error, ValueError) as exc:
        raise ProtocolError("invalid base64 field") from exc
    if b64e(data) != text:
        raise ProtocolError("non-canonical base64 field")
    if length is not None and len(data) != length:
        raise ProtocolError("invalid field length")
    return data


def encode(message: dict[str, Any]) -> str:
    return json.dumps(message, separators=(",", ":"))


def decode(raw: str | bytes) -> dict[str, Any]:
    if len(raw) > MAX_MESSAGE_BYTES:
        raise ProtocolError("message too large")
    try:
        message = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError("invalid json") from exc
    if not isinstance(message, dict) or not isinstance(message.get("t"), str):
        raise ProtocolError("invalid message")
    return message
