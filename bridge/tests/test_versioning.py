# SPDX-License-Identifier: MIT
"""H11: protocol version and capabilities between phone and bridge (E2E `hello`), `unsupported`
answers for unknown E2E types, and the schema version of state.json."""

import asyncio
import json
import logging
import tomllib
from pathlib import Path

import pytest

from hermescall_bridge import state as state_mod
from hermescall_bridge.state import StateStore
from hermescall_bridge.version import PROTOCOL_VERSION, VERSION

from .test_bridge_flows import connect, h, pair_device  # noqa: F401 - h is a fixture
from .test_chat import next_of


@pytest.fixture
async def phone(h):  # noqa: F811
    device = await pair_device(h)
    task = await connect(device)
    yield device
    device.session.stop()
    task.cancel()


def test_version_matches_pyproject() -> None:
    project = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text())
    assert project["project"]["version"] == VERSION


async def test_hello_is_answered_with_version_and_caps(h, phone) -> None:  # noqa: F811
    await phone.send({"type": "hello", "v": 1, "app": "1.4 (77)", "caps": ["call_resume", "history", "BAD CAP", 5]})
    reply = await next_of(phone, "hello")
    assert reply["v"] == PROTOCOL_VERSION and reply["bridge"] == VERSION
    assert "unsupported" in reply["caps"]
    peers = h.bridge.calls.peers
    device_id = phone.state["device_id"]
    assert peers.supports(device_id, "call_resume") and peers.supports(device_id, "history")
    assert not peers.supports(device_id, "BAD CAP")
    assert peers.info(device_id).app == "1.4 (77)"


async def test_phone_without_hello_has_no_caps(h, phone) -> None:  # noqa: F811
    await phone.send({"type": "invite_query", "call_id": "A" * 22})
    await next_of(phone, "cancel")
    assert not h.bridge.calls.peers.supports(phone.state["device_id"], "call_resume")


async def test_unknown_type_is_answered_with_unsupported(h, phone) -> None:  # noqa: F811
    await phone.send({"type": "teleport", "where": "moon"})
    reply = await next_of(phone, "unsupported")
    assert reply["unknown"] == "teleport"


async def test_unsupported_is_never_answered_and_odd_names_are_not_echoed(h, phone) -> None:  # noqa: F811
    await phone.send({"type": "unsupported", "unknown": "hello"})
    await phone.send({"type": "Weird Type!"})
    await phone.send({"type": "hello", "v": 1, "caps": []})
    reply = await next_of(phone, "hello")
    assert reply["type"] == "hello"
    await asyncio.sleep(0.2)
    leftovers = []
    while not phone.inbox.empty():
        leftovers.append(phone.inbox.get_nowait())
    # "Weird Type!" gets an answer without the name (it is not a valid type name); `unsupported` gets none.
    assert [body.get("unknown") for body in leftovers if body["type"] == "unsupported"] in ([], [None])


def test_state_without_schema_is_migrated_and_saved_with_one(tmp_path) -> None:
    store = StateStore(tmp_path)
    state = store.load()
    raw = json.loads(store.path.read_text())
    assert raw["schema"] == state_mod.SCHEMA
    del raw["schema"]
    store.path.write_text(json.dumps(raw))
    loaded = StateStore(tmp_path).load()
    assert loaded.keys == state.keys
    assert json.loads(store.path.read_text())["schema"] == state_mod.SCHEMA


def test_migration_hooks_run_in_order(tmp_path, monkeypatch) -> None:
    store = StateStore(tmp_path)
    store.load()
    relay = {"host": "relay.example", "port": 443, "pin": "", "bridge_id": "b" * 22}

    def add_relay(raw: dict) -> dict:
        return {**raw, "relay": relay}

    monkeypatch.setattr(state_mod, "MIGRATIONS", (*state_mod.MIGRATIONS, add_relay))
    monkeypatch.setattr(state_mod, "SCHEMA", len(state_mod.MIGRATIONS))
    assert StateStore(tmp_path).load().relay == relay
    raw = json.loads(store.path.read_text())
    assert raw["schema"] == state_mod.SCHEMA and raw["relay"] == relay


def test_state_from_a_newer_bridge_still_loads(tmp_path, caplog) -> None:
    store = StateStore(tmp_path)
    state = store.load()
    raw = json.loads(store.path.read_text())
    store.path.write_text(json.dumps({**raw, "schema": state_mod.SCHEMA + 5}))
    with caplog.at_level(logging.WARNING):
        loaded = StateStore(tmp_path).load()
    assert loaded.keys == state.keys
    assert "newer" in caplog.text
