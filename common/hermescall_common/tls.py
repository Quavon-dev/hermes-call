"""TLS to the relay: WebPKI for Let's Encrypt relays, SPKI pinning for
self-signed ones (pin known from a QR code, or observed on first contact and
then confirmed by the CPace handshake, which binds it into its AD)."""

import hashlib
import ssl

import aiohttp
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from .codes import format_authority
from .errors import ProtocolError, SelfSignedRelay
from .wire import b64e


def spki_pin(der_cert: bytes) -> str:
    public_key = x509.load_der_x509_certificate(der_cert).public_key()
    spki = public_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return b64e(hashlib.sha256(spki).digest())


def unverified_context() -> ssl.SSLContext:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def _peer_cert(ws: aiohttp.ClientWebSocketResponse) -> bytes:
    ssl_object = ws.get_extra_info("ssl_object")
    der = ssl_object.getpeercert(binary_form=True) if ssl_object else None
    if not der:
        raise ProtocolError("no TLS certificate")
    return der


def _observed_pin(ws: aiohttp.ClientWebSocketResponse) -> str:
    return spki_pin(_peer_cert(ws))


def cert_fingerprint(ws: aiohttp.ClientWebSocketResponse) -> bytes:
    """SHA-256 of the certificate on a connection whose key was already checked against the pin,
    for later HTTPS requests to the same relay (`aiohttp.Fingerprint`)."""
    return hashlib.sha256(_peer_cert(ws)).digest()


async def connect(
    session: aiohttp.ClientSession, host: str, port: int, pin: str, path: str, heartbeat: float | None = 25.0
) -> aiohttp.ClientWebSocketResponse:
    """Connect with WebPKI verification, or with an exact SPKI pin when `pin` is set."""
    url = f"wss://{format_authority(host, port)}{path}"
    ws = await session.ws_connect(url, ssl=unverified_context() if pin else True, heartbeat=heartbeat, max_msg_size=65536)
    if pin and _observed_pin(ws) != pin:
        await ws.close()
        raise ProtocolError("relay TLS key does not match the pinned key")
    return ws


async def connect_first_contact(
    session: aiohttp.ClientSession, host: str, port: int, pin: str, path: str, allow_self_signed: bool = False
) -> tuple[aiohttp.ClientWebSocketResponse, str]:
    """First contact during pairing. Returns the socket and the pin to bind into
    CPace: the given pin, "" for a WebPKI-valid relay, or, only when explicitly
    allowed, the observed pin of a self-signed relay (trust on first use). Never
    falls back silently: an attacker who breaks WebPKI would otherwise get a free
    guess at the code."""
    if pin:
        return await connect(session, host, port, pin, path, heartbeat=None), pin
    try:
        return await connect(session, host, port, "", path, heartbeat=None), ""
    except aiohttp.ClientConnectorCertificateError:
        url = f"wss://{format_authority(host, port)}{path}"
        ws = await session.ws_connect(url, ssl=unverified_context(), max_msg_size=65536)
        observed = _observed_pin(ws)
        if not allow_self_signed:
            await ws.close()
            raise SelfSignedRelay(observed) from None
        return ws, observed
