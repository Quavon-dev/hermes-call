"""Runs inside Hermes' own Python (argv: hermes_dir bridge_hermes_py port): Hermes' REAL API server
(/health, /v1/runs, its events, approval and stop routes) with a stubbed agent, driven by the bridge's
HermesClient. Prints one JSON line. Needs Hermes >= 0.21 (tools.approval_gateway_wait) and aiohttp;
HERMES_HOME must be a temp dir."""

import asyncio
import dataclasses
import importlib.util
import json
import secrets
import sys
import threading

hermes_dir, client_file, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, hermes_dir)

try:
    from tools.approval_gateway_wait import _await_gateway_decision
except ImportError:
    print(json.dumps({"skipped": "Hermes before 0.21"}))
    sys.exit(0)

from gateway.config import PlatformConfig  # noqa: E402
from gateway.platforms.api_server import APIServerAdapter  # noqa: E402
from tools.approval import _gateway_notify_cbs  # noqa: E402
from tools.approval_context import get_current_session_key  # noqa: E402

spec = importlib.util.spec_from_file_location("bridge_hermes", client_file)
bridge = importlib.util.module_from_spec(spec)
sys.modules["bridge_hermes"] = bridge
spec.loader.exec_module(bridge)

KEY = secrets.token_hex(24)
SEEN: dict = {}


class FakeAgent:
    """What the API server needs of an agent: a turn with a tool, a gated command and text."""

    session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
    provider, model = "fake", "fake"

    def __init__(self, **kwargs) -> None:
        self.kwargs = kwargs
        self.stopped = threading.Event()

    def interrupt(self, *args, **kwargs) -> None:
        self.stopped.set()

    def run_conversation(self, user_message, conversation_history=None, task_id=None, **kwargs) -> dict:
        SEEN.setdefault("turns", []).append(
            {
                "input": user_message,
                "instructions": self.kwargs.get("ephemeral_system_prompt"),
                "session": self.kwargs.get("session_id"),
            }
        )
        delta, progress = self.kwargs["stream_delta_callback"], self.kwargs["tool_progress_callback"]
        if user_message == "count slowly":
            delta("One. ")
            SEEN["stopped"] = self.stopped.wait(10)
            return {"final_response": "", "interrupted": True}
        progress("tool.started", "terminal", "rm -rf /tmp/x", {})
        key = get_current_session_key()
        data = {
            "command": "rm -rf /tmp/x",
            "description": "delete",
            "pattern_key": "rm",
            "pattern_keys": ["rm"],
            "smart_denied": True,
        }
        SEEN["decision"] = _await_gateway_decision(key, _gateway_notify_cbs[key], data)["choice"]
        progress("tool.completed", "terminal", None, {"duration": 0.1, "result": "ok"})
        delta("Done.")
        return {"final_response": "Done.", "completed": True}


def describe(event) -> object:
    return [type(event).__name__, dataclasses.asdict(event)] if dataclasses.is_dataclass(event) else event


async def main() -> None:
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"port": port, "host": "127.0.0.1", "key": KEY}))
    adapter._create_agent = lambda **kwargs: FakeAgent(**kwargs)
    assert await adapter.connect(), "the API server did not start"
    client = bridge.HermesClient(f"http://127.0.0.1:{port}", KEY, "hermes-call-phone-smoke")
    events = []
    try:
        async for event in client.turn("call note", "delete it"):
            events.append(describe(event))
            if isinstance(event, bridge.ApprovalRequest):
                events.append(["answered", await client.answer_approval(event, "once")])
        turn = client.turn("call note", "count slowly")
        events.append(describe(await anext(turn)))
        await turn.aclose()  # the owner cut the agent off
        for _ in range(100):
            if "stopped" in SEEN:
                break
            await asyncio.sleep(0.05)
    finally:
        await client.close()
        await adapter.disconnect()
    print(json.dumps({"runs": client._runs, "events": events, "seen": SEEN}))


asyncio.run(main())
