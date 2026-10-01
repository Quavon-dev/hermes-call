"""The outbox waits quietly while the relay is disconnected and delivers on the reconnect kick."""

import asyncio

from .test_chat_durable import MailRelay, service
from .test_regressions import until


class CountingRelay(MailRelay):
    def __init__(self) -> None:
        super().__init__()
        self.attempts = 0

    async def request(self, message: dict, timeout: float = 15.0) -> dict:
        self.attempts += 1
        return await super().request(message, timeout)


async def test_offline_outbox_does_not_spin_and_sends_after_reconnect(tmp_path) -> None:
    relay = CountingRelay()
    relay.connected.clear()
    chat, _, _ = service(tmp_path, relay)
    message_id = await chat.send_text("while offline")
    await asyncio.sleep(0.3)
    assert relay.attempts == 0 and await chat.queued(message_id)
    relay.connected.set()
    await chat.on_relay_ready()
    await until(lambda: len(relay.mailed) == 1, 5)
    assert relay.attempts == 1 and not await chat.queued(message_id)
    await chat.close()


class SlowRelay(MailRelay):
    async def request(self, message: dict, timeout: float = 15.0) -> dict:
        await asyncio.sleep(0.1)
        return await super().request(message, timeout)


async def test_shutdown_flush_does_not_send_what_the_outbox_loop_is_sending(tmp_path) -> None:
    relay = SlowRelay()
    relay.connected.clear()
    chat, _, _ = service(tmp_path, relay)
    await chat.send_text("queued while offline")
    relay.connected.set()
    await chat.on_relay_ready()  # the loop picks the message up
    await asyncio.sleep(0.02)  # its relay request is in flight
    left = await chat.outbox.flush(2.0)
    await asyncio.sleep(0.2)
    assert left == 0 and len(relay.mailed) == 1, relay.mailed
    await chat.close()
