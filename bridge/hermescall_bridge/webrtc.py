"""aiortc peer connections restricted to TURN relay candidates.

aiortc has no iceTransportPolicy; aioice does. Forcing RELAY means the bridge
never advertises or uses a home address, and never contacts a default STUN
server: every media packet goes to the user's own TURN relay.
"""

import aioice
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, rtcicetransport

_connection_kwargs = rtcicetransport.connection_kwargs


def _relay_only(servers: list[RTCIceServer]) -> dict:
    kwargs = _connection_kwargs(servers)
    if not kwargs.get("turn_server"):
        raise ValueError("a TURN server is required")
    kwargs["transport_policy"] = aioice.TransportPolicy.RELAY
    kwargs.pop("stun_server", None)
    return kwargs


rtcicetransport.connection_kwargs = _relay_only


# Which TURN transport the bridge tries first. aiortc/aioice use exactly one TURN URL per call (the
# first one they support), so the bridge cannot fall back between them within a call; the phone
# (libwebrtc) uses all of them. `tcp`/`tls` help a bridge host that blocks outbound UDP.
PREFERENCES = {
    "auto": ("udp", "tcp", "tls"),
    "udp": ("udp", "tcp", "tls"),
    "tcp": ("tcp", "tls", "udp"),
    "tls": ("tls", "tcp", "udp"),
}


def url_transport(url: str) -> str:
    if url.startswith("turns:"):
        return "tls"
    return "tcp" if "transport=tcp" in url else "udp"


def order_turn_urls(urls: list[str], preference: str = "auto") -> list[str]:
    """All TURN URLs from the relay, the preferred transport first (stable within a transport)."""
    ranks = PREFERENCES.get(preference, PREFERENCES["auto"])
    turn = [url for url in urls if isinstance(url, str) and url.startswith(("turn:", "turns:"))]
    return sorted(turn, key=lambda url: ranks.index(url_transport(url)))


def peer_connection(turn: dict, preference: str = "auto") -> RTCPeerConnection:
    urls = order_turn_urls(list(turn["urls"]), preference)
    server = RTCIceServer(urls=urls, username=turn["username"], credential=turn["credential"])
    return RTCPeerConnection(RTCConfiguration(iceServers=[server]))
