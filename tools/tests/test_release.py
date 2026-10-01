# SPDX-License-Identifier: MIT
"""tools/release.sh (build, MANIFEST, signing) and the installers' shared hc_verify_release block."""

import gzip
import hashlib
import io
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
RELEASE_SH = ROOT / "tools" / "release.sh"
HELPERS = [
    ROOT / "proxmox-helper" / "ct" / "hermes-call-relay.sh",
    ROOT / "proxmox-helper" / "install" / "hermes-call-relay-install.sh",
]
GET_SH = ROOT / "bridge" / "get.sh"
BLOCK = re.compile(r"^# BEGIN verify_release.*?^# END verify_release\n", re.S | re.M)

pytestmark = pytest.mark.skipif(
    not (shutil.which("ssh-keygen") and shutil.which("git") and shutil.which("bash")), reason="needs ssh-keygen, git, bash"
)


def run(*args: str, cwd: Path | None = None, env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, env=env, check=check, capture_output=True, text=True)


def git_env() -> dict:
    return {
        **os.environ,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.invalid",
    }


def make_key(path: Path) -> str:
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", str(path))
    return " ".join(path.with_suffix(".pub").read_text().split()[:2])


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "tools").mkdir(parents=True)
    (repo / "relay" / "hermescall_relay").mkdir(parents=True)
    (repo / "bridge").mkdir()
    shutil.copy(RELEASE_SH, repo / "tools" / "release.sh")
    (repo / "relay" / "hermescall_relay" / "version.py").write_text('VERSION = "1.2.3"\n')
    (repo / "bridge" / "pyproject.toml").write_text('[project]\nname = "b"\nversion = "1.2.3"\n')
    (repo / "README.md").write_text("hello\n")
    env = git_env()
    run("git", "init", "-q", "-b", "main", cwd=repo, env=env)
    run("git", "add", "-A", cwd=repo, env=env)
    run("git", "commit", "-q", "-m", "release", cwd=repo, env=env)
    run("git", "tag", "v1.2.3", cwd=repo, env=env)
    return repo


def release(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return run("bash", str(repo / "tools" / "release.sh"), *args, cwd=repo, env=git_env(), check=check)


def manifest(path: Path) -> dict:
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def test_build_signs_sums_and_manifest(repo: Path, tmp_path: Path) -> None:
    key = tmp_path / "key"
    public = make_key(key)
    release(repo, "v1.2.3", str(key))
    dist = repo / "dist"
    fields = manifest(dist / "MANIFEST")
    commit = run("git", "rev-parse", "v1.2.3^{commit}", cwd=repo, env=git_env()).stdout.strip()
    assert fields["version"] == "1.2.3" and fields["tag"] == "v1.2.3" and fields["commit"] == commit
    assert fields["tarball"] == "hermes-call.tar.gz"
    assert re.fullmatch(r"[0-9a-f]{64}", fields["sha256"])
    with tarfile.open(dist / "hermes-call.tar.gz") as tar:
        names = tar.getnames()
        assert "hermes-call/README.md" in names
        release_file = tar.extractfile("hermes-call/RELEASE").read().decode()
    assert release_file == f"version=1.2.3\ntag=v1.2.3\ncommit={commit}\n"
    signers = tmp_path / "allowed"
    signers.write_text(f"release@quavon {public}\n")
    for name, namespace in (("SHA256SUMS", "hermes-call-release"), ("MANIFEST", "hermes-call-manifest")):
        command = ["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "release@quavon", "-n", namespace]
        with open(dist / name) as data:
            verified = subprocess.run([*command, "-s", str(dist / f"{name}.sig")], stdin=data, capture_output=True)
        assert verified.returncode == 0, verified.stderr


def test_build_is_reproducible_and_sign_checks_content(repo: Path, tmp_path: Path) -> None:
    key = tmp_path / "key"
    make_key(key)
    release(repo, "v1.2.3")
    first = gzip.decompress((repo / "dist" / "hermes-call.tar.gz").read_bytes())
    assert not (repo / "dist" / "MANIFEST.sig").exists()
    downloaded = tmp_path / "draft"
    shutil.copytree(repo / "dist", downloaded)
    release(repo, "v1.2.3")
    assert gzip.decompress((repo / "dist" / "hermes-call.tar.gz").read_bytes()) == first

    signed = release(repo, "--sign", str(downloaded), str(key))
    assert "signed v1.2.3" in signed.stdout
    assert (downloaded / "MANIFEST.sig").exists() and (downloaded / "SHA256SUMS.sig").exists()

    # A tarball with one extra file (and checksums rewritten to match) is refused.
    buffer = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(first)) as source, tarfile.open(fileobj=buffer, mode="w") as target:
        for member in source.getmembers():
            target.addfile(member, source.extractfile(member) if member.isfile() else None)
        extra = tarfile.TarInfo("hermes-call/evil.sh")
        extra.size = 3
        target.addfile(extra, io.BytesIO(b"hi\n"))
    (downloaded / "hermes-call.tar.gz").write_bytes(gzip.compress(buffer.getvalue()))
    refused = release(repo, "--sign", str(downloaded), str(key), check=False)
    assert refused.returncode != 0 and "does not contain exactly v1.2.3" in refused.stderr


def test_version_must_match_tag(repo: Path) -> None:
    env = git_env()
    (repo / "bridge" / "pyproject.toml").write_text('[project]\nname = "b"\nversion = "1.2.4"\n')
    run("git", "commit", "-qam", "bump bridge only", cwd=repo, env=env)
    run("git", "tag", "v1.2.4", cwd=repo, env=env)
    failed = release(repo, "v1.2.4", check=False)
    assert failed.returncode == 2 and "relay/hermescall_relay/version.py says '1.2.3'" in failed.stderr
    assert release(repo, "1.2.3", check=False).returncode == 2


def test_compose_must_pin_the_released_image(repo: Path) -> None:
    env = git_env()
    compose = repo / "relay" / "deploy" / "docker-compose.yml"
    compose.parent.mkdir(parents=True)
    compose.write_text("services:\n  relay:\n    image: ghcr.io/quavon-dev/hermes-call-relay:latest\n")
    run("git", "add", "-A", cwd=repo, env=env)
    run("git", "commit", "-qm", "compose", cwd=repo, env=env)
    run("git", "tag", "-f", "v1.2.3", cwd=repo, env=env)
    failed = release(repo, "v1.2.3", check=False)
    assert failed.returncode == 2 and "must default to image tag 1.2.3" in failed.stderr
    pinned = "ghcr.io/quavon-dev/hermes-call-relay:${HERMESCALL_RELAY_VERSION:-1.2.3}"
    compose.write_text(f"services:\n  relay:\n    image: {pinned}\n")
    run("git", "commit", "-qam", "pin", cwd=repo, env=env)
    run("git", "tag", "-f", "v1.2.3", cwd=repo, env=env)
    assert release(repo, "v1.2.3").returncode == 0


def test_this_checkout_pins_its_own_version_and_main_never_publishes_latest() -> None:
    version = re.search(r'^VERSION = "(.*)"$', (ROOT / "relay" / "hermescall_relay" / "version.py").read_text(), re.M)
    compose = (ROOT / "relay" / "deploy" / "docker-compose.yml").read_text()
    assert f"hermes-call-relay:${{HERMESCALL_RELAY_VERSION:-{version.group(1)}}}" in compose
    workflow = (ROOT / ".github" / "workflows" / "relay-image.yml").read_text()
    assert "flavor: latest=false" in workflow
    latest = [line for line in workflow.splitlines() if "value=latest" in line]
    assert latest and all("refs/tags/v" in line for line in latest)


def test_verify_block_is_identical_in_all_installers() -> None:
    blocks = [BLOCK.search(path.read_text()) for path in HELPERS]
    assert all(blocks), "every Proxmox helper script must contain the verify_release block"
    assert blocks[0].group(0) == blocks[1].group(0)
    get_sh = BLOCK.search(GET_SH.read_text())
    assert get_sh, "bridge/get.sh must contain the verify_release block"
    assert get_sh.group(0) == blocks[0].group(0)


def test_release_key_is_the_same_everywhere() -> None:
    signer = re.compile(r'^RELEASE_SIGNER="\$\{RELEASE_SIGNER:-(ssh-ed25519 [A-Za-z0-9+/=]+)\}"$', re.M)
    keys = {signer.search(path.read_text()).group(1) for path in [*HELPERS, GET_SH]}
    assert len(keys) == 1
    assert keys.pop() in (ROOT / "docs" / "releasing.md").read_text()


class Verifier:
    def __init__(self, tmp_path: Path, dist: Path, public: str) -> None:
        self.tmp_path, self.dist, self.public = tmp_path, dist, public
        self.script = tmp_path / "verify.sh"
        self.script.write_text(
            "set -Eeuo pipefail\n" + BLOCK.search(HELPERS[0].read_text()).group(0) + 'hc_verify_release "$@"\n'
        )

    def __call__(self, installed: str = "", signer: str | None = None, drop: tuple = (), **env: str):
        work = self.tmp_path / f"work{len(list(self.tmp_path.glob('work*')))}"
        shutil.copytree(self.dist, work)
        for name in drop:
            (work / name).unlink()
        environment = {**os.environ, "RELEASE_SIGNER": self.public if signer is None else signer, **env}
        return run("bash", str(self.script), str(work), installed, env=environment, check=False)


@pytest.fixture
def verifier(repo: Path, tmp_path: Path) -> Verifier:
    key = tmp_path / "key"
    public = make_key(key)
    release(repo, "v1.2.3", str(key))
    return Verifier(tmp_path, repo / "dist", public)


def test_verify_accepts_signed_release_and_upgrades(verifier: Verifier) -> None:
    assert verifier().returncode == 0
    assert verifier("1.2.2").returncode == 0
    assert verifier("1.2.3").returncode == 0  # reinstalling the same version
    assert verifier("0.9.10").returncode == 0


def test_verify_refuses_downgrade_unless_forced(verifier: Verifier) -> None:
    refused = verifier("1.10.0")
    assert refused.returncode == 1 and "older than the installed 1.10.0" in refused.stderr
    forced = verifier("1.10.0", HC_ALLOW_DOWNGRADE="1")
    assert forced.returncode == 0 and "downgrading" in forced.stderr


def test_verify_refuses_bad_signer_and_tampering(verifier: Verifier, tmp_path: Path) -> None:
    other = make_key(tmp_path / "other")
    assert "manifest signature is invalid" in verifier(signer=other).stderr
    missing = verifier(signer="")
    assert missing.returncode == 1 and "docs/releasing.md" in missing.stderr
    (verifier.dist / "hermes-call.tar.gz").write_bytes(b"not the release")
    assert "checksum mismatch" in verifier().stderr


def test_verify_signatures_are_not_interchangeable(verifier: Verifier) -> None:
    shutil.copy(verifier.dist / "SHA256SUMS.sig", verifier.dist / "MANIFEST.sig")
    assert "manifest signature is invalid" in verifier().stderr


def test_verify_legacy_release_without_manifest(verifier: Verifier) -> None:
    legacy = verifier(drop=("MANIFEST", "MANIFEST.sig"))
    assert legacy.returncode == 0 and "without MANIFEST" in legacy.stderr
    assert verifier("0.6.2", drop=("MANIFEST", "MANIFEST.sig")).returncode == 0
    newer = verifier("0.7.0", drop=("MANIFEST", "MANIFEST.sig"))
    assert newer.returncode == 1 and "refusing to downgrade" in newer.stderr
    required = verifier(drop=("MANIFEST", "MANIFEST.sig"), HC_REQUIRE_MANIFEST="1")
    assert required.returncode == 1 and "no signed MANIFEST" in required.stderr


def resign_sums(verifier: Verifier, content: str) -> None:
    sums = verifier.dist / "SHA256SUMS"
    sums.write_text(content)
    (verifier.dist / "SHA256SUMS.sig").unlink()
    run("ssh-keygen", "-Y", "sign", "-q", "-f", str(verifier.tmp_path / "key"), "-n", "hermes-call-release", str(sums))


@pytest.mark.parametrize(
    "content",
    [
        "{other}  other-file\n",  # a signed list that does not name the tarball
        "{digest}  hermes-call.tar.gz\n{digest}  hermes-call.tar.gz\n",
        "{digest}  hermes-call.tar.gz\n{digest}  evil.sh\n",
        "{digest} *hermes-call.tar.gz\n",
        "",
    ],
)
def test_verify_legacy_sums_must_name_exactly_the_tarball(verifier: Verifier, content: str) -> None:
    digest = hashlib.sha256((verifier.dist / "hermes-call.tar.gz").read_bytes()).hexdigest()
    (verifier.dist / "other-file").write_text("x")
    resign_sums(verifier, content.format(digest=digest, other=hashlib.sha256(b"x").hexdigest()))
    refused = verifier("0.6.1", drop=("MANIFEST", "MANIFEST.sig"))
    assert refused.returncode == 1 and "SHA256SUMS" in refused.stderr


def test_verify_legacy_checks_the_tarball_itself(verifier: Verifier) -> None:
    (verifier.dist / "hermes-call.tar.gz").write_bytes(b"not the release")
    refused = verifier("0.6.1", drop=("MANIFEST", "MANIFEST.sig"))
    assert refused.returncode == 1 and "checksum mismatch" in refused.stderr


def test_verify_legacy_only_for_upgrades_once_fresh_installs_need_a_manifest(verifier: Verifier) -> None:
    legacy = ("MANIFEST", "MANIFEST.sig")
    fresh = verifier(drop=legacy, HC_ALLOW_LEGACY_FRESH_INSTALL="0")
    assert fresh.returncode == 1 and "fresh install" in fresh.stderr
    assert verifier("0.6.1", drop=legacy, HC_ALLOW_LEGACY_FRESH_INSTALL="0").returncode == 0  # existing install
    assert verifier(HC_ALLOW_LEGACY_FRESH_INSTALL="0").returncode == 0  # MANIFEST releases always


def test_sign_refuses_sums_that_do_not_name_exactly_the_tarball(repo: Path, tmp_path: Path) -> None:
    key = tmp_path / "key"
    make_key(key)
    release(repo, "v1.2.3")
    sums = repo / "dist" / "SHA256SUMS"
    sums.write_text(sums.read_text() + sums.read_text().replace("hermes-call.tar.gz", "other"))
    (repo / "dist" / "other").write_bytes((repo / "dist" / "hermes-call.tar.gz").read_bytes())
    refused = release(repo, "--sign", "dist", str(key), check=False)
    assert refused.returncode == 2 and "SHA256SUMS must be exactly one line" in refused.stderr


# ---- bridge/get.sh: the installed version and the MANIFEST download (outside the shared block) ----

VERSION_BLOCK = re.compile(r"^# BEGIN bridge_version.*?^# END bridge_version\n", re.S | re.M)
INSTALL_SH = ROOT / "bridge" / "install.sh"


def get_sh(tmp_path: Path, call: str, *args: str) -> subprocess.CompletedProcess:
    block = VERSION_BLOCK.search(GET_SH.read_text())
    assert block, "bridge/get.sh must contain the bridge_version block"
    script = tmp_path / "get-block.sh"
    script.write_text("set -Eeuo pipefail\n" + block.group(0) + call + ' "$@"\n')
    return run("bash", str(script), *args, check=False)


def test_get_sh_reads_the_version_install_sh_wrote_first(tmp_path: Path) -> None:
    prefix, src = tmp_path / "prefix", tmp_path / "src"
    (src / "hermes-call" / "bridge").mkdir(parents=True)
    prefix.mkdir()
    assert get_sh(tmp_path, "hc_installed_version", str(prefix), str(src)).stdout == ""
    (src / "hermes-call" / "bridge" / "pyproject.toml").write_text('[project]\nversion = "0.6.1"\n')
    assert get_sh(tmp_path, "hc_installed_version", str(prefix), str(src)).stdout == "0.6.1"
    (src / "hermes-call" / "RELEASE").write_text("version=0.6.2\ntag=v0.6.2\n")
    assert get_sh(tmp_path, "hc_installed_version", str(prefix), str(src)).stdout == "0.6.2"
    # A git install or a removed /opt/hermes-call-src: install.sh's VERSION decides.
    (prefix / "VERSION").write_text("0.7.1\n")
    assert get_sh(tmp_path, "hc_installed_version", str(prefix), str(src)).stdout == "0.7.1"
    shutil.rmtree(src)
    assert get_sh(tmp_path, "hc_installed_version", str(prefix), str(src)).stdout == "0.7.1"
    # Not x.y.z: unknown (get.sh then requires a signed MANIFEST), not a fresh install.
    (prefix / "VERSION").write_text("0.7.0.dev1\n")
    result = get_sh(tmp_path, "hc_installed_version", str(prefix), str(src))
    assert result.returncode == 0 and result.stdout == ""


@pytest.fixture
def release_server(tmp_path: Path):
    import functools
    import http.server
    import threading

    root = tmp_path / "www"
    root.mkdir()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path.endswith("/broken/MANIFEST"):
                self.send_error(500)
                return
            super().do_GET()

        def log_message(self, *args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield root, f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def test_get_sh_takes_the_legacy_path_only_on_a_404(release_server, tmp_path: Path) -> None:
    root, url = release_server
    (root / "signed").mkdir()
    (root / "signed" / "MANIFEST").write_text("version=0.7.0\n")
    (root / "signed" / "MANIFEST.sig").write_text("sig\n")
    (root / "legacy").mkdir()
    (root / "nosig").mkdir()
    (root / "nosig" / "MANIFEST").write_text("version=0.7.0\n")
    work = tmp_path / "work"
    work.mkdir()

    signed = get_sh(tmp_path, "hc_fetch_manifest", f"{url}/signed", str(work))
    assert signed.returncode == 0 and (work / "MANIFEST").read_text() == "version=0.7.0\n"
    assert (work / "MANIFEST.sig").exists()
    (work / "MANIFEST.sig").unlink()

    legacy = get_sh(tmp_path, "hc_fetch_manifest", f"{url}/legacy", str(work))
    assert legacy.returncode == 1 and not (work / "MANIFEST").exists()

    for broken in ("broken", "nosig"):
        result = get_sh(tmp_path, "hc_fetch_manifest", f"{url}/{broken}", str(work))
        assert result.returncode == 2, broken
        assert not (work / "MANIFEST").exists()
    # No answer at all (network down, DNS): an error, never "no MANIFEST".
    down = get_sh(tmp_path, "hc_fetch_manifest", "http://127.0.0.1:9/x", str(work))
    assert down.returncode == 2 and "MANIFEST" in down.stderr


def test_get_sh_requires_a_manifest_when_an_installed_bridge_has_no_known_version() -> None:
    text = GET_SH.read_text()
    main = text[text.index("# END bridge_version") :]
    assert 'hc_installed_version "$BRIDGE_PREFIX" "$SRC"' in main
    assert re.search(r'-z \$installed && -d \$BRIDGE_PREFIX/bridge[^\n]*\n(?:[^\n]*\n){0,2}\s*HC_REQUIRE_MANIFEST=1\n', main)


def test_install_sh_records_the_installed_version(tmp_path: Path) -> None:
    src = tmp_path / "hermes-call"
    (src / "bridge").mkdir(parents=True)
    shutil.copy(INSTALL_SH, src / "bridge" / "install.sh")
    (src / "bridge" / "pyproject.toml").write_text('[project]\nversion = "0.7.2"\n')

    function = re.search(r"^release_version\(\) \{.*?^\}\n", INSTALL_SH.read_text(), re.S | re.M)
    assert function, "bridge/install.sh must define release_version"
    script = tmp_path / "release-version.sh"
    script.write_text('set -Eeuo pipefail\nSRC_ROOT=$1\n' + function.group(0) + "release_version\n")

    def version() -> subprocess.CompletedProcess:
        return run("bash", str(script), str(src), check=False)

    assert version().stdout == "0.7.2"
    (src / "RELEASE").write_text("version=0.7.3\ntag=v0.7.3\n")
    assert version().stdout == "0.7.3"
    assert "VERSION" in INSTALL_SH.read_text().split("deploy_code() {", 1)[1].split("\n}\n", 1)[0]
