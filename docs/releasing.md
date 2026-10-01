# Releasing

For maintainers. Three things get released, each on its own path:

| What | Tag | Built by | Signed by |
|---|---|---|---|
| Relay, bridge, Hermes plugin, Proxmox helper (one tarball) | `v1.2.3` | `tools/release.sh` (locally or `.github/workflows/release.yml`) | the offline **release key** (SSH ed25519) |
| Relay / push gateway container image | `v1.2.3` and every push to `main` | `.github/workflows/relay-image.yml` | cosign, keyless (this repository's workflow identity) |
| iOS app | `ios-v<version>-<build>` (automatic) | `.github/workflows/ios-release.yml` | Apple distribution certificate; see [iOS app](ios.md#automatic-releases) |

Installers never use `main`: `bridge/get.sh` and the Proxmox helper download the release marked
*latest* and install it only if the release key signed it.

## Release key

One SSH ed25519 key signs every relay/bridge release. Its public half is pinned as
`RELEASE_SIGNER` in:

- `proxmox-helper/ct/hermes-call-relay.sh`
- `proxmox-helper/install/hermes-call-relay-install.sh`
- `bridge/get.sh`

The key used for 0.6.0 to 0.6.2 is already pinned there. Only if it is lost or must be replaced:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hermes-call-release -C release@quavon   # use a passphrase
cat ~/.ssh/hermes-call-release.pub                                       # ssh-ed25519 AAAA… release@quavon
```

Put the `ssh-ed25519 AAAA…` part (without the comment) into `RELEASE_SIGNER` in all three files and
in "Verify a release by hand" below in one commit, and publish a release signed with the new key before anything else. Installers refuse to
install when `RELEASE_SIGNER` is empty or not an ed25519 key, with a message pointing here. Keep the
private key off GitHub and off servers (a hardware key or an offline machine; a backup in your
password manager). A replaced key means old installers (piped from `main` each time, so they update
themselves) accept only releases signed with the new one.

## What a release contains

`tools/release.sh v1.2.3` writes `dist/`:

| File | Content | Checked by |
|---|---|---|
| `hermes-call.tar.gz` | `git archive` of the tag under `hermes-call/`, plus `hermes-call/RELEASE` (`version`, `tag`, `commit`) | – |
| `SHA256SUMS`, `SHA256SUMS.sig` | tarball checksum, signed in namespace `hermes-call-release` | installers of 0.6.x |
| `MANIFEST`, `MANIFEST.sig` | `version`, `tag`, `commit`, commit date, tarball name and SHA-256, signed in namespace `hermes-call-manifest` | installers from 0.7 on |

The build is reproducible: the tar content depends only on the tag (`tools/tests/test_release.py`
checks it). `release.sh` refuses a tag that is not `vX.Y.Z` or whose `relay/hermescall_relay/version.py`
and `bridge/pyproject.toml` do not say the same version.

### Rollback protection

The installers (`hc_verify_release`, the same block in all three scripts, checked by a test)
verify `MANIFEST.sig`, compare the tarball with the manifest's checksum and refuse a release whose
version is **older than the installed one** (Proxmox helper `update`: `/opt/hermescall-relay/VERSION`;
bridge: `/opt/hermes-call-bridge/VERSION`, written by `bridge/install.sh`, else the copy of the
release in `/opt/hermes-call-src`). `HC_ALLOW_DOWNGRADE=1` in front of the command forces it.
`bridge/get.sh` takes the no-MANIFEST path below only when the MANIFEST download answers HTTP 404
(any other failure stops it), and requires a MANIFEST when a bridge is installed but its version is
unknown.
`relay/install.sh update` does the same for a checkout (`--allow-downgrade`); `install.sh rollback`
stays the way back to the previous code.

A release without a MANIFEST (0.6.2 and older) is still accepted while nothing newer is installed,
so the scripts keep working until the first 0.7 release is *latest*. Its `SHA256SUMS` must be
exactly one line, `<64 hex>  hermes-call.tar.gz`, and the installers compare that checksum with the
tarball themselves (a signed list that names other files proves nothing about the tarball);
`release.sh --sign` refuses to sign any other `SHA256SUMS`. `HC_REQUIRE_MANIFEST=1` in front of a
command refuses every release without a MANIFEST.

Fresh installs versus updates: `HC_ALLOW_LEGACY_FRESH_INSTALL=0` refuses a release without MANIFEST
when nothing is installed yet, while an existing 0.6.x install can still update. It defaults to 1
for now because the release marked *latest* (0.6.2) has no MANIFEST, and the helper scripts run
from `main`: with 0, every fresh install would fail until 0.7 is published.

> **TODO after the first 0.7 release is *latest*:** in the `verify_release` block (both Proxmox
> scripts and `bridge/get.sh`, one commit; the test checks they stay identical) change
> `${HC_ALLOW_LEGACY_FRESH_INSTALL:-1}` to `${HC_ALLOW_LEGACY_FRESH_INSTALL:-0}`. From then on a
> fresh install needs a release with a signed MANIFEST and cannot be served an old release;
> existing 0.6.x installs still update through the legacy path. Later, once no 0.6.x installs are
> expected, set `HC_REQUIRE_MANIFEST` to 1 as well (`: "${HC_REQUIRE_MANIFEST:=1}"` next to
> `RELEASE_SIGNER`).

### Verify a release by hand

For installs without the helper scripts (a VPS relay, a review before running anything as root).
The release key (the same `RELEASE_SIGNER` as in `bridge/get.sh` and the Proxmox helper):

```
release@quavon ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZcryC9omwjnjag9wJHwPgVH4MH+sfVxJAMs/NeplTx
```

```bash
mkdir /tmp/hc && cd /tmp/hc
for f in hermes-call.tar.gz MANIFEST MANIFEST.sig; do
  curl -fsSLO "https://github.com/Quavon-dev/hermes-call/releases/latest/download/$f"
done
echo 'release@quavon ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZcryC9omwjnjag9wJHwPgVH4MH+sfVxJAMs/NeplTx' >allowed_signers
ssh-keygen -Y verify -f allowed_signers -I release@quavon -n hermes-call-manifest -s MANIFEST.sig <MANIFEST
grep -qx "sha256=$(sha256sum hermes-call.tar.gz | cut -d' ' -f1)" MANIFEST && echo "tarball matches"
grep '^version=' MANIFEST
tar -xzf hermes-call.tar.gz -C /opt       # then e.g. /opt/hermes-call/relay/install.sh install --domain …
```

Releases before 0.7 have no MANIFEST: verify `SHA256SUMS` with `SHA256SUMS.sig` in namespace
`hermes-call-release`, check that it is exactly one line ending in `  hermes-call.tar.gz`, and run
`sha256sum -c SHA256SUMS`. Later updates of such a relay:
download and verify the next release the same way, then `/opt/hermes-call/relay/install.sh update`
(it refuses older code than the installed one).

## Cutting a release

1. `main` is green; `CHANGELOG.md` has the section with today's date.
2. Bump the version in `relay/hermescall_relay/version.py`, `relay/pyproject.toml`,
   `bridge/pyproject.toml`, `common/pyproject.toml` and the root `pyproject.toml` (a unit test
   checks the relay pair), `uv lock`, commit `chore: version 1.2.3`.
3. Tag and push the tag (annotated, signed if you sign commits):

   ```bash
   git tag -s v1.2.3 -m "Hermes Call 1.2.3" && git push origin v1.2.3
   ```

4. **CI** (`release.yml`) runs the tests, builds `dist/` with `tools/release.sh`, attests the
   tarball's build provenance and creates a **draft** GitHub release with the tarball,
   `SHA256SUMS` and `MANIFEST`. `relay-image.yml` builds, scans, signs and pushes the image tags
   `1.2.3` and `1.2`.
5. **Sign** (offline key): download the three files of the draft into a folder and run, in a clean
   checkout that has the tag:

   ```bash
   gh release download v1.2.3 --dir /tmp/v1.2.3 --pattern 'hermes-call.tar.gz' --pattern SHA256SUMS --pattern MANIFEST
   tools/release.sh --sign /tmp/v1.2.3 ~/.ssh/hermes-call-release
   gh release upload v1.2.3 /tmp/v1.2.3/SHA256SUMS.sig /tmp/v1.2.3/MANIFEST.sig
   ```

   `--sign` rebuilds the archive from your checkout and signs only if the downloaded tarball holds
   exactly the tag's files and both lists describe it.
6. Publish the draft and mark it **latest** (iOS releases are never latest). From that moment the
   installers pick it up.
7. Check: `curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | sudo bash`
   on a test host, or the Proxmox helper's update in a test container.

Without CI (or to release from your machine): `tools/release.sh v1.2.3 ~/.ssh/hermes-call-release`
builds and signs `dist/`; create the release with those five files.

Signing in CI instead: store the private key as the repository secret `RELEASE_SSH_SIGNING_KEY`
(environment `release`, with required reviewers) and the workflow signs the draft itself. That is
convenient but moves the key into GitHub; the offline way above is the default.

## Container image

`relay-image.yml` pushes `ghcr.io/quavon-dev/hermes-call-relay` with `:edge` and `:sha-<commit>`
from `main`, and `:X.Y.Z`, `:X.Y` and `:latest` from release tags (`vX.Y.Z`; a pre-release tag
such as `v1.2.3-rc1` gets only its own tag), so `:latest` is always a release. The weekly rebuild
for Debian security updates runs on `main` and refreshes `:edge`. `relay/deploy/docker-compose.yml`
pins the image to `${HERMESCALL_RELAY_VERSION:-X.Y.Z}`; `tools/release.sh` refuses a tag whose
compose file does not default to the tag's version, so bump it together with `version.py`. Before
the push, Trivy scans the image and fails the run on a CRITICAL vulnerability that has a fix. The
pushed digest is signed keylessly with cosign and carries an SBOM and provenance. The job summary
shows the digest and the verification command:

```bash
cosign verify ghcr.io/quavon-dev/hermes-call-relay@sha256:… \
  --certificate-identity-regexp '(?i)^https://github\.com/quavon-dev/hermes-call/\.github/workflows/relay-image\.yml@refs/(heads/main|tags/v.*)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

**Deployments pull, this repository does not push.** The workflow used to clone the deployment
repository at its HEAD with a write token and run a script from it; a compromised workflow run or a
change to that script could then rewrite the whole cluster configuration. Now the deployment side
updates itself: Renovate (docker datasource with `pinDigests`) or a scheduled job in the deployment
repository that reads the new digest, runs the `cosign verify` above and commits the pin. The token
for that lives in the deployment repository, not here. Until that is set up, copy the digest from
the job summary into the deployment by hand.

## CI overview

| Workflow | When | What |
|---|---|---|
| `ci.yml` | push, pull request, weekly (Linux jobs) | ruff, shellcheck, pytest with coverage floor, SPDX on new files, pip-audit, relay on distro packages, relay installer in systemd containers, Swift core, app unit tests, app UI tests |
| `codeql.yml` | push, pull request (Python); weekly (Swift) | CodeQL security queries |
| `hermes-compat.yml` | plugin/bridge changes, weekly | the plugin in a pinned Hermes Agent release |
| `bridge-e2e.yml` | bridge installer changes, weekly | bridge install, Whisper, Kokoro, calls both ways |
| `release.yml` | `v*` tags | draft release (above) |
| `relay-image.yml` | relay changes, `v*` tags, weekly | image (above) |
| `ios-release.yml` | app changes on `main` | TestFlight and App Store ([iOS app](ios.md#automatic-releases)) |
| `gateway-monitor.yml` | every 30 minutes | `tools/gateway_smoke.py` against `hermes-push.quavon.de`; a failure e-mails the maintainers |

Actions are pinned by commit SHA; Dependabot proposes updates weekly (`.github/dependabot.yml`).
