"""Runs inside Hermes' own Python (argv: hermes_dir plugin_dir): loads the plugin, registers the
`hermes_call` platform in the real registry and drives the real adapter against a running bridge
(HERMES_CALL_URL / HERMES_CALL_TOKEN). Prints one JSON line per step. HERMES_HOME must be a temp dir."""

import asyncio
import importlib.util
import json
import sys
from pathlib import Path

hermes_dir, plugin_dir = sys.argv[1], Path(sys.argv[2])
sys.path.insert(0, hermes_dir)

from gateway.config import PlatformConfig  # noqa: E402
from gateway.platform_registry import PlatformEntry, platform_registry  # noqa: E402

spec = importlib.util.spec_from_file_location(
    "hermes_call_plugin", plugin_dir / "__init__.py", submodule_search_locations=[str(plugin_dir)]
)
plugin = importlib.util.module_from_spec(spec)
sys.modules["hermes_call_plugin"] = plugin
spec.loader.exec_module(plugin)


class Ctx:
    tools: dict = {}
    hooks: dict = {}

    def register_tool(self, **kwargs) -> None:
        self.tools[kwargs["name"]] = kwargs

    def register_hook(self, name: str, callback) -> None:
        self.hooks.setdefault(name, []).append(callback)

    def register_platform(
        self, name, label, adapter_factory, check_fn, validate_config=None, required_env=None, install_hint="", **kwargs
    ) -> None:
        platform_registry.register(
            PlatformEntry(
                name=name,
                label=label,
                adapter_factory=adapter_factory,
                check_fn=check_fn,
                validate_config=validate_config,
                required_env=required_env or [],
                install_hint=install_hint,
                source="plugin",
                plugin_name="hermes-call",
                **kwargs,
            )
        )


def connect_kwargs() -> dict:
    """Every optional argument the real BasePlatformAdapter.connect declares (v0.21: is_reconnect), with its
    default, so the adapter is called the way the gateway calls it."""
    import inspect

    from gateway.platforms.base import BasePlatformAdapter

    params = inspect.signature(BasePlatformAdapter.connect).parameters.values()
    return {p.name: p.default for p in params if p.name != "self" and p.default is not inspect.Parameter.empty}


def emit(**fields) -> None:
    print(json.dumps(fields), flush=True)


def run_tool_hooks(message_id: str) -> None:
    """What Hermes does around a tool call in a hermes_call turn (session context set by the gateway)."""
    from gateway.session_context import clear_session_vars, set_session_vars

    tokens = set_session_vars(platform="hermes_call", chat_id="owner", message_id=message_id)
    try:
        for callback in Ctx.hooks["pre_tool_call"]:
            callback(tool_name="web_search", args={"query": "weather munich"}, task_id="", session_id="", tool_call_id="c1")
        for callback in Ctx.hooks["post_tool_call"]:
            callback(tool_name="web_search", args={}, result="{}", task_id="", session_id="", tool_call_id="c1", duration_ms=80)
    finally:
        clear_session_vars(tokens)
    # Outside a hermes_call turn the hooks do nothing.
    for callback in Ctx.hooks["pre_tool_call"]:
        callback(tool_name="terminal", args={"command": "ls"}, task_id="", session_id="", tool_call_id="c2")


async def main() -> None:
    plugin.register(Ctx())
    entry = platform_registry.get("hermes_call")
    emit(step="registered", check=entry.check_fn(), home=entry.env_enablement_fn(), hint=bool(entry.platform_hint))
    adapter = entry.adapter_factory(PlatformConfig(enabled=True))
    received = []

    async def capture(event) -> None:
        received.append(event)

    adapter.handle_message = capture
    assert await adapter.connect(**connect_kwargs())
    emit(step="connected")
    for _ in range(300):
        if received:
            break
        await asyncio.sleep(0.05)
    event = received[0]
    emit(
        step="message",
        text=event.text,
        type=event.message_type.value,
        media=[Path(p).exists() for p in event.media_urls],  # noqa: ASYNC240 - test helper
        types=event.media_types,
        user=event.source.user_id,
        chat=event.source.chat_id,
        platform=event.source.platform.value,
    )
    from gateway.platforms.base import ProcessingOutcome
    from gateway.stream_events import ToolCallChunk

    chrome = adapter.format_tool_event(ToolCallChunk("terminal", "ls", {"command": "ls"}, 0))
    await asyncio.to_thread(run_tool_hooks, event.source.message_id)
    await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
    await asyncio.to_thread(sys.modules["hermes_call_plugin.progress"].REPORTER.flush)
    emit(step="progress", chrome=chrome, turn=event.source.message_id, hooks=sorted(Ctx.hooks))
    await adapter.on_processing_start(event)
    # The final response (notify) answers the owner's message: its first chunk carries `answers`.
    result = await adapter.send("owner", "Reply with **markdown** " + "x" * 9000, metadata={"notify": True})
    emit(step="sent", success=result.success)
    photo = Path(sys.argv[3])
    result = await adapter.send_image_file("owner", str(photo), caption="chart")
    emit(step="file", success=result.success)
    standalone = await entry.standalone_sender_fn(PlatformConfig(enabled=True), "owner", "from cron")
    emit(step="standalone", success=standalone.get("success", False))
    resolved = []
    adapter_module = sys.modules["hermes_call_plugin.adapter"]
    adapter_module._resolve = lambda key, choice: resolved.append((key, choice))
    result = await adapter.send_exec_approval("owner", "rm -rf /tmp/x", "session-key-1", "delete files")
    emit(step="approval_sent", success=result.success)
    for _ in range(300):
        if resolved:
            break
        await asyncio.sleep(0.05)
    emit(step="approval_resolved", resolved=resolved)
    from tools.approval import resolve_gateway_approval

    emit(step="real_resolver", pending=resolve_gateway_approval("unknown-session", "deny"))
    await adapter.disconnect()
    emit(step="done")


asyncio.run(main())
