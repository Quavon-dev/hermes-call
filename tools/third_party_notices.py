"""Regenerates the Python part of THIRD_PARTY_NOTICES.md.

    uv run python tools/third_party_notices.py

Reads the installed distribution metadata (importlib.metadata) of every package pinned in
bridge/requirements.lock plus the relay's and test client's runtime dependencies, and adds the
models, vendored code and distribution packages that are not Python distributions. Everything
from the "## iOS app" heading onwards is kept as it is.
"""

import importlib.metadata as metadata
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
BRIDGE_LOCK = ROOT / "bridge" / "requirements.lock"
IOS_HEADING = "## iOS app"

# On the relay host these come from Debian/Ubuntu packages (python3-aiohttp, python3-httpx, ...).
RELAY_RUNTIME = ["aiohttp", "httpx", "h2", "hpack", "hyperframe", "cryptography"]
TESTCLIENT_RUNTIME = ["sounddevice", "cffi", "pycparser"]

MODELS = [
    (
        "faster-whisper base.en / small.en (CTranslate2 conversions of OpenAI Whisper)",
        "MIT",
        "https://huggingface.co/Systran/faster-whisper-base.en",
        "Downloaded once by bridge/install.sh from Systran/faster-whisper-<model> at a pinned "
        "revision (base.en 3d3d5dee26484f91867d81cb899cfcf72b96be6c, small.en "
        "d1d751a5f8271d482d14ca55d9e2deeebbae577f), checked against a pinned SHA-256.",
    ),
    (
        "Silero VAD (silero_vad_v6.onnx)",
        "MIT",
        "https://github.com/snakers4/silero-vad",
        "Shipped inside the faster-whisper wheel; used for voice activity detection.",
    ),
    (
        "Kokoro-82M (text-to-speech weights)",
        "Apache-2.0",
        "https://huggingface.co/hexgrad/Kokoro-82M",
        "Not downloaded or distributed by Hermes Call: the bridge talks to a Kokoro-FastAPI "
        "server you run yourself (ghcr.io/remsky/kokoro-fastapi-cpu, 127.0.0.1:8880).",
    ),
    (
        "German Kokoro voices: Thorsten-Voice/Kokoro, kikiri-tts/kikiri-german-martin and kikiri-german-victoria",
        "Apache-2.0 (Thorsten-Voice dataset: CC0-1.0)",
        "https://huggingface.co/Thorsten-Voice/Kokoro",
        "Downloaded by tts/install.sh at pinned revisions (734e593d320a3d876bede7020f773dfd481a0cc7, "
        "1e9dcd16ed48fda0a7a1f62e5e37130a5fdf10d9, ce81e200ff9203e1a3b042cd678c48e3ffb85cef), each file "
        "checked against a pinned SHA-256; not distributed with Hermes Call.",
    ),
    (
        "kokoro and misaki German forks (semidark/kokoro, semidark/misaki)",
        "Apache-2.0",
        "https://github.com/semidark/kokoro",
        "Checked out by tts/install.sh at pinned commits (kokoro b96fef95e6a746495f92443fac7c688f90fc57fc, "
        "misaki 6d252a2e02f3b030f22f56686f1a73786c16ffc8); they use the distribution's espeak-ng (GPL-3.0).",
    ),
    (
        "Kokoro-FastAPI (container image ghcr.io/remsky/kokoro-fastapi-cpu)",
        "Apache-2.0",
        "https://github.com/remsky/Kokoro-FastAPI",
        "Run by the operator, not distributed with Hermes Call. The image bundles further "
        "components under their own licenses (for example espeak-ng, GPL-3.0).",
    ),
]

VENDORED = [
    (
        "CPace (third_party/cpace)",
        "BSD-2-Clause, Copyright (c) 2020-2021 Frank Denis",
        "https://github.com/jedisct1/cpace",
        "Vendored at 41701e79157d6d4d5792eac5713cc4008447e5a0 as the reference implementation for "
        "the interoperability tests; full license text in third_party/cpace/LICENSE.",
    ),
]

DISTRO_PACKAGES = [
    ("libsodium (libsodium23)", "ISC", "https://libsodium.org", "relay and bridge (loaded via ctypes)"),
    ("Caddy", "Apache-2.0", "https://caddyserver.com", "relay: TLS termination"),
    ("coturn", "BSD-3-Clause", "https://github.com/coturn/coturn", "relay: TURN server"),
    ("qrencode", "LGPL-2.1-or-later", "https://fukuchi.org/works/qrencode/", "relay and bridge: QR codes in the terminal"),
    ("OpenSSL", "Apache-2.0", "https://www.openssl.org", "relay: certificate generation"),
    ("nftables", "GPL-2.0-only", "https://netfilter.org/projects/nftables/", "relay: firewall"),
    ("unattended-upgrades", "GPL-2.0-or-later", "https://github.com/mvo5/unattended-upgrades", "relay: security updates"),
    ("fail2ban (only when sshd is present)", "GPL-2.0-or-later", "https://github.com/fail2ban/fail2ban", "relay: SSH hardening"),
]

_LOCK_LINE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==")
_CLASSIFIER_LICENSES = {
    "MIT License": "MIT",
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
}
_URL_LABELS = ("homepage", "home", "source", "source code", "repository", "github: repo", "code")


def locked_names(lock: Path) -> list[str]:
    return [match.group(1) for line in lock.read_text().splitlines() if (match := _LOCK_LINE.match(line))]


def license_of(meta: metadata.PackageMetadata) -> str:
    if expression := meta.get("License-Expression"):
        return expression
    text = (meta.get("License") or "").strip()
    if text and "\n" not in text and len(text) <= 60:
        return text
    for classifier in meta.get_all("Classifier") or []:
        if classifier.startswith("License :: OSI Approved :: "):
            name = classifier.removeprefix("License :: OSI Approved :: ")
            return _CLASSIFIER_LICENSES.get(name, name)
    return "see the distribution's license file"


def homepage_of(meta: metadata.PackageMetadata) -> str:
    if page := meta.get("Home-page"):
        return page
    urls = {}
    for entry in meta.get_all("Project-URL") or []:
        label, _, url = entry.partition(",")
        urls[label.strip().lower()] = url.strip()
    return next((urls[label] for label in _URL_LABELS if label in urls), next(iter(urls.values()), ""))


def package_rows(names: list[str]) -> list[str]:
    rows = []
    for name in sorted(set(names), key=str.lower):
        try:
            dist = metadata.distribution(name)
        except metadata.PackageNotFoundError:
            rows.append(f"| {name} | (platform-specific, not installed here) | | |")
            continue
        rows.append(f"| {dist.metadata['Name']} | {dist.version} | {license_of(dist.metadata)} | {homepage_of(dist.metadata)} |")
    return rows


def python_section() -> list[str]:
    table = ["| Package | Version | License | Homepage |", "|---|---|---|---|"]
    return [
        "# Third-party notices",
        "",
        "Hermes Call is MIT-licensed (Copyright (c) Quavon UG (haftungsbeschränkt)). It uses the",
        "components below under their own licenses. The Python part is generated by",
        "`uv run python tools/third_party_notices.py`; do not edit it by hand.",
        "",
        "## Python (bridge, relay, test client)",
        "",
        "### Bridge (pinned in `bridge/requirements.lock`, installed with `--require-hashes`)",
        "",
        *table,
        *package_rows(locked_names(BRIDGE_LOCK)),
        "",
        "### Relay",
        "",
        "Installed from Debian/Ubuntu packages on the relay host; the versions shown are the",
        "development environment's.",
        "",
        *table,
        *package_rows(RELAY_RUNTIME),
        "",
        "### Test client (development only)",
        "",
        *table,
        *package_rows(TESTCLIENT_RUNTIME),
        "",
        "### Models",
        "",
        *entries(MODELS),
        "### Vendored code",
        "",
        *entries(VENDORED),
        "### Distribution packages installed by `relay/install.sh` and `bridge/install.sh`",
        "",
        "| Package | License | Homepage | Used for |",
        "|---|---|---|---|",
        *(f"| {name} | {license_} | {url} | {use} |" for name, license_, url, use in DISTRO_PACKAGES),
        "",
    ]


def entries(items: list[tuple[str, str, str, str]]) -> list[str]:
    lines = []
    for name, license_, url, note in items:
        lines += [f"- **{name}** — {license_} — <{url}>  ", f"  {note}", ""]
    return lines


def main() -> None:
    existing = NOTICES.read_text() if NOTICES.exists() else ""
    _, found, ios = existing.partition(IOS_HEADING)
    tail = f"{IOS_HEADING}{ios}" if found else f"{IOS_HEADING}\n\n(see below)\n"
    NOTICES.write_text("\n".join(python_section()) + "\n" + tail)
    print(f"wrote {NOTICES.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
