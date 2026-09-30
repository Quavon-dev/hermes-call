import aioice
import pytest
from aiortc import RTCIceServer, rtcicetransport

from hermescall_bridge import webrtc


def test_relay_policy_is_forced_and_stun_dropped() -> None:
    servers = [
        RTCIceServer(urls=["stun:stun.example.com"]),
        RTCIceServer(urls=["turn:relay.example.com:3478?transport=udp"], username="u", credential="p"),
    ]
    kwargs = rtcicetransport.connection_kwargs(servers)
    assert kwargs["transport_policy"] is aioice.TransportPolicy.RELAY
    assert "stun_server" not in kwargs
    assert kwargs["turn_server"] == ("relay.example.com", 3478)


def test_turn_server_is_mandatory() -> None:
    with pytest.raises(ValueError):
        rtcicetransport.connection_kwargs([RTCIceServer(urls=["stun:stun.example.com"])])
    with pytest.raises(ValueError):
        rtcicetransport.connection_kwargs([])


def test_patch_is_what_aiortc_calls() -> None:
    assert rtcicetransport.connection_kwargs is webrtc._relay_only


async def test_offer_contains_no_host_candidates() -> None:
    turn = {"urls": ["turn:127.0.0.1:9?transport=udp", "turn:127.0.0.1:9?transport=tcp"], "username": "u", "credential": "p"}
    pc = webrtc.peer_connection(turn)
    pc.addTransceiver("audio")
    try:
        await pc.setLocalDescription(await pc.createOffer())
        candidates = [line for line in pc.localDescription.sdp.splitlines() if "candidate:" in line]
        assert all(" typ relay" in line for line in candidates)
        assert not any(t in pc.localDescription.sdp for t in (" typ host", " typ srflx"))
    finally:
        await pc.close()
