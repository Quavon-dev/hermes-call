# SPDX-License-Identifier: MIT
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gateway_smoke  # noqa: E402


def test_health_accepts_text_and_json_ok() -> None:
    assert gateway_smoke.health_ok(200, b"ok\n")
    assert gateway_smoke.health_ok(200, b'{"status": "ok", "version": "0.7.0", "checks": {"state": "ok"}}')
    assert not gateway_smoke.health_ok(200, b'{"status": "unhealthy"}')
    assert not gateway_smoke.health_ok(503, b"ok")
    assert not gateway_smoke.health_ok(200, b"<html>")
    assert not gateway_smoke.health_ok(200, b"[1]")


def test_only_https_urls() -> None:
    assert gateway_smoke.check("http://hermes-push.example") == ["not an https URL: http://hermes-push.example"]
    assert gateway_smoke.main(["ftp://x"]) == 1
