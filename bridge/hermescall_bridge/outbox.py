"""Persistent outbox for chat mail: a message the agent sent is kept (sealed) until the relay's
mailbox took it, retried with backoff and at once after every relay reconnect. A message that
still cannot be stored after `MAX_AGE` (or whose phone was unpaired) is reported as failed."""

import asyncio
import contextlib
import logging
import time
from collections.abc import Awaitable, Callable

from hermescall_common.errors import ProtocolError

from .chatstore import AsyncStore, Mail
from .transport import TRANSPORT_ERRORS, Transport

log = logging.getLogger(__name__)

# The phone accepts mail up to 8 days after sealing (e2e.MAIL_WINDOW_MS); stay well inside.
MAX_AGE = 7 * 86_400.0
BACKOFF = (1.0, 2.0, 5.0, 15.0, 30.0, 60.0, 300.0)
CLAIM = 60.0
# Relay answers that will never succeed for this message.
PERMANENT = ("unknown_device", "too_large", "invalid")

FailedHandler = Callable[[str, str, str], Awaitable[None]]  # (message_id, device_id, why)


def backoff(attempts: int) -> float:
    return BACKOFF[min(attempts, len(BACKOFF) - 1)]


class Outbox:
    def __init__(self, transport: Transport, store: AsyncStore, on_failed: FailedHandler | None = None) -> None:
        self._transport = transport
        self._store = store
        self._on_failed = on_failed
        self._wake = asyncio.Event()
        self._task: asyncio.Task | None = None
        self.sent = 0

    async def queue(self, device_id: str, message_id: str, body: dict, alert: bool) -> None:
        device = self._transport.device(device_id)
        if device is None:
            return
        mid, sealed = self._transport.seal_mail(device, body)
        expires = time.time() + MAX_AGE
        # Claimed for CLAIM seconds: the first attempt happens right here, the loop takes over on failure.
        row = await self._store.call(
            self._store.store.queue_mail, device_id, mid, message_id, sealed, alert, expires, time.time() + CLAIM
        )
        if self._transport.relay.connected.is_set():
            await self._deliver(Mail(row, device_id, mid, message_id, sealed, alert, 0, expires))
        else:
            await self._store.call(self._store.store.mail_later, row, time.time())
        self.kick()

    def kick(self) -> None:
        """Try now (new mail, or the relay just reconnected)."""
        self._wake.set()
        if self._task is None or self._task.done():
            self._task = asyncio.ensure_future(self._run())

    async def flush(self, timeout: float) -> int:
        """Shutdown: one last attempt for everything due; returns what is still queued."""
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._deliver_due(), timeout)
        return await self._store.call(self._store.store.outbox_depth)

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()

    async def _run(self) -> None:
        while True:
            self._wake.clear()
            try:
                await self._deliver_due()
            except Exception:
                log.exception("outbox delivery failed")
            next_try = await self._store.call(self._store.store.next_mail_time)
            if next_try is None:
                await self._wake.wait()
                continue
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._wake.wait(), max(0.05, next_try - time.time()))

    async def _deliver_due(self) -> None:
        while due := await self._store.call(self._store.store.due_mail, time.time()):
            for mail in due:
                await self._deliver(mail)
            if not self._transport.relay.connected.is_set():
                return

    async def _deliver(self, mail: Mail) -> None:
        store = self._store.store
        if time.time() > mail.expires or self._transport.device(mail.device_id) is None:
            await self._store.call(store.mail_done, mail.row)
            await self._failed(mail, "expired" if time.time() > mail.expires else "unpaired")
            return
        try:
            await self._transport.relay.request(
                {"t": "mail", "to": mail.device_id, "id": mail.mid, "data": mail.data, "alert": mail.alert}
            )
        except ProtocolError as exc:
            if any(code in str(exc) for code in PERMANENT):
                await self._store.call(store.mail_done, mail.row)
                await self._failed(mail, str(exc))
                return
            await self._later(mail, exc)
            return
        except TRANSPORT_ERRORS as exc:
            await self._later(mail, exc)
            return
        self.sent += 1
        await self._store.call(store.mail_done, mail.row)

    async def _later(self, mail: Mail, exc: Exception) -> None:
        delay = backoff(mail.attempts)
        log.info("chat mail for %s queued, retry in %.0f s (%s)", mail.device_id[:6], delay, exc.__class__.__name__)
        await self._store.call(self._store.store.mail_later, mail.row, time.time() + delay)

    async def _failed(self, mail: Mail, why: str) -> None:
        log.warning("chat mail %s for %s given up: %s", mail.message_id[:6], mail.device_id[:6], why)
        if self._on_failed is not None:
            await self._on_failed(mail.message_id, mail.device_id, why)
