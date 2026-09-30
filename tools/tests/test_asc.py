import base64
import json
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import asc  # noqa: E402


def ver(version: str, state: str) -> dict:
    return {"id": f"id-{version}", "attributes": {"versionString": version, "appVersionState": state}}


@pytest.mark.parametrize(
    ("versions", "floor", "expected"),
    [
        ([], "0.6.0", "0.6.0"),
        ([ver("0.6.0", "PREPARE_FOR_SUBMISSION")], "0.6.0", "0.6.0"),
        ([ver("0.6.0", "WAITING_FOR_REVIEW")], "0.6.0", "0.6.0"),  # train still open for TestFlight
        ([ver("0.6.0", "PENDING_DEVELOPER_RELEASE")], "0.6.0", "0.7.0"),  # approved: train closed
        ([ver("0.6.0", "READY_FOR_SALE"), ver("0.7.0", "READY_FOR_SALE")], "0.6.0", "0.8.0"),
        ([ver("0.6.0", "READY_FOR_SALE")], "1.0.0", "1.0.0"),  # floor raised by hand
    ],
)
def test_resolve_version(versions, floor, expected) -> None:
    assert asc.resolve_version(versions, floor) == expected


def test_release_notes(tmp_path: Path) -> None:
    (tmp_path / "0.7.0").mkdir()
    (tmp_path / "0.7.0" / "en-US.txt").write_text("Call back from Recents.\n")
    assert asc.release_notes(tmp_path, "0.7.0", "en-US") == "Call back from Recents."
    assert asc.release_notes(tmp_path, "0.7.0", "de-DE") == "Verbesserungen und Fehlerbehebungen."
    assert asc.release_notes(None, "0.8.0", "en-GB") == "Improvements and bug fixes."


def test_token_is_a_valid_es256_jwt() -> None:
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    token = asc.make_token("KEY1234567", "issuer-uuid", pem, now=1000)
    header, claims, sig = token.split(".")

    def dec(s: str) -> bytes:
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

    assert json.loads(dec(header)) == {"alg": "ES256", "kid": "KEY1234567", "typ": "JWT"}
    assert json.loads(dec(claims)) == {"iss": "issuer-uuid", "iat": 1000, "exp": 2200, "aud": "appstoreconnect-v1"}
    raw = dec(sig)
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key.public_key().verify(der, f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))


class FakeAsc(asc.Asc):
    """App Store Connect as a dict of canned answers; records every write."""

    def __init__(self, versions=(), internal_all=False, beta_error=None, external_state="READY_FOR_BETA_SUBMISSION"):
        self.app_id = "app-1"
        self.writes: list[tuple[str, str]] = []
        self._versions = list(versions)
        self.internal_all = internal_all
        self.beta_error = beta_error
        self.external_state = external_state

    def call(self, method, path, body=None):
        route = path.split("?")[0]
        if method != "GET":
            self.writes.append((method, route))
        if method == "GET":
            if route == "/v1/builds":
                return {"data": [{"id": "build-1", "attributes": {"version": "7", "processingState": "VALID"}}]}
            if route.endswith("/betaGroups"):
                return {
                    "data": [
                        {"id": "g-int", "attributes": {"name": "Internal", "hasAccessToAllBuilds": self.internal_all}},
                        {"id": "g-ext", "attributes": {"name": "Beta"}},
                    ]
                }
            if route.endswith("/buildBetaDetail"):
                state, self.external_state = self.external_state, "WAITING_FOR_BETA_REVIEW"
                return {"data": {"attributes": {"externalBuildState": state}}}
            if route.endswith("/appStoreVersions"):
                return {"data": self._versions}
            if route.endswith("/appStoreVersionLocalizations"):
                return {"data": [{"id": "loc-1", "attributes": {"locale": "en-US"}}]}
            return {"data": []}
        if route == "/v1/betaAppReviewSubmissions" and self.beta_error:
            raise asc.AscError(f"POST {route} -> 409: {self.beta_error}")
        if route == "/v1/appStoreVersions":
            return {"data": {"id": "ver-new", "attributes": {"versionString": "0.6.0"}}}
        if route == "/v1/reviewSubmissions":
            return {"data": {"id": "sub-1", "attributes": {}}}
        return {"data": {}}


def test_beta_add_submits_external_build(capsys) -> None:
    fake = FakeAsc()
    asc.beta_add(fake, "0.6.0", "7", "Internal", "Beta", "- Recents call-back", wait=0)
    assert fake.writes == [
        ("POST", "/v1/betaGroups/g-int/relationships/builds"),
        ("POST", "/v1/betaBuildLocalizations"),
        ("POST", "/v1/betaGroups/g-ext/relationships/builds"),
        ("POST", "/v1/betaAppReviewSubmissions"),
    ]
    assert "external state: WAITING_FOR_BETA_REVIEW" in capsys.readouterr().out


def test_beta_add_waits_behind_another_review(capsys) -> None:
    fake = FakeAsc(internal_all=True, beta_error="ANOTHER_BUILD_IN_REVIEW: one build per train")
    asc.beta_add(fake, "0.6.0", "7", "Internal", "Beta", "n", wait=0)
    assert ("POST", "/v1/betaGroups/g-int/relationships/builds") not in fake.writes
    out = capsys.readouterr().out
    assert "gets every build automatically" in out and "::notice::another 0.6.0 build" in out


def test_promote_first_release() -> None:
    fake = FakeAsc()
    asc.promote(fake, "0.6.0", "7", None, wait=0)
    assert fake.writes == [
        ("POST", "/v1/appStoreVersions"),
        ("PATCH", "/v1/appStoreVersions/ver-new/relationships/build"),
        ("PATCH", "/v1/appStoreVersions/ver-new"),
        ("POST", "/v1/reviewSubmissions"),
        ("POST", "/v1/reviewSubmissionItems"),
        ("PATCH", "/v1/reviewSubmissions/sub-1"),
    ]  # no "What's New" on a first release


def test_promote_skips_while_a_version_is_with_apple(capsys) -> None:
    fake = FakeAsc(versions=[ver("0.6.0", "WAITING_FOR_REVIEW")])
    asc.promote(fake, "0.6.0", "8", None, wait=0)
    assert fake.writes == []  # never withdraws a waiting submission
    assert "0.6.0 is WAITING_FOR_REVIEW" in capsys.readouterr().out


def test_promote_update_writes_whats_new(tmp_path: Path) -> None:
    (tmp_path / "0.7.0").mkdir()
    (tmp_path / "0.7.0" / "en-US.txt").write_text("New: call back from Recents.")
    fake = FakeAsc(versions=[ver("0.6.0", "READY_FOR_SALE"), ver("0.7.0", "PREPARE_FOR_SUBMISSION")])
    asc.promote(fake, "0.7.0", "7", tmp_path, wait=0)
    assert ("PATCH", "/v1/appStoreVersionLocalizations/loc-1") in fake.writes
    assert ("PATCH", "/v1/appStoreVersions/id-0.7.0/relationships/build") in fake.writes


def test_beta_add_without_external_group(capsys) -> None:
    fake = FakeAsc()
    asc.beta_add(fake, "0.6.0", "7", "Internal", "", "n", wait=0)
    assert ("POST", "/v1/betaAppReviewSubmissions") not in fake.writes
    assert "external beta: off" in capsys.readouterr().out
