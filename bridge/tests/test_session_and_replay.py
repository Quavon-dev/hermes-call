"""RelaySession reconnect/backoff and on_ready (K4), clock skew (C7), append-only replay marks (L2)."""

import asyncio
import json
import time

import pytest

from hermescall_bridge.seen import SeenLog
from hermescall_common import client as client_mod
from hermescall_common import sodium, wire
from hermescall_common.client import RelaySession, clock_offset_ms
from hermescall_common.e2e import Channel, ClockSkewError
from hermescall_common.errors import ProtocolError

from .test_bridge_flows import h  # noqa: F401 - fixture

# ---- RelaySession ----------------------------------------------------------------------


async def test_session_reconnects_after_the_relay_drops_it_and_calls_on_ready(h, monkeypatch) -> None:  # noqa: F811
    ready = asyncio.Queue()
    state = h.bridge.relay
    session = RelaySession(
        state.endpoint, "bridge", state.identity, state._sign_sk, lambda m: asyncio.sleep(0), lambda: ready.put(1)
    )
    h.bridge.relay.stop()
    task = asyncio.ensure_future(session.run())
    try:
        await asyncio.wait_for(ready.get(), 10)
        await session._ws.close()  # the relay (or network) drops us
        await asyncio.wait_for(ready.get(), 10)
        assert session.connected.is_set()
    finally:
        session.stop()
        task.cancel()


async def test_backoff_doubles_with_jitter_and_resets_after_success(monkeypatch) -> None:
    sleeps: list[float] = []
    attempts = {"n": 0}

    async def fail_then_stop(self, http_session) -> None:
        attempts["n"] += 1
        if attempts["n"] == 3:
            return  # a session that connected and ended normally resets the backoff
        if attempts["n"] >= 6:
            self._stopped = True
        raise OSError("connection refused")

    async def fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)

    monkeypatch.setattr(RelaySession, "_session_once", fail_then_stop)
    monkeypatch.setattr(client_mod.asyncio, "sleep", fake_sleep)
    monkeypatch.setattr(client_mod.random, "uniform", lambda low, high: high)
    session = RelaySession(client_mod.RelayEndpoint("127.0.0.1", 1, ""), "bridge", "id", bytes(64), None)
    await session.run()
    assert sleeps == [1.5, 3.0, 1.5, 3.0, 6.0]


async def test_pending_requests_fail_fast_when_the_connection_drops() -> None:
    session = RelaySession(client_mod.RelayEndpoint("127.0.0.1", 1, ""), "bridge", "id", bytes(64), None)
    future = asyncio.get_running_loop().create_future()
    session._pending[1] = future
    session._disconnect()
    with pytest.raises(ProtocolError):
        await future


# ---- C7: clock skew -------------------------------------------------------------------


def test_clock_offset_from_the_relay_challenge() -> None:
    assert clock_offset_ms({"t": "challenge", "time": 1_000_500}, 1_000_000) == 500
    assert clock_offset_ms({"t": "challenge"}, 1_000_000) is None
    assert clock_offset_ms({"t": "challenge", "time": True}, 1_000_000) is None


def test_skewed_live_message_names_the_clock_problem(monkeypatch) -> None:
    a_pk, a_sk = sodium.box_keypair()
    b_pk, b_sk = sodium.box_keypair()
    sender, receiver = Channel("phone", a_sk), Channel("bridge", b_sk)
    sealed = sender.seal("bridge", b_pk, {"type": "hangup"})
    real = time.time
    monkeypatch.setattr("hermescall_common.e2e.time.time", lambda: real() - 300)  # our clock is 5 min behind
    with pytest.raises(ClockSkewError, match="300 s ahead of this clock.*NTP") as raised:
        receiver.open("phone", a_pk, sealed)
    assert isinstance(raised.value, ProtocolError) and raised.value.skew_ms > 0


# ---- L2: replay marks --------------------------------------------------------------------


def mid() -> str:
    return wire.b64e(sodium.random_bytes(16))


def test_marks_are_appended_and_survive_a_crash(tmp_path) -> None:
    log = SeenLog(tmp_path)
    log.load()
    ids = [mid() for _ in range(3)]
    now = int(time.time() * 1000)
    for index, key in enumerate(ids):
        log.mark("mail", key, now + index)
    log.mark("peer", "phone", now)
    # no close(): the process died; the next start still knows every mark
    peers, mail = SeenLog(tmp_path).load()
    assert peers == {"phone": now} and set(ids) <= set(mail)


def test_compaction_writes_snapshots_and_drops_old_segments(tmp_path) -> None:
    log = SeenLog(tmp_path, compact_every=5)
    log.load()
    now = int(time.time() * 1000)
    keys = [mid() for _ in range(12)]
    for key in keys:
        log.mark("mail", key, now)
    segments = sorted(p.name for p in tmp_path.glob("e2e_seen.*.log"))
    assert len(segments) == 1, segments  # older segments were folded into the snapshot
    assert len(json.loads((tmp_path / "e2e_seen_mail.json").read_text())) == 10
    assert set(keys) <= set(SeenLog(tmp_path).load()[1])
    log.close()
    assert list(tmp_path.glob("e2e_seen.*.log")) == []
    assert set(keys) <= set(SeenLog(tmp_path).load()[1])


def test_old_mail_marks_are_pruned_but_the_floor_stays(tmp_path) -> None:
    log = SeenLog(tmp_path)
    log.load()
    log.mark("mail", "old", 1)
    log.mark("mail", "", 5)
    log.mark("mail", "bad key", 7)  # never written: keys cannot contain spaces
    log.close()
    _, mail = SeenLog(tmp_path).load()
    assert mail == {"": 5}


async def test_channel_replay_protection_survives_restart_with_the_log(tmp_path) -> None:
    a_pk, a_sk = sodium.box_keypair()
    b_pk, b_sk = sodium.box_keypair()
    sender = Channel("phone", a_sk)
    log = SeenLog(tmp_path)
    peers, mail = log.load()
    receiver = Channel("bridge", b_sk, peers, seen_mail=mail, on_mark=log.mark)
    live = sender.seal("bridge", b_pk, {"type": "hangup"})
    mailed = sender.seal("bridge", b_pk, {"type": "chat"}, mid=mid())
    receiver.open("phone", a_pk, live)
    receiver.open("phone", a_pk, mailed)
    peers, mail = SeenLog(tmp_path).load()  # restart without a clean shutdown
    restarted = Channel("bridge", b_sk, peers, seen_mail=mail)
    for replay in (live, mailed):
        with pytest.raises(ProtocolError):
            restarted.open("phone", a_pk, replay)
