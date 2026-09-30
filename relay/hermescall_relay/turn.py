import base64
import hashlib
import hmac
import time

from hermescall_common import sodium
from hermescall_common.wire import b64e


def credentials(secret: bytes, urls: tuple[str, ...], ttl: int, now: float | None = None) -> dict:
    """Ephemeral TURN REST API credentials (coturn `use-auth-secret`)."""
    username = f"{int(time.time() if now is None else now) + ttl}:{b64e(sodium.random_bytes(9))}"
    digest = hmac.new(secret, username.encode(), hashlib.sha1).digest()
    return {"urls": list(urls), "username": username, "credential": base64.b64encode(digest).decode(), "ttl": ttl}
