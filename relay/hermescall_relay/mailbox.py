"""Ciphertext mailbox for chat messages to phones, with an alert push when a phone does not ack."""

import asyncio
import contextlib
import logging

from hermescall_common import wire
from hermescall_common.errors import ProtocolError

from .push import PushResult
from .store import PUSH_ENVS

log = logging.getLogger(__name__)

MAX_E2E_BLOB = 48 * 1024
MAIL_BATCH = 100


class MailboxMixin:
    """Part of `Relay` (server.py). Pending alert pushes finish on shutdown instead of being lost."""

    _alert_tasks: set[asyncio.Task]
    _stopping: asyncio.Event

    async def b_mail(self, bridge_id: str, message: dict) -> dict:
        device_id = self._valid_id(message.get("to"))
        mail_id = self._valid_id(message.get("id"))
        data = wire.b64e(wire.b64d(message.get("data"), max_length=MAX_E2E_BLOB))
        device = self.store.device(device_id)
        if device is None or device.bridge_id != bridge_id:
            return {"t": "error", "code": "unknown_device"}
        if not self._allow(self.mail_rate, bridge_id, "mail"):
            return {"t": "error", "code": "rate_limited"}
        stored = self.store.add_mail(mail_id, device_id, data)
        if stored == "full":
            self._count_limit("mailbox_full")
            return {"t": "error", "code": "mailbox_full"}
        if stored == "ok":
            ws = self.devices.get(device_id)
            online = ws is not None and await self._send(ws, {"t": "mail", "id": mail_id, "data": data})
            if message.get("alert") is True:
                grace = self.limits.mail_ack_grace if online else 0.0
                self._spawn_alert(self._alert_unless_acked(device_id, mail_id, data, grace))
        return {"t": "mailed", "id": mail_id}

    def _spawn_alert(self, coro) -> None:
        task = asyncio.ensure_future(coro)
        self._alert_tasks.add(task)
        task.add_done_callback(self._alert_tasks.discard)

    async def _alert_unless_acked(self, device_id: str, mail_id: str, data: str, grace: float) -> None:
        if grace and not self._stopping.is_set():
            # Shutdown cuts the wait short: the phone is being disconnected, so push now.
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._stopping.wait(), grace)
        device = self.store.device(device_id)
        if (
            self.push is None
            or device is None
            or not device.alert_token
            or device.alert_env not in PUSH_ENVS
            or not self.store.has_mail(device_id, mail_id)
            or not self._allow(self.alert_rate, device_id, "alerts")
        ):
            return
        result = await self.push.send_alert(device.alert_token, device.alert_env, data)
        if result is PushResult.INVALID_TOKEN:
            self.store.set_alert_token(device_id, None, None)

    async def _flush_alerts(self, timeout: float) -> None:
        self._stopping.set()
        pending = set(self._alert_tasks)
        if not pending:
            return
        log.info("sending %d pending chat alert(s) before exit", len(pending))
        _, late = await asyncio.wait(pending, timeout=timeout)
        for task in late:
            task.cancel()

    async def d_mail_fetch(self, device_id: str, message: dict) -> dict:
        ws = self.devices.get(device_id)
        batch = self.store.pending_mail(device_id, MAIL_BATCH + 1)
        for mail_id, data in batch[:MAIL_BATCH]:
            if ws is None or not await self._send(ws, {"t": "mail", "id": mail_id, "data": data}):
                break
        return {"t": "mail_done", "more": len(batch) > MAIL_BATCH}

    async def d_mail_ack(self, device_id: str, message: dict) -> dict:
        ids = message.get("ids")
        if not isinstance(ids, list) or not 0 < len(ids) <= MAIL_BATCH:
            raise ProtocolError("invalid ack")
        self.store.ack_mail(device_id, [self._valid_id(item) for item in ids])
        return {"t": "mail_acked"}
