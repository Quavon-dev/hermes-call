import time

import pytest

from hermescall_common import e2e, sodium, wire
from hermescall_common.errors import ProtocolError


def pair():
    a_pk, a_sk = sodium.box_keypair()
    b_pk, b_sk = sodium.box_keypair()
    saved: dict = {}
    alice = e2e.Channel("A" * 22, a_sk)
    bob = e2e.Channel("B" * 22, b_sk, on_seen_mail=lambda seen: saved.update(seen=seen))
    return alice, bob, a_pk, b_pk, b_sk, saved


def mid() -> str:
    return wire.b64e(sodium.random_bytes(16))


def test_mail_is_accepted_once_in_any_order_and_late() -> None:
    alice, bob, a_pk, b_pk, _, saved = pair()
    first = alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid())
    second = alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid())
    assert bob.open(alice.my_id, a_pk, second)["type"] == "chat"
    assert bob.open(alice.my_id, a_pk, first)["mid"]  # older mail after newer is fine
    with pytest.raises(ProtocolError):
        bob.open(alice.my_id, a_pk, first)
    assert len(saved["seen"]) == 2


def test_mail_replay_is_rejected_after_restart() -> None:
    alice, bob, a_pk, b_pk, b_sk, saved = pair()
    sealed = alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid())
    bob.open(alice.my_id, a_pk, sealed)
    restarted = e2e.Channel(bob.my_id, b_sk, seen_mail=saved["seen"])
    with pytest.raises(ProtocolError):
        restarted.open(alice.my_id, a_pk, sealed)


def test_mail_older_than_window_is_rejected(monkeypatch) -> None:
    alice, bob, a_pk, b_pk, _, _ = pair()
    real = time.time()
    monkeypatch.setattr(e2e.time, "time", lambda: real - 9 * 86_400)
    sealed = alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid())
    monkeypatch.setattr(e2e.time, "time", lambda: real)
    with pytest.raises(ProtocolError):
        bob.open(alice.my_id, a_pk, sealed)


def test_mail_and_live_domains_are_independent() -> None:
    alice, bob, a_pk, b_pk, _, _ = pair()
    live = alice.seal(bob.my_id, b_pk, {"type": "typing"})
    mail = alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid())
    bob.open(alice.my_id, a_pk, mail)
    bob.open(alice.my_id, a_pk, live)


def test_eviction_floor_blocks_replay_of_evicted(monkeypatch) -> None:
    monkeypatch.setattr(e2e, "MAX_SEEN_MAIL", 2)
    alice, bob, a_pk, b_pk, _, _ = pair()
    sealed = [alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid=mid()) for _ in range(3)]
    for item in sealed:
        bob.open(alice.my_id, a_pk, item)
    with pytest.raises(ProtocolError):
        bob.open(alice.my_id, a_pk, sealed[0])


def test_bad_mid_is_rejected() -> None:
    alice, bob, a_pk, b_pk, _, _ = pair()
    with pytest.raises(ProtocolError):
        alice.seal(bob.my_id, b_pk, {"type": "chat"}, mid="short")
