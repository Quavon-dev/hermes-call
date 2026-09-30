"""Regression tests for issues found in code review of the durability work."""

import asyncio
import sqlite3
import time

from hermescall_bridge.seen import SeenLog
from hermescall_common import sodium, wire

from .test_chat_durable import service
from .test_devices_offline import registry
from .test_regressions import until


async def test_cursor_beyond_the_store_is_treated_as_stale(tmp_path) -> None:
    chat, _, _ = service(tmp_path)
    await chat._emit({"type": "message", "text": "new"})
    # an adapter without epoch support, holding a cursor from a lost store
    cursor, events = await chat.poll(99, 0)
    assert [e["text"] for e in events] == ["new"] and cursor == 1
    await chat.close()


async def test_owner_message_that_failed_processing_is_retried_on_the_next_reconnect(tmp_path, monkeypatch) -> None:
    chat, _, device = service(tmp_path)
    real = chat._db.store.hand_over
    calls = {"n": 0}

    def flaky(message_id: str, event: dict) -> int:
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(message_id, event)

    monkeypatch.setattr(chat._db.store, "hand_over", flaky)
    body = {"type": "chat", "mid": "x", "id": wire.b64e(b"q" * 16), "text": "retry me"}
    await chat.handle(device, body)
    assert (await chat.poll(0, 0))[1] == []  # acked and stored, but not with Hermes yet
    await chat.on_relay_ready()
    assert [e["text"] for e in (await chat.poll(0, 0))[1]] == ["retry me"]
    await chat.close()


async def test_chat_approval_requests_expire_with_the_approval(tmp_path) -> None:
    chat, relay, _ = service(tmp_path)
    relay.connected.clear()
    await chat.request_approval("req-1", "ls", "list")
    rows = chat._db.store.due_mail(time.time() + 10_000)
    assert len(rows) == 1 and rows[0].expires < time.time() + 700
    await chat.close()


async def test_concurrent_revocations_are_not_lost(tmp_path) -> None:
    from hermescall_bridge.state import new_device

    devices, relay, store, first = registry(tmp_path)
    second = new_device(wire.b64e(b"e" * 16), "phone 2", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    devices._state.devices[second.id] = second
    relay.connected.set()
    gate = asyncio.Event()
    real = relay.request

    async def slow(message: dict, timeout: float = 15.0) -> dict:
        await gate.wait()
        relay.error = "rate_limited"  # nothing is confirmed in this round
        return await real(message, timeout)

    relay.request = slow
    first_task = asyncio.ensure_future(devices.revoke(first))
    await asyncio.sleep(0.05)
    second_task = asyncio.ensure_future(devices.revoke(second.id))
    await asyncio.sleep(0.05)
    gate.set()
    await asyncio.gather(first_task, second_task)
    assert sorted(store.load_revocations()) == sorted([first, second.id])


def test_a_stale_compaction_never_overwrites_a_newer_snapshot(tmp_path) -> None:
    log = SeenLog(tmp_path)
    log.load()
    key = wire.b64e(sodium.random_bytes(16))
    log.mark("mail", key, int(time.time() * 1000))
    log.close()  # generation 1 written
    log._write_snapshot({"peer": {}, "mail": {}}, [], 0)  # an older, in-flight compaction lands late
    assert key in SeenLog(tmp_path).load()[1]


async def test_outbox_survives_a_failing_give_up_handler(tmp_path, monkeypatch) -> None:
    from hermescall_bridge import outbox as outbox_mod

    monkeypatch.setattr(outbox_mod, "MAX_AGE", -1.0)
    chat, relay, _ = service(tmp_path)

    async def broken(*args) -> None:
        raise ValueError("handler bug")

    chat.outbox._on_failed = broken
    await chat.send_text("expired at once")
    await asyncio.sleep(0.1)
    monkeypatch.setattr(outbox_mod, "MAX_AGE", 3600.0)
    await chat.send_text("still delivered")
    await until(lambda: len(relay.mailed) == 1, 5)
    await chat.close()
