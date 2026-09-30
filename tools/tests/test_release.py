# SPDX-License-Identifier: MIT
"""tools/release.sh (build, MANIFEST, signing) and the installers' shared hc_verify_release block."""

import gzip
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


def test_verify_block_is_identical_in_all_installers() -> None:
    blocks = [BLOCK.search(path.read_text()) for path in HELPERS]
    assert all(blocks), "every Proxmox helper script must contain the verify_release block"
    assert blocks[0].group(0) == blocks[1].group(0)
    get_sh = GET_SH.read_text()
    if "BEGIN verify_release" in get_sh:  # bridge/get.sh adopts it in the bridge lane
        assert BLOCK.search(get_sh).group(0) == blocks[0].group(0)


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
