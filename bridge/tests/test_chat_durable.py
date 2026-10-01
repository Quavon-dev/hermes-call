"""Durable chat queues (chatstore.py, outbox.py) and the adapter cursor epoch."""

import asyncio
import json
import sqlite3
import time

import pytest

from hermescall_bridge import outbox as outbox_mod
from hermescall_bridge.chat import ChatService
from hermescall_bridge.chatstore import ChatStore
from hermescall_bridge.state import State, new_device
from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_regressions import PlainChannel, restart, stop_restarted, until  # noqa: F401 - fixtures


class MailRelay:
    """Records mail; `down` makes every request fail like a lost relay connection."""

    def __init__(self) -> None:
        self.mailed: list[dict] = []
        self.live: list[dict] = []
        self.down = False
        self.error = "relay disconnected"
        self.connected = asyncio.Event()
        self.connected.set()

    async def request(self, message: dict, timeout: float = 15.0) -> dict:
        if self.down:
            raise ProtocolError(self.error)
        self.mailed.append(message)
        return {"t": "mailed"}

    async def send(self, message: dict) -> None:
        self.live.append(message)


class JsonChannel(PlainChannel):
    def seal(self, device_id: str, box_key: bytes, body: dict, mid: str | None = None) -> str:
        return json.dumps(body)


def service(tmp_path, relay=None) -> tuple[ChatService, MailRelay, object]:
    device = new_device(wire.b64e(b"d" * 16), "phone", wire.b64e(bytes(32)), wire.b64e(b"\x01" * 32))
    relay = relay or MailRelay()
    state = State(keys={}, devices={device.id: device})

    async def transcribe(audio) -> str:
        return ""

    chat = ChatService(state, relay, JsonChannel(), transcribe, store=ChatStore(tmp_path / "chat.db"))
    return chat, relay, device


def test_store_seq_survives_reopen_and_epoch_is_per_database(tmp_path) -> None:
    store = ChatStore(tmp_path / "chat.db")
    epoch = store.epoch
    assert [store.add_event({"n": i}) for i in range(3)] == [1, 2, 3]
    store.ack(3)
    store.close()
    again = ChatStore(tmp_path / "chat.db")
    assert again.epoch == epoch and again.add_event({"n": 4}) == 4 and again.last_seq() == 4
    assert ChatStore(tmp_path / "other.db").epoch != epoch


def test_store_accepts_a_message_id_once(tmp_path) -> None:
    store = ChatStore(tmp_path / "chat.db")
    assert store.accept("m1", "d1", {"text": "hi"}) is True
    assert store.accept("m1", "d1", {"text": "different text, same id"}) is False
    assert store.accept("m2", "d1", {"text": "hi"}) is True
    assert [p.message_id for p in store.pending()] == ["m1", "m2"]
    store.hand_over("m1", {"type": "message"})
    assert [p.message_id for p in store.pending()] == ["m2"] and store.event_depth() == 1


async def test_poll_with_a_foreign_epoch_acks_nothing_and_delivers_everything(tmp_path) -> None:
    chat, _, _ = service(tmp_path)
    await chat._emit({"type": "message", "text": "a"})
    await chat._emit({"type": "message", "text": "b"})
    # A cursor of 2 from another (lost) event store must not swallow these two events.
    cursor, events = await chat.poll(2, 0, epoch="old-epoch")
    assert [e["text"] for e in events] == ["a", "b"] and cursor == 2
    # The matching epoch keeps the cursor: acked events are not delivered again.
    assert await chat.poll(cursor, 0, epoch=chat.epoch) == (2, [])
    await chat.close()


async def test_chat_api_reports_epoch_and_queued(h) -> None:  # noqa: F811
    status, result = await hermes_api(h, "GET", "/v1/chat/events?cursor=0&wait=0")
    assert status == 200 and result["epoch"] == h.bridge.chat.epoch
    await online_device(h)
    status, result = await hermes_api(h, "POST", "/v1/chat/messages", {"text": "hello"})
    assert status == 200 and result["queued"] is False


async def test_store_failure_means_no_delivered_ack(tmp_path, monkeypatch) -> None:
    chat, relay, device = service(tmp_path)

    def broken(*args):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(chat._db.store, "accept", broken)
    await chat.handle(device, {"type": "chat", "mid": "x", "id": wire.b64e(b"i" * 16), "text": "hi"})
    assert relay.live == []
    await chat.close()


async def test_outbox_retries_with_backoff_and_survives_a_restart(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(outbox_mod, "BACKOFF", (0.05,))
    relay = MailRelay()
    relay.down = True
    chat, _, _ = service(tmp_path, relay)
    message_id = await chat.send_text("later")
    await asyncio.sleep(0.2)
    assert relay.mailed == [] and await chat.queued(message_id)
    await chat.close()
    # restart: a new service on the same database delivers it once the relay is back
    relay.down = False
    chat2, _, _ = service(tmp_path, relay)
    await chat2.on_relay_ready()
    await until(lambda: len(relay.mailed) == 1, 5)
    assert relay.mailed[0]["t"] == "mail" and not await chat2.queued(message_id)
    await chat2.close()


async def test_outbox_gives_up_on_permanent_errors_and_tells_the_adapter(tmp_path) -> None:
    relay = MailRelay()
    relay.down, relay.error = True, "relay error: unknown_device"
    chat, _, device = service(tmp_path, relay)
    message_id = await chat.send_text("to a phone the relay forgot")
    await until(lambda: chat._db.store.event_depth() == 1, 5)
    _, events = await chat.poll(0, 0)
    assert events == [{**events[0], "type": "delivery_failed", "message_id": message_id, "device_id": device.id}]
    await chat.close()


async def test_outbox_drops_expired_mail(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(outbox_mod, "MAX_AGE", -1.0)
    chat, relay, _ = service(tmp_path)
    await chat.send_text("too late")
    await until(lambda: chat._db.store.event_depth() == 1, 5)
    assert relay.mailed == []
    await chat.close()


@pytest.mark.parametrize("key", ["recent", "call_context"])
async def test_call_and_chat_context_survive_a_restart(tmp_path, key) -> None:
    chat, _, _ = service(tmp_path)
    chat.note_call([("owner", "remind me about the dentist"), ("Hermes", "Will do.")])
    await chat._db.call(time.sleep, 0)  # everything submitted before is written
    await chat.close()
    chat2, _, _ = service(tmp_path)
    assert "dentist" in (chat2.recent_context() if key == "recent" else chat2._call_context)
    await chat2.close()


class SlowLiveRelay(MailRelay):
    """The `delivered` ack takes a moment, so a reconnect can run while it is in flight."""

    async def send(self, message: dict) -> None:
        await asyncio.sleep(0.05)
        self.live.append(message)


async def test_a_reconnect_during_the_delivered_ack_hands_the_message_over_once(tmp_path) -> None:
    chat, relay, device = service(tmp_path, SlowLiveRelay())
    body = {"type": "chat", "id": wire.b64e(b"m" * 16), "mid": wire.b64e(b"x" * 16), "text": "hello"}
    on_chat = asyncio.ensure_future(chat.handle(device, body))
    await asyncio.sleep(0.01)  # stored, ack in flight
    await chat.on_relay_ready()
    await on_chat
    _, events = await chat.poll(0, 0)
    assert sum(e["type"] == "message" for e in events) == 1
    await chat.close()


def test_hand_over_claims_the_inbox_row_once(tmp_path) -> None:
    store = ChatStore(tmp_path / "chat.db")
    message_id = wire.b64e(b"m" * 16)
    assert store.accept(message_id, "dev", {"id": message_id, "text": "hi"})
    assert store.hand_over(message_id, {"type": "message", "id": message_id}) is not None
    assert store.hand_over(message_id, {"type": "message", "id": message_id}) is None
    assert len(store.events_after(0)) == 1
    store.close()


async def test_a_poll_while_an_agent_file_is_recorded_keeps_the_file(tmp_path, monkeypatch) -> None:
    chat, relay, device = service(tmp_path)
    record = chat.history.record

    async def poll_first(*args, **kwargs) -> None:
        await chat.files.collect()  # the adapter's long-poll comes in between
        await record(*args, **kwargs)

    monkeypatch.setattr(chat.history, "record", poll_first)
    monkeypatch.setattr(chat, "_upload", lambda device, file: asyncio.sleep(0, {"blob_id": "b"}))
    await chat.send_file(b"report", "q3.pdf", "application/pdf", "file")
    (name,) = [p.name for p in chat.files.directory.iterdir()]
    assert (await chat.files.get(name)) is not None
    assert await chat.files.read(await chat.files.get(name)) == b"report"
    await chat.close()


class RecordingDir:
    """The spool directory, noting on which thread (and how often) it is scanned."""

    def __init__(self, real) -> None:
        self.real = real
        self.scans: list[str] = []

    def iterdir(self):
        import threading

        self.scans.append(threading.current_thread().name)
        return self.real.iterdir()

    def __truediv__(self, name: str):
        return self.real / name


async def test_collecting_spooled_files_scans_the_disk_off_the_event_loop_and_not_every_time(tmp_path) -> None:
    import threading

    chat, _, _ = service(tmp_path)
    directory = RecordingDir(chat.files.directory)
    chat.files.directory = directory
    await chat.send_text("one")
    await chat.send_text("two")
    await chat.files.collect()
    assert directory.scans, "stray files are still looked for"
    assert threading.main_thread().name not in directory.scans
    assert len(directory.scans) == 1, "at most one directory scan per interval"
    await chat.close()
