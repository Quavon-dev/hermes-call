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


def peer_connection(turn: dict) -> RTCPeerConnection:
    udp = [url for url in turn["urls"] if "transport=udp" in url] or list(turn["urls"])
    server = RTCIceServer(urls=udp[:1], username=turn["username"], credential=turn["credential"])
    return RTCPeerConnection(RTCConfiguration(iceServers=[server]))
