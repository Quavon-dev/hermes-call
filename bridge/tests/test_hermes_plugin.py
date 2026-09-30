import asyncio
import importlib.util
import json
import sys
from pathlib import Path

import pytest

from .conftest import API_TOKEN, CALL_TOKEN
from .test_bridge_flows import connect, h, pair_device  # noqa: F401 - h is a fixture

PLUGIN_DIR = Path(__file__).resolve().parents[2] / "hermes-integration" / "hermes-call"


def load_plugin():
    spec = importlib.util.spec_from_file_location(
        "hermes_call_plugin", PLUGIN_DIR / "__init__.py", submodule_search_locations=[str(PLUGIN_DIR)]
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["hermes_call_plugin"] = module
    spec.loader.exec_module(module)
    return module


plugin = load_plugin()


class Ctx:
    def __init__(self) -> None:
        self.tools: dict[str, dict] = {}
        self.hooks: dict[str, list] = {}

    def register_tool(self, **kwargs) -> None:
        self.tools[kwargs["name"]] = kwargs

    def register_hook(self, name: str, callback) -> None:
        self.hooks.setdefault(name, []).append(callback)


def test_registers_call_owner_gated_on_token(monkeypatch) -> None:
    ctx = Ctx()
    plugin.register(ctx)
    tool = ctx.tools["call_owner"]
    assert tool["schema"]["name"] == "call_owner" and tool["requires_env"] == ["HERMES_CALL_TOKEN"]
    monkeypatch.delenv("HERMES_CALL_TOKEN", raising=False)
    assert tool["check_fn"]() is False
    monkeypatch.setenv("HERMES_CALL_TOKEN", "t")
    assert tool["check_fn"]() is True


@pytest.mark.parametrize(
    ("env", "params", "error"),
    [
        ({}, {"reason": "r", "first_message": "hi"}, "HERMES_CALL_TOKEN"),
        ({"HERMES_CALL_TOKEN": "t"}, {"reason": "r", "first_message": "  "}, "first_message is required"),
        ({"HERMES_CALL_TOKEN": "t"}, {"reason": 5, "first_message": "hi"}, "must be strings"),
        ({"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "http://evil.example:8765"}, {"first_message": "hi"}, "loopback"),
        ({"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "http://127.0.0.1:1"}, {"first_message": "hi"}, "cannot reach"),
        (
            {"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "http://127.0.0.1:8765@evil.example"},
            {"first_message": "hi"},
            "loopback",
        ),
        ({"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "http://u@127.0.0.1:8765"}, {"first_message": "hi"}, "loopback"),
        ({"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "https://127.0.0.1:8765"}, {"first_message": "hi"}, "loopback"),
        ({"HERMES_CALL_TOKEN": "t", "HERMES_CALL_URL": "http://127.0.0.1"}, {"first_message": "hi"}, "loopback"),
    ],
)
def test_rejects_bad_input_without_calling(monkeypatch, env, params, error) -> None:
    monkeypatch.delenv("HERMES_CALL_TOKEN", raising=False)
    monkeypatch.delenv("HERMES_CALL_URL", raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    result = json.loads(plugin.call_owner(params, task_id="x"))
    assert result["success"] is False and error in result["error"]


async def test_token_never_follows_redirects_or_proxies(monkeypatch) -> None:
    from aiohttp import web

    hits: list[str] = []

    async def redirect(request: web.Request) -> web.Response:
        hits.append(request.headers.get("Authorization", ""))
        raise web.HTTPTemporaryRedirect("http://127.0.0.1:9/steal")

    app = web.Application()
    app.router.add_post("/v1/calls", redirect)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    monkeypatch.setenv("HERMES_CALL_TOKEN", "secret")
    monkeypatch.setenv("HERMES_CALL_URL", f"http://127.0.0.1:{port}")
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:9")
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    try:
        result = json.loads(await asyncio.to_thread(plugin.call_owner, {"first_message": "hi"}))
    finally:
        await runner.cleanup()
    assert hits == ["Bearer secret"]
    assert result == {"success": False, "error": "the bridge answered HTTP 307"}


async def test_wrong_token_is_reported(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setenv("HERMES_CALL_TOKEN", "wrong")
    monkeypatch.setenv("HERMES_CALL_URL", f"http://127.0.0.1:{h.api_port}")
    result = json.loads(await asyncio.to_thread(plugin.call_owner, {"reason": "r", "first_message": "hi"}))
    assert result == {"success": False, "error": "the bridge rejected the token"}


async def test_ring_only_token_can_ring_but_nothing_else(h) -> None:  # noqa: F811
    from aiohttp import ClientSession

    base = f"http://127.0.0.1:{h.api_port}"
    async with ClientSession(headers={"Authorization": f"Bearer {CALL_TOKEN}"}) as session:
        for method, path in [
            ("GET", "/v1/status"),
            ("GET", "/v1/devices"),
            ("POST", "/v1/devices/pairing"),
            ("DELETE", "/v1/devices/x"),
        ]:
            async with session.request(method, base + path, json={}) as response:
                assert response.status == 403
        async with session.post(base + "/v1/calls", json={"first_message": "hi"}) as response:
            assert response.status == 200 and (await response.json())["status"] == "no_devices"
    async with ClientSession(headers={"Authorization": f"Bearer {API_TOKEN}"}) as session:
        async with session.get(base + "/v1/status") as response:
            assert response.status == 200


async def test_call_owner_rings_the_phone_and_reports_decline(h, monkeypatch) -> None:  # noqa: F811
    monkeypatch.setenv("HERMES_CALL_TOKEN", CALL_TOKEN)
    monkeypatch.setenv("HERMES_CALL_URL", f"http://127.0.0.1:{h.api_port}")
    device = await pair_device(h)
    task = await connect(device)
    try:
        call = asyncio.ensure_future(
            asyncio.to_thread(plugin.call_owner, {"reason": "backup failed", "first_message": "Hi, it's Hermes."})
        )
        invite = await asyncio.wait_for(device.inbox.get(), 10)
        assert invite["type"] == "invite" and invite["reason"] == "backup failed"
        await device.send({"type": "decline", "call_id": invite["call_id"]})
        assert json.loads(await asyncio.wait_for(call, 10)) == {"success": False, "status": "declined", "messaged": True}
    finally:
        device.session.stop()
        task.cancel()


def test_registers_phone_context_and_present_to_owner() -> None:
    ctx = Ctx()
    plugin.register(ctx)
    assert set(ctx.tools) >= {"call_owner", "phone_context", "present_to_owner"}
    phone, present = ctx.tools["phone_context"], ctx.tools["present_to_owner"]
    assert phone["toolset"] == present["toolset"] == "hermes_call"
    schema = phone["schema"]["parameters"]
    assert len(schema["properties"]["capability"]["enum"]) == 15 and schema["required"] == ["capability", "reason"]
    assert "geofence" in schema["properties"]["capability"]["enum"]
    options = schema["properties"]["params"]["properties"]
    assert options["action"]["enum"] == ["add", "remove", "list"] and options["trigger"]["enum"] == ["enter", "exit"]
    assert set(options["place"]["properties"]) == {"lat", "lon", "radius_m", "query"}
    description = phone["schema"]["description"]
    assert "No / Ask / Yes" in description and "never retry" in description and "vision_analyze" in description
    assert "never returned" in description and "local notification" in description
    assert set(ctx.hooks) == {"pre_tool_call", "post_tool_call"}
    assert present["schema"]["parameters"]["properties"]["items"]["maxItems"] == 10


@pytest.mark.parametrize(
    ("params", "error"),
    [
        ({"capability": "microphone", "reason": "r"}, "capability must be one of"),
        ({"capability": "location", "reason": " "}, "reason is required"),
        ({"capability": "location", "reason": "x" * 301}, "reason is required"),
        ({"capability": "location", "reason": "r", "params": "precise"}, "params must be an object"),
    ],
)
def test_phone_context_rejects_bad_input(monkeypatch, params, error) -> None:
    monkeypatch.setenv("HERMES_CALL_TOKEN", "t")
    monkeypatch.setenv("HERMES_CALL_URL", "http://127.0.0.1:1")
    result = json.loads(plugin.phone_context(params))
    assert result["success"] is False and error in result["error"]


async def _online(h, monkeypatch, answer):
    monkeypatch.setenv("HERMES_CALL_TOKEN", CALL_TOKEN)
    monkeypatch.setenv("HERMES_CALL_URL", f"http://127.0.0.1:{h.api_port}")
    device = await pair_device(h)
    device.answer_queries = answer
    return device, await connect(device)


async def test_phone_context_returns_data_and_notes(h, monkeypatch) -> None:  # noqa: F811
    answers = iter([{"status": "ok", "data": {"level": 0.8, "state": "charging", "low_power": False}}, {"status": "denied"}])

    async def answer(query: dict) -> dict:
        return next(answers)

    device, task = await _online(h, monkeypatch, answer)
    try:
        params = {"capability": "battery", "reason": "Check before the long call"}
        result = json.loads(await asyncio.to_thread(plugin.phone_context, params))
        assert result == {"success": True, "status": "ok", "data": {"level": 0.8, "state": "charging", "low_power": False}}
        result = json.loads(await asyncio.to_thread(plugin.phone_context, params))
        assert result["success"] is False and result["status"] == "denied" and "do not ask again" in result["note"]
        bad = {"capability": "calendar", "reason": "r", "params": {"days": 99}}
        result = json.loads(await asyncio.to_thread(plugin.phone_context, bad))
        assert result["success"] is False and result["error"].startswith("invalid request: params.days")
    finally:
        device.session.stop()
        task.cancel()


async def test_phone_context_saves_picked_photos_privately(h, monkeypatch, tmp_path) -> None:  # noqa: F811
    import os
    import stat

    monkeypatch.setattr(plugin.tempfile, "tempdir", str(tmp_path))
    photo = b"\xff\xd8 fake jpeg"
    device = None

    async def pick(query: dict) -> dict:
        blob_id, key = await device.upload(photo)
        ref = {"blob_id": blob_id, "key": key, "name": "../../IMG 1.jpg", "mime": "image/jpeg"}
        return {"status": "ok", "data": {"files": [ref]}}

    device, task = await _online(h, monkeypatch, pick)
    try:
        params = {"capability": "photos", "reason": "Show me the receipt", "params": {"max": 1}}
        result = json.loads(await asyncio.to_thread(plugin.phone_context, params))
    finally:
        device.session.stop()
        task.cancel()
    assert result["success"] is True and result["status"] == "ok" and "data" not in result
    (saved,) = result["files"]
    path = Path(saved["path"])
    assert saved["name"] == "....IMG 1.jpg" and saved["mime"] == "image/jpeg" and saved["size"] == len(photo)
    assert path.parent.parent == tmp_path and path.parent.name.startswith("hermes-call-")
    assert path.name == "1-IMG_1.jpg" and path.read_bytes() == photo  # noqa: ASYNC240
    assert stat.S_IMODE(os.stat(path.parent).st_mode) == 0o700 and stat.S_IMODE(os.stat(path).st_mode) == 0o600


async def test_present_to_owner_sends_cards(h, monkeypatch) -> None:  # noqa: F811
    async def no_images(url: str) -> bytes:
        raise OSError("offline")

    h.bridge.presenter.fetch = no_images
    device, task = await _online(h, monkeypatch, None)
    try:
        params = {
            "title": "Links",
            "kind": "links",
            "items": [{"title": "Docs", "url": "https://example.com/docs", "image_url": "https://example.com/i.png"}],
        }
        result = json.loads(await asyncio.to_thread(plugin.present_to_owner, params))
        assert result["success"] is True and result["images"] == 0 and result["message_id"]
        while (message := await asyncio.wait_for(device.inbox.get(), 10))["type"] != "chat":
            pass
        assert message["kind"] == "presentation" and message["presentation"]["items"][0]["url"] == "https://example.com/docs"
        bad = json.loads(
            await asyncio.to_thread(plugin.present_to_owner, {"title": "x", "items": [{"title": "a", "url": "http://x"}]})
        )
        assert bad["success"] is False and "https" in bad["error"]
    finally:
        device.session.stop()
        task.cancel()


def test_saving_files_cleans_up_on_failure_and_sweeps_old_dirs(monkeypatch, tmp_path) -> None:
    import os
    import time

    monkeypatch.setattr(plugin.tempfile, "tempdir", str(tmp_path))
    old, fresh, other = tmp_path / "hermes-call-old", tmp_path / "hermes-call-fresh", tmp_path / "keep-me"
    for directory in (old, fresh, other):
        directory.mkdir()
        (directory / "f").write_bytes(b"x")
    past = time.time() - 25 * 3600
    for directory in (old, other):
        os.utime(directory, (past, past))
    good = {"name": "a.jpg", "mime": "image/jpeg", "data": "eA"}
    with pytest.raises(ValueError):
        plugin._save_files([good, {"name": "b.jpg"}])
    assert sorted(p.name for p in tmp_path.iterdir()) == ["hermes-call-fresh", "keep-me"]
    (saved,) = plugin._save_files([good])
    assert Path(saved["path"]).read_bytes() == b"x"
