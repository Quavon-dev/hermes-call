import pytest

from hermescall_common import pairing
from hermescall_common.errors import CryptoError

CTX = pairing.Context("device", "relay.example.com", 443, "")


def handshake(client_ctx: pairing.Context, server_ctx: pairing.Context, client_secret: str, server_secret: str):
    state, public = pairing.start(client_ctx, client_secret)
    response, server_keys = pairing.respond(server_ctx, server_secret, public)
    return pairing.finish(state, response), server_keys


def test_handshake_and_confirmation() -> None:
    client, server = handshake(CTX, CTX, "Q4M9P", "Q4M9P")
    sealed = pairing.seal_initiator(client, {"sign_pk": "x"})
    assert pairing.open_initiator(server, sealed) == {"sign_pk": "x"}
    reply = pairing.seal_responder(server, {"ok": True})
    assert pairing.open_responder(client, reply) == {"ok": True}


@pytest.mark.parametrize(
    "client_ctx,client_secret",
    [
        (CTX, "WRONG"),
        (pairing.Context("device", "relay.example.com", 443, "B" * 43), "Q4M9P"),
        (pairing.Context("device", "other.example.com", 443, ""), "Q4M9P"),
        (pairing.Context("relay", "relay.example.com", 443, ""), "Q4M9P"),
    ],
)
def test_mismatch_fails_confirmation(client_ctx: pairing.Context, client_secret: str) -> None:
    client, server = handshake(client_ctx, CTX, client_secret, "Q4M9P")
    with pytest.raises(CryptoError):
        pairing.open_initiator(server, pairing.seal_initiator(client, {}))


def test_directions_are_not_interchangeable() -> None:
    client, server = handshake(CTX, CTX, "Q4M9P", "Q4M9P")
    with pytest.raises(CryptoError):
        pairing.open_responder(server, pairing.seal_initiator(client, {}))
