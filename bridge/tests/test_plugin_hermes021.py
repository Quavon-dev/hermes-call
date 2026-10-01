"""Hermes Agent v0.21 behaviour of the chat adapter: approvals are answered by Hermes request id
within Hermes' own approval timeout, slash-command confirmations use the phone's approval sheet,
cancelled turns, fatal auth errors and cron output. Hermes is stubbed (see test_plugin_compat.py)."""

import sys
import time
import types

import pytest

from .test_plugin_compat import FakeHttp, MessageEvent, Response, adapter_module, run_polls  # noqa: F401

pytestmark = pytest.mark.usefixtures("adapter_module")


@pytest.fixture
def hermes021(monkeypatch, adapter_module):  # noqa: F811
    """tools.approval with request ids and a pending queue, approval_context, slash_confirm."""
    queues: dict[str, list[dict]] = {}
    resolved: list[tuple] = []
    confirms: list[tuple] = []

    def resolve_gateway_approval(session_key, choice, resolve_all=False, reason=None, request_id=None):
        resolved.append((session_key, choice, request_id))
        return 1

    approval = sys.modules["tools.approval"]
    monkeypatch.setattr(approval, "resolve_gateway_approval", resolve_gateway_approval, raising=False)
    monkeypatch.setattr(approval, "list_gateway_approvals", lambda key: list(queues.get(key, [])), raising=False)
    context = types.ModuleType("tools.approval_context")
    context._get_approval_timeout = lambda: 120
    slash = types.ModuleType("tools.slash_confirm")

    async def resolve(session_key, confirm_id, choice):
        confirms.append((session_key, confirm_id, choice))
        return "MCP servers reloaded." if choice == "once" else "Reload cancelled."

    slash.resolve = resolve
    monkeypatch.setitem(sys.modules, "tools.approval_context", context)
    monkeypatch.setitem(sys.modules, "tools.slash_confirm", slash)
    return types.SimpleNamespace(module=adapter_module, queues=queues, resolved=resolved, confirms=confirms)


def approvals_posted(http: FakeHttp) -> list[dict]:
    return [body for path, body in http.posts if path == "/v1/chat/approvals"]


# ---- 1: the approval shown is the one answered, within Hermes' timeout -----------------------


async def test_an_answer_resolves_the_hermes_request_that_was_shown(hermes021) -> None:
    adapter = hermes021.module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    # Hermes enqueues each request before it notifies the platform: ours is the newest one we do not track.
    hermes021.queues["s"] = [{"request_id": "someone-elses"}, {"request_id": "r1"}]
    await adapter.send_exec_approval("owner", "rm a", "s")
    hermes021.queues["s"].append({"request_id": "r2"})
    await adapter.send_exec_approval("owner", "rm b", "s")
    first, second = list(adapter._approvals)
    await adapter._on_approval({"request_id": second, "choice": "once"})
    await adapter._on_approval({"request_id": first, "choice": "session"})
    assert hermes021.resolved == [("s", "once", "r2"), ("s", "session", "r1")]
    assert all(body["ttl"] == 115 for body in approvals_posted(http))  # Hermes' 120 s minus a margin


async def test_an_expired_approval_denies_only_its_own_request(hermes021) -> None:
    adapter = hermes021.module.HermesCallAdapter(None)
    adapter._http = FakeHttp([])
    hermes021.queues["s"] = [{"request_id": "mine"}]
    await adapter.send_exec_approval("owner", "rm a", "s")
    request_id = next(iter(adapter._approvals))
    pending = adapter._approvals[request_id]
    assert 100 < pending.until - time.monotonic() <= 115
    adapter._approvals[request_id] = pending._replace(until=time.monotonic() - 1)
    adapter._expire_approvals()
    assert hermes021.resolved == [("s", "deny", "mine")]


async def test_older_hermes_without_request_ids_still_resolves(adapter_module) -> None:  # noqa: F811
    adapter = adapter_module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    await adapter.send_exec_approval("owner", "ls", "s0")
    await adapter._on_approval({"request_id": next(iter(adapter._approvals)), "choice": "once"})
    assert adapter_module.resolved == [("s0", "once")]
    assert approvals_posted(http)[0]["ttl"] == 295  # Hermes' default 300 s minus the margin


# ---- 7: the approval POST does not outlast Hermes' 15 s wait --------------------------------


async def test_approval_is_posted_with_a_short_timeout(hermes021) -> None:
    adapter = hermes021.module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    await adapter.send_exec_approval("owner", "ls", "s")
    assert http.timeouts["/v1/chat/approvals"] is not None and http.timeouts["/v1/chat/approvals"] <= 10


# ---- 3: /reload-mcp, /new … confirmations on the phone sheet -------------------------------


async def test_slash_confirmations_use_the_phone_sheet(hermes021) -> None:
    adapter = hermes021.module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])
    prompt = "Reloading rebuilds the tool set.\n\n_Text fallback: reply `/approve`, `/always`, or `/cancel`._"
    result = await adapter.send_slash_confirm("owner", "/reload-mcp", prompt, "sess", "7")
    assert result.success
    body = approvals_posted(http)[-1]
    assert body["command"] == "/reload-mcp" and body["choices"] == ["once", "deny"]
    assert "/approve" not in body["description"] and "rebuilds the tool set" in body["description"]
    await adapter._on_approval({"request_id": body["request_id"], "choice": "once"})
    await adapter.send_slash_confirm("owner", "/new", "Start a new session?", "sess", "8")
    await adapter._on_approval({"request_id": approvals_posted(http)[-1]["request_id"], "choice": "deny"})
    assert hermes021.confirms == [("sess", "7", "once"), ("sess", "8", "cancel")]
    assert hermes021.resolved == []  # never a command approval
    sent = [body["text"] for path, body in http.posts if path == "/v1/chat/messages"]
    assert sent == ["MCP servers reloaded.", "Reload cancelled."]


async def test_an_undeliverable_slash_confirmation_is_cancelled_not_typed(hermes021) -> None:
    adapter = hermes021.module.HermesCallAdapter(None)
    adapter._http = http = FakeHttp([])

    async def refused(path, json, timeout=None):
        http.posts.append((path, json))
        return Response({"status": "denied"})

    http.post = refused
    result = await adapter.send_slash_confirm("owner", "/new", "Start a new session?", "sess", "9")
    assert result.success  # no typed /approve fallback on this platform
    assert hermes021.confirms == [("sess", "9", "cancel")]


# ---- 4: cron output is chunked by send() ------------------------------------------------------


def test_the_adapter_splits_long_messages(adapter_module) -> None:  # noqa: F811
    assert adapter_module.HermesCallAdapter.splits_long_messages is True
