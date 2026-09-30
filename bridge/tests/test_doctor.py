"""`hermes-call-bridge doctor` (I6)."""

import socket

from aiohttp import web

from hermescall_bridge.config import load
from hermescall_bridge.doctor import doctor
from hermescall_bridge.state import StateStore


def config_for(tmp_path, hermes_port: int, tts_port: int, api_port: int, relay_port: int):
    (tmp_path / "secrets").mkdir()
    for name in ("api_token", "call_token"):
        (tmp_path / "secrets" / name).write_text("x")
    model = tmp_path / "models" / "base.en"
    model.mkdir(parents=True)
    (model / "model.bin").write_bytes(b"")
    (tmp_path / "bridge.toml").write_text(
        f'state_dir = "{tmp_path / "state"}"\nsecrets_dir = "{tmp_path / "secrets"}"\n'
        f'[api]\nport = {api_port}\n[hermes]\nurl = "http://127.0.0.1:{hermes_port}"\n'
        f'[tts]\nurl = "http://127.0.0.1:{tts_port}"\n[stt]\nmodel_dir = "{tmp_path / "models"}"\n'
    )
    config = load(tmp_path / "bridge.toml")
    store = StateStore(config.state_dir)
    state = store.load()
    state.relay = {"host": "127.0.0.1", "port": relay_port, "pin": "", "bridge_id": "b"}
    store.save(state)
    return config


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_doctor_reports_each_check(tmp_path) -> None:
    import threading

    async def health(request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_get("/health", health)
    runner = web.AppRunner(app)
    ready = threading.Event()
    port = free_port()
    relay = socket.socket()
    relay.bind(("127.0.0.1", 0))
    relay.listen()

    def serve() -> None:
        import asyncio

        loop = asyncio.new_event_loop()
        loop.run_until_complete(runner.setup())
        loop.run_until_complete(web.TCPSite(runner, "127.0.0.1", port).start())
        ready.set()
        loop.run_forever()

    threading.Thread(target=serve, daemon=True).start()
    ready.wait(5)
    lines: list[str] = []
    try:
        config = config_for(tmp_path, port, free_port(), free_port(), relay.getsockname()[1])
        code = doctor(config, lines.append)
    finally:
        relay.close()
    report = {line.split()[1]: line.split()[0] for line in lines if len(line.split()) > 1}
    assert report["config"] == "ok" and report["relay"] == "ok" and report["hermes"] == "ok"
    assert report["secrets"] == "fail"  # hermes_api_key missing
    assert report["kokoro"] == "fail" and report["service"] == "warn"
    assert "speech" in " ".join(lines) and code == 1
