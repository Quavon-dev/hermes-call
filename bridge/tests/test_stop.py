"""Emergency stop: an owner chat message `/stop` also interrupts the call's turn and ends the task on the phones."""

import pytest

from hermescall_bridge.calls import ActiveCall
from hermescall_bridge.chat import is_stop

from .test_bridge_flows import connect, h, pair_device  # noqa: F401 - h is a fixture
from .test_chat import hermes_api, next_of, online_device, poll, stop_devices  # noqa: F401 - fixtures
from .test_tasks import drain, progress, started


class FakeConversation:
    def __init__(self) -> None:
        self.interrupts = 0

    def interrupt(self) -> None:
        self.interrupts += 1


@pytest.mark.parametrize(
    ("text", "stop"),
    [
        ("/stop", True),
        ("  /STOP\n", True),
        ("/Stop", True),
        ("stop", False),
        ("/stop now", False),
        ("please /stop", False),
        ("", False),
    ],
)
def test_is_stop(text: str, stop: bool) -> None:
    assert is_stop(text) is stop


async def test_stop_goes_to_hermes_as_a_bare_command(h) -> None:  # noqa: F811
    device = await online_device(h)
    h.bridge.chat.note_call([("owner", "remind me about the dentist"), ("Hermes", "Will do.")])
    await device.send_chat(" /STOP ")
    cursor, events = await poll(h)
    # The gateway only recognises the command when it is the whole text: no call context in front.
    assert [e["text"] for e in events] == ["/stop"]
    await device.send_chat("hello")
    _, events = await poll(h, cursor)
    assert events[0]["text"].startswith("[Context: a phone call with your owner ended")  # kept for the next message


async def test_stop_ends_the_running_task_on_the_phones(h) -> None:  # noqa: F811
    device = await online_device(h)
    assert await progress(h, started("web_search", 0)) == 204
    assert (await next_of(device, "task"))["state"] == "running"
    await device.send_chat("/stop")
    ended = await next_of(device, "task")
    assert ended["turn_id"] == "turn-1" and ended["state"] == "done"
    # The stopped turn's late tool events do not light the ring again (only the end's mail copy arrives).
    assert await progress(h, started("terminal", 1)) == 204
    assert {m["state"] for m in await drain(device, 0.8) if m["type"] == "task"} <= {"done"}
    assert h.bridge.tasks._turn.state == "done"


async def test_stop_interrupts_the_turn_of_an_active_call(h) -> None:  # noqa: F811
    device = await online_device(h)
    call = ActiveCall("call-1", h.bridge.devices._state.devices[device.state["device_id"]], pc=None)
    call.conversation = FakeConversation()
    h.bridge.calls.active = call
    try:
        await device.send_chat("/stop")
        await poll(h)
        assert call.conversation.interrupts == 1
        await device.send_chat("not a stop")
        await poll(h, wait=1)
        assert call.conversation.interrupts == 1
    finally:
        h.bridge.calls.active = None


async def test_a_resent_stop_acts_once(h) -> None:  # noqa: F811
    device = await online_device(h)
    call = ActiveCall("call-1", h.bridge.devices._state.devices[device.state["device_id"]], pc=None)
    call.conversation = FakeConversation()
    h.bridge.calls.active = call
    try:
        message_id = await device.send_chat("/stop")
        await next_of(device, "chat_ack")
        await device.send({"type": "chat", "id": message_id, "text": "/stop"}, mail=True)
        assert (await next_of(device, "chat_ack"))["id"] == message_id
        assert call.conversation.interrupts == 1
    finally:
        h.bridge.calls.active = None
