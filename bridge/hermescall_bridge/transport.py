"""Seal-and-send to a paired phone, shared by calls, chat, phone context and tasks.

- `live`: an E2E message to an online phone, best effort (dropped when the relay is down);
- `mail`: one attempt at the relay mailbox (for time-bound messages such as phone queries);
  chat messages that must arrive go through the persistent outbox (outbox.py) instead.
"""

import logging
from typing import Any

import aiohttp

from hermescall_common import sodium, wire
from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel
from hermescall_common.errors import ProtocolError

from .state import Device, State

log = logging.getLogger(__name__)

TRANSPORT_ERRORS = (ProtocolError, TimeoutError, ConnectionError, RuntimeError, aiohttp.ClientError)


def new_mid() -> str:
    return wire.b64e(sodium.random_bytes(16))


class Transport:
    def __init__(self, state: State, relay: RelaySession, channel: Channel) -> None:
        self.state = state
        self.relay = relay
        self.channel = channel

    def device(self, device_id: str) -> Device | None:
        return self.state.devices.get(device_id)

    def seal_mail(self, device: Device, body: dict[str, Any]) -> tuple[str, str]:
        """(mid, sealed) for the relay mailbox."""
        mid = new_mid()
        return mid, self.channel.seal(device.id, device.box_key, body, mid=mid)

    async def live(self, device: Device | str, body: dict[str, Any]) -> bool:
        target = self.device(device) if isinstance(device, str) else device
        if target is None:
            return False
        sealed = self.channel.seal(target.id, target.box_key, body)
        try:
            await self.relay.send({"t": "e2e", "to": target.id, "data": sealed})
        except TRANSPORT_ERRORS as exc:
            log.info("live message for %s not sent: %s", target.id[:6], exc.__class__.__name__)
            return False
        return True

    async def live_all(self, body: dict[str, Any]) -> None:
        for device in list(self.state.devices.values()):
            await self.live(device, body)

    async def mail(self, device: Device | str, body: dict[str, Any], alert: bool) -> bool:
        target = self.device(device) if isinstance(device, str) else device
        if target is None:
            return False
        mid, sealed = self.seal_mail(target, body)
        return await self.post_mail(target.id, mid, sealed, alert)

    async def post_mail(self, device_id: str, mid: str, sealed: str, alert: bool) -> bool:
        try:
            await self.relay.request({"t": "mail", "to": device_id, "id": mid, "data": sealed, "alert": alert})
        except TRANSPORT_ERRORS as exc:
            log.warning("mail for %s not stored: %s", device_id[:6], exc)
            return False
        return True
