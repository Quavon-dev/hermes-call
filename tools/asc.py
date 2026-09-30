"""App Store Connect automation for .github/workflows/ios-release.yml (same model as Quavon's jackpoll).

    python tools/asc.py next-version --floor 0.6.0
    python tools/asc.py next-build --version 0.6.0 --at-least 42
    python tools/asc.py beta-add --version 0.6.0 --build 7 --notes-file notes.txt
    python tools/asc.py promote --version 0.6.0 --build 7 --notes ios/appstore/notes

Credentials come from the environment, never from arguments: ASC_KEY_ID, ASC_ISSUER_ID and
ASC_KEY_PATH (the .p8 of an App Store Connect API key with the Admin role). The app is found by
HC_BUNDLE_ID (default de.quavon.hermescall).

- Versions: once Apple has approved a version, its train is closed, and the next build goes out as
  the next minor version (0.6.0 approved -> 0.7.0). Never below MARKETING_VERSION.
- Build numbers: highest number App Store Connect has for the train + 1, so manual and CI uploads
  share one sequence.
- beta-add: the internal group (unless it gets every build), then the external group plus Beta App
  Review. Apple reviews one build per train at a time; a later build waits in the group.
- promote: attaches the build to the open App Store version and submits it, released after
  approval. Only one version can be with Apple at a time: while one is in review or approved and
  not yet live, this skips and the next push after that goes out as the next version.
"""

import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

API = "https://api.appstoreconnect.apple.com"
POLL_SECONDS = 30
# The App Store version record can still be edited and submitted.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
# With Apple right now: nothing else can be submitted until this one is done.
IN_FLIGHT = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE",
    "PROCESSING_FOR_APP_STORE",
    "WAITING_FOR_EXPORT_COMPLIANCE",
}
# Past App Review: the train of these versions takes no more builds.
APPROVED = {
    "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE",
    "PROCESSING_FOR_APP_STORE",
    "READY_FOR_SALE",
    "READY_FOR_DISTRIBUTION",
    "ACCEPTED",
    "PREORDER_READY_FOR_SALE",
    "REPLACED_WITH_NEW_VERSION",
    "DEVELOPER_REMOVED_FROM_SALE",
    "REMOVED_FROM_SALE",
}
DEFAULT_NOTES = {"de": "Verbesserungen und Fehlerbehebungen.", "en": "Improvements and bug fixes."}


class AscError(RuntimeError):
    pass


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(key_id: str, issuer: str, key_pem: bytes, now: float | None = None) -> str:
    now = int(time.time() if now is None else now)
    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("ASC key must be an ES256 .p8 key")
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = _b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    # JWS wants the raw r||s pair, not the DER structure the library returns.
    r, s = decode_dss_signature(key.sign(f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def state_of(version: dict) -> str:
    attrs = version["attributes"]
    return attrs.get("appVersionState") or attrs.get("appStoreState") or ""


def parse_version(text: str) -> tuple[int, ...] | None:
    try:
        parts = tuple(int(p) for p in text.split("."))
    except ValueError:
        return None
    return parts + (0,) * (3 - len(parts)) if 1 <= len(parts) <= 3 else None


def resolve_version(versions: list[dict], floor: str) -> str:
    """MARKETING_VERSION, or the next minor after the highest approved version if that is higher."""
    approved = [p for v in versions if state_of(v) in APPROVED and (p := parse_version(v["attributes"]["versionString"]))]
    floor_parsed = parse_version(floor)
    if floor_parsed is None:
        raise ValueError(f"not a version: {floor}")
    if not approved or floor_parsed > max(approved):
        return floor
    major, minor, _ = max(approved)
    return f"{major}.{minor + 1}.0"


class Asc:
    def __init__(self, key_id: str, issuer: str, key_pem: bytes, bundle_id: str) -> None:
        self._auth = (key_id, issuer, key_pem)
        self._token = ""
        self._issued = 0.0
        apps = self.get("/v1/apps", **{"filter[bundleId]": bundle_id})
        if not apps:
            raise AscError(f"no app with bundle id {bundle_id} in App Store Connect")
        self.app_id = apps[0]["id"]

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        if time.time() - self._issued > 900:  # tokens live 20 minutes; a slow ingest lives longer
            self._token = make_token(*self._auth)
            self._issued = time.time()
        req = urllib.request.Request(  # noqa: S310 - fixed https host
            API + path, method=method, data=json.dumps(body).encode() if body is not None else None
        )
        req.add_header("Authorization", "Bearer " + self._token)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as res:  # noqa: S310
                raw = res.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")
            try:
                detail = "; ".join(f"{e.get('code')}: {e.get('detail')}" for e in json.loads(detail)["errors"])
            except (ValueError, KeyError, TypeError):
                pass
            raise AscError(f"{method} {path.split('?')[0]} -> {err.code}: {detail}") from None
        return json.loads(raw) if raw else {}

    def get(self, path: str, **params: str) -> list[dict]:
        query = urllib.parse.urlencode(params)
        return self.call("GET", f"{path}?{query}" if query else path).get("data", [])

    def versions(self) -> list[dict]:
        return self.get(f"/v1/apps/{self.app_id}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "50"})

    def builds(self, version: str) -> list[dict]:
        return self.get(
            "/v1/builds",
            **{"filter[app]": self.app_id, "filter[preReleaseVersion.version]": version, "limit": "200"},
        )

    def build(self, version: str, number: str, wait: int) -> dict:
        """Polls: the build exists for the API only minutes after the upload, then PROCESSING."""
        deadline = time.time() + wait
        while True:
            found = [b for b in self.builds(version) if b["attributes"].get("version") == number]
            if found:
                state = found[0]["attributes"].get("processingState")
                if state == "VALID":
                    return found[0]
                if state in ("FAILED", "INVALID"):
                    raise AscError(f"build {version} ({number}) is {state}")
                last = f"build {version} ({number}) is {state}"
            else:
                last = f"build {version} ({number}) has not appeared yet"
            if time.time() >= deadline:
                raise AscError(f"{last} after waiting {wait}s")
            print(f"... {last}, retrying", flush=True)
            time.sleep(POLL_SECONDS)

    def beta_group(self, name: str) -> dict:
        for group in self.get(f"/v1/apps/{self.app_id}/betaGroups", limit="200"):
            if group["attributes"]["name"] == name:
                return group
        raise AscError(f"no TestFlight group named {name!r}")


def _rel(kind: str, ident: str) -> dict:
    return {"data": {"type": kind, "id": ident}}


def beta_add(asc: Asc, version: str, number: str, internal: str, external: str, notes: str, wait: int) -> None:
    build = asc.build(version, number, wait)
    group = asc.beta_group(internal)
    if group["attributes"].get("hasAccessToAllBuilds"):
        print(f"{internal}: gets every build automatically")
    else:
        asc.call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]})
        print(f"build {version} ({number}) -> {internal}")

    locs = asc.get(f"/v1/builds/{build['id']}/betaBuildLocalizations")
    if locs:
        asc.call(
            "PATCH",
            f"/v1/betaBuildLocalizations/{locs[0]['id']}",
            {"data": {"type": "betaBuildLocalizations", "id": locs[0]["id"], "attributes": {"whatsNew": notes}}},
        )
    else:
        asc.call(
            "POST",
            "/v1/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "en-US", "whatsNew": notes},
                    "relationships": {"build": _rel("builds", build["id"])},
                }
            },
        )

    if not external:
        print("external beta: off (repository variable ASC_EXTERNAL_BETA)")
        return
    group = asc.beta_group(external)
    asc.call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]})
    print(f"build {version} ({number}) -> {external}")
    # Adding a build to an external group is not submitting it: without this call it sits at
    # READY_FOR_BETA_SUBMISSION and no external tester ever sees it.
    state = asc.call("GET", f"/v1/builds/{build['id']}/buildBetaDetail")["data"]["attributes"]["externalBuildState"]
    if state == "READY_FOR_BETA_SUBMISSION":
        try:
            asc.call(
                "POST",
                "/v1/betaAppReviewSubmissions",
                {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": _rel("builds", build["id"])}}},
            )
        except AscError as err:
            if "ANOTHER_BUILD_IN_REVIEW" not in str(err):
                raise
            print(f"::notice::another {version} build is still in Beta App Review; build {number} waits in {external}")
            return
        state = asc.call("GET", f"/v1/builds/{build['id']}/buildBetaDetail")["data"]["attributes"]["externalBuildState"]
    print(f"external state: {state}")


def release_notes(notes_dir: pathlib.Path | None, version: str, locale: str) -> str:
    """<notes_dir>/<version>/<locale>.txt, else a generic line (per version on purpose)."""
    if notes_dir:
        path = notes_dir / version / f"{locale}.txt"
        if path.exists() and path.read_text().strip():
            return path.read_text().strip()[:4000]
    print(f"::notice::no release notes for {version} {locale}, using the generic text")
    return DEFAULT_NOTES.get(locale.split("-")[0], DEFAULT_NOTES["en"])


def promote(asc: Asc, version: str, number: str, notes_dir: pathlib.Path | None, wait: int) -> None:
    versions = asc.versions()
    busy = next((v for v in versions if state_of(v) in IN_FLIGHT), None)
    if busy:
        print(f"::notice::{busy['attributes']['versionString']} is {state_of(busy)}; {version} goes to App Review after that one")
        return
    build = asc.build(version, number, wait)
    record = next((v for v in versions if state_of(v) in EDITABLE), None)
    if record is None:
        record = asc.call(
            "POST",
            "/v1/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {"platform": "IOS", "versionString": version},
                    "relationships": {"app": _rel("apps", asc.app_id)},
                }
            },
        )["data"]
    elif record["attributes"]["versionString"] != version:
        record = asc.call(
            "PATCH",
            f"/v1/appStoreVersions/{record['id']}",
            {"data": {"type": "appStoreVersions", "id": record["id"], "attributes": {"versionString": version}}},
        )["data"]
    asc.call("PATCH", f"/v1/appStoreVersions/{record['id']}/relationships/build", _rel("builds", build["id"]))
    asc.call(
        "PATCH",
        f"/v1/appStoreVersions/{record['id']}",
        {"data": {"type": "appStoreVersions", "id": record["id"], "attributes": {"releaseType": "AFTER_APPROVAL"}}},
    )

    # "What's New" is refused on a first release and required on every later one.
    if any(state_of(v) == "READY_FOR_SALE" for v in versions):
        for loc in asc.get(f"/v1/appStoreVersions/{record['id']}/appStoreVersionLocalizations"):
            locale = loc["attributes"]["locale"]
            asc.call(
                "PATCH",
                f"/v1/appStoreVersionLocalizations/{loc['id']}",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": loc["id"],
                        "attributes": {"whatsNew": release_notes(notes_dir, version, locale)},
                    }
                },
            )

    # Reuse a submission that was created but never sent; Apple allows only one.
    open_subs = [
        s
        for s in asc.get("/v1/reviewSubmissions", **{"filter[app]": asc.app_id, "filter[platform]": "IOS"})
        if s["attributes"].get("state") == "READY_FOR_REVIEW"
    ]
    submission = (
        open_subs[0]
        if open_subs
        else asc.call(
            "POST",
            "/v1/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": _rel("apps", asc.app_id)},
                }
            },
        )["data"]
    )
    if not asc.get(f"/v1/reviewSubmissions/{submission['id']}/items"):
        asc.call(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": _rel("reviewSubmissions", submission["id"]),
                        "appStoreVersion": _rel("appStoreVersions", record["id"]),
                    },
                }
            },
        )
    asc.call(
        "PATCH",
        f"/v1/reviewSubmissions/{submission['id']}",
        {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}},
    )
    print(f"submitted {version} ({number}) for App Review, released automatically after approval")


def from_env() -> Asc:
    try:
        key_id, issuer, path = (os.environ[n] for n in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"))
    except KeyError as exc:
        raise SystemExit(f"missing environment variable {exc.args[0]}") from exc
    return Asc(key_id, issuer, pathlib.Path(path).read_bytes(), os.environ.get("HC_BUNDLE_ID", "de.quavon.hermescall"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="asc")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("next-version", help="version the next build belongs to")
    p.add_argument("--floor", required=True)
    p = sub.add_parser("next-build", help="next build number in a version train")
    p.add_argument("--version", required=True)
    p.add_argument("--at-least", type=int, default=1)
    p = sub.add_parser("beta-add", help="internal group, external group and Beta App Review")
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--notes-file", type=pathlib.Path, required=True)
    p.add_argument("--internal", default="Internal")
    p.add_argument("--external", default="Beta")
    p.add_argument("--wait", type=int, default=2400)
    p = sub.add_parser("promote", help="submit a build for App Review")
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--notes", type=pathlib.Path)
    p.add_argument("--wait", type=int, default=2400)
    args = parser.parse_args(argv)

    asc = from_env()
    try:
        if args.command == "next-version":
            print(resolve_version(asc.versions(), args.floor))
        elif args.command == "next-build":
            numbers = [int(v) for b in asc.builds(args.version) if (v := b["attributes"].get("version", "")).isdigit()]
            print(max([args.at_least, *(n + 1 for n in numbers)]))
        elif args.command == "beta-add":
            notes = args.notes_file.read_text().strip()[:4000] or DEFAULT_NOTES["en"]
            beta_add(asc, args.version, args.build, args.internal, args.external, notes, args.wait)
        else:
            promote(asc, args.version, args.build, args.notes, args.wait)
    except AscError as err:
        print(f"::error::{err}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
