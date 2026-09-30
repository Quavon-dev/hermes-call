"""H5: SIGTERM hangs up the active call, gives queued chat mail a last try, persists replay marks."""

from hermescall_bridge.calls import ActiveCall
from hermescall_bridge.daemon import shutdown

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import next_of, online_device, stop_devices  # noqa: F401 - fixtures
from .test_regressions import FakePc


async def test_shutdown_hangs_up_flushes_and_leaves_the_relay(h) -> None:  # noqa: F811
    device = await online_device(h)
    device_id = device.state["device_id"]
    pc = FakePc()
    h.bridge.calls.active = ActiveCall("call-1", h.bridge.devices._state.devices[device_id], pc)
    await h.bridge.chat.send_text("see you")
    await shutdown(h.bridge)
    assert h.bridge.calls.active is None and pc.closed
    assert (await next_of(device, "chat"))["text"] == "see you"
    assert (await next_of(device, "hangup"))["call_id"] == "call-1"
    assert h.bridge.relay._stopped
    assert (h.bridge.devices._store.directory / "e2e_seen_mail.json").exists()
