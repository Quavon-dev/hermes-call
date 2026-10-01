"""Bridge side of the Hermes v0.21 fixes: a chat approval lives no longer than Hermes waits for it."""

import time

import pytest

from .test_bridge_flows import h  # noqa: F401 - h is a fixture
from .test_chat import hermes_api, online_device, stop_devices  # noqa: F401 - stop_devices is a fixture


@pytest.mark.parametrize(("ttl", "at_most"), [(30, 30), (100_000, 600)])
async def test_a_chat_approval_expires_with_hermes(h, ttl, at_most) -> None:  # noqa: F811
    device = await online_device(h)
    device.approve = None
    body = {"request_id": f"ttl-{ttl}", "command": "ls", "description": "", "choices": ["once", "deny"], "ttl": ttl}
    assert (await hermes_api(h, "POST", "/v1/chat/approvals", body)) == (200, {"status": "sent"})
    until, _ = h.bridge.chat._approvals[f"ttl-{ttl}"]
    assert at_most - 2 < until - time.monotonic() <= at_most


@pytest.mark.parametrize("ttl", [0, -5, "60", True])
async def test_an_invalid_approval_ttl_is_refused(h, ttl) -> None:  # noqa: F811
    await online_device(h)
    body = {"request_id": "bad-ttl", "command": "ls", "description": "", "ttl": ttl}
    status, _ = await hermes_api(h, "POST", "/v1/chat/approvals", body)
    assert status == 400
