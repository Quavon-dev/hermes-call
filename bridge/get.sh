#!/usr/bin/env bash
# Install or update hermes-call-bridge next to Hermes, from the signed release:
#
#   curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | sudo bash
#
# From a Proxmox host into the container that runs Hermes (<hermes-id> = its ID):
#
#   pct exec <hermes-id> -- bash -c "curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | bash"
#
# Downloads the latest release, checks its signature against the pinned release key before
# anything runs, then runs bridge/install.sh install --configure-hermes for the Hermes user: the one
# who called sudo, or the only user with a ~/.hermes. Settings for install.sh go in front of bash:
# `... | sudo HERMES_USER=hermes AGENT_NAME=Atlas STT_MODEL=small.en bash`. Run it again to update.
set -euo pipefail

# Release signing key (ssh-ed25519 public key of tools/release.sh).
RELEASE_SIGNER="${RELEASE_SIGNER:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZcryC9omwjnjag9wJHwPgVH4MH+sfVxJAMs/NeplTx}"
RELEASE_URL="${HC_RELEASE_URL:-https://github.com/Quavon-dev/hermes-call/releases/latest/download}"
SRC=/opt/hermes-call-src
BRIDGE_PREFIX=/opt/hermes-call-bridge

# BEGIN verify_release (identical in proxmox-helper/ct, proxmox-helper/install and bridge/get.sh;
# tools/tests/test_release.py checks that and runs it). See docs/releasing.md.
# hc_verify_release DIR [INSTALLED_VERSION]: DIR holds hermes-call.tar.gz, SHA256SUMS, SHA256SUMS.sig
# and, from 0.7 on, MANIFEST and MANIFEST.sig. Succeeds only if RELEASE_SIGNER signed the release
# and, with a MANIFEST, its version is not older than INSTALLED_VERSION (HC_ALLOW_DOWNGRADE=1 allows
# it). Releases up to 0.6.2 have no MANIFEST: accepted only while nothing newer is installed,
# HC_REQUIRE_MANIFEST is not 1, and (for a fresh install) HC_ALLOW_LEGACY_FRESH_INSTALL is 1;
# their SHA256SUMS must be exactly one line for hermes-call.tar.gz.
hc_verify_release() {
  local dir=$1 installed=${2:-} version digest oldest
  if [[ ${RELEASE_SIGNER:-} != "ssh-ed25519 "* ]]; then
    echo "RELEASE_SIGNER is not set to the release signing key (ssh-ed25519 AAAA...): refusing to install" \
      "an unverified release. Maintainers: docs/releasing.md, 'Release key'." >&2
    return 1
  fi
  [[ $installed =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || installed=
  printf 'release@quavon %s\n' "$RELEASE_SIGNER" >"$dir/allowed_signers"
  if [[ -f $dir/MANIFEST ]]; then
    ssh-keygen -Y verify -f "$dir/allowed_signers" -I release@quavon -n hermes-call-manifest \
      -s "$dir/MANIFEST.sig" <"$dir/MANIFEST" >/dev/null 2>&1 ||
      { echo "release manifest signature is invalid: not installing" >&2; return 1; }
    version=$(sed -n 's/^version=//p' "$dir/MANIFEST")
    digest=$(sed -n 's/^sha256=//p' "$dir/MANIFEST")
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $digest =~ ^[0-9a-f]{64}$ ]] ||
      { echo "release manifest is malformed: not installing" >&2; return 1; }
    [[ $(sha256sum "$dir/hermes-call.tar.gz" | cut -d' ' -f1) == "$digest" ]] ||
      { echo "release checksum mismatch: not installing" >&2; return 1; }
    oldest=$(printf '%s\n%s\n' "$version" "${installed:-$version}" | sort -V | head -1)
    if [[ -n $installed && $version != "$installed" && $oldest == "$version" ]]; then
      [[ ${HC_ALLOW_DOWNGRADE:-0} == 1 ]] || {
        echo "release $version is older than the installed $installed: refusing to downgrade" \
          "(HC_ALLOW_DOWNGRADE=1 forces it)" >&2
        return 1
      }
      echo "warning: downgrading from $installed to $version (HC_ALLOW_DOWNGRADE=1)" >&2
    fi
    return 0
  fi
  [[ ${HC_REQUIRE_MANIFEST:-0} != 1 ]] || { echo "release has no signed MANIFEST: not installing" >&2; return 1; }
  [[ -n $installed || ${HC_ALLOW_LEGACY_FRESH_INSTALL:-0} == 1 ]] ||
    { echo "release has no signed MANIFEST: a fresh install needs 0.7 or newer" >&2; return 1; }
  if [[ -n $installed && $(printf '%s\n0.6.2\n' "$installed" | sort -V | tail -1) != 0.6.2 ]]; then
    [[ ${HC_ALLOW_DOWNGRADE:-0} == 1 ]] || {
      echo "release has no MANIFEST (0.6.2 or older) but $installed is installed: refusing to downgrade" \
        "(HC_ALLOW_DOWNGRADE=1 forces it)" >&2
      return 1
    }
  fi
  ssh-keygen -Y verify -f "$dir/allowed_signers" -I release@quavon -n hermes-call-release \
    -s "$dir/SHA256SUMS.sig" <"$dir/SHA256SUMS" >/dev/null 2>&1 ||
    { echo "release signature is invalid: not installing" >&2; return 1; }
  # Exactly one line for exactly the tarball: a signed list naming other files proves nothing.
  digest=$(sed -n '1{/^[0-9a-f]\{64\}  hermes-call\.tar\.gz$/s/ .*//p;}' "$dir/SHA256SUMS")
  [[ -n $digest && $(wc -l <"$dir/SHA256SUMS") -eq 1 ]] ||
    { echo "release SHA256SUMS is not exactly one line for hermes-call.tar.gz: not installing" >&2; return 1; }
  [[ $(sha256sum "$dir/hermes-call.tar.gz" | cut -d' ' -f1) == "$digest" ]] ||
    { echo "release checksum mismatch: not installing" >&2; return 1; }
  echo "warning: release without MANIFEST (0.6.2 or older): its version is not checked" >&2
}
# END verify_release

# BEGIN bridge_version (bridge/get.sh only; tools/tests/test_release.py runs it)
# hc_installed_version PREFIX SRC: the installed bridge's version (x.y.z), or nothing when unknown.
# install.sh writes PREFIX/VERSION (also for git installs); installs from before that are read from
# get.sh's copy of their release in SRC.
hc_installed_version() {
  local prefix=$1 src=$2 version
  version=$(head -n 1 "$prefix/VERSION" 2>/dev/null || true)
  [[ -n $version ]] || version=$(sed -n 's/^version=//p' "$src/hermes-call/RELEASE" 2>/dev/null || true)
  [[ -n $version ]] ||
    version=$({ sed -n 's/^version = "\(.*\)"$/\1/p' "$src/hermes-call/bridge/pyproject.toml" 2>/dev/null || true; } | head -n 1)
  if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s' "$version"; fi
}

# hc_fetch_manifest URL DIR: downloads MANIFEST and MANIFEST.sig into DIR. 0: done; 1: the release has
# no MANIFEST (HTTP 404, releases up to 0.6.2); 2: any other failure (network, server, a MANIFEST
# without its signature), which must never count as "no MANIFEST".
hc_fetch_manifest() {
  local url=$1 dir=$2 status
  status=$(curl -sSL -o "$dir/MANIFEST" -w '%{http_code}' "$url/MANIFEST" 2>/dev/null) || true
  case $status in
    200)
      curl -fsSL -o "$dir/MANIFEST.sig" "$url/MANIFEST.sig" && return 0
      echo "release has a MANIFEST without MANIFEST.sig" >&2 ;;
    404) rm -f "$dir/MANIFEST"; return 1 ;;
    *) echo "could not download the release MANIFEST from $url (HTTP ${status:-none})" >&2 ;;
  esac
  rm -f "$dir/MANIFEST" "$dir/MANIFEST.sig"
  return 2
}
# END bridge_version

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | sudo bash"

hermes_user() {
  if [[ -n ${HERMES_USER:-} ]]; then
    printf '%s' "$HERMES_USER"
    return
  fi
  local home user found=()
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -d $home/.hermes ]] && { printf '%s' "$SUDO_USER"; return; }
  fi
  while IFS=: read -r user _ _ _ _ home _; do
    [[ -d $home/.hermes ]] && found+=("$user")
  done < <(getent passwd)
  case ${#found[@]} in
    1) printf '%s' "${found[0]}" ;;
    0) die "no Hermes found (no user has ~/.hermes); install Hermes first, or set HERMES_USER" ;;
    *) die "several users have ~/.hermes (${found[*]}); choose one: ... | sudo HERMES_USER=<user> bash" ;;
  esac
}

user=$(hermes_user)
say "Hermes user: $user"

say "Installing download tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates openssh-client >/dev/null

say "Downloading the latest release and checking its signature"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for file in hermes-call.tar.gz SHA256SUMS SHA256SUMS.sig; do
  curl -fsSL -o "$tmp/$file" "$RELEASE_URL/$file" || die "could not download $file from $RELEASE_URL"
done
# Releases from 0.7 on carry a signed MANIFEST; older ones do not (hc_verify_release decides). Only an
# HTTP 404 means "no MANIFEST": any other failure stops here instead of taking the legacy path.
manifest=0
hc_fetch_manifest "$RELEASE_URL" "$tmp" || manifest=$?
[[ $manifest -ne 2 ]] || die "release download failed: not installing"
installed=$(hc_installed_version "$BRIDGE_PREFIX" "$SRC")
if [[ -z $installed && -d $BRIDGE_PREFIX/bridge ]]; then
  say "The installed bridge's version is unknown: only a release with a signed MANIFEST is accepted"
  HC_REQUIRE_MANIFEST=1
fi
hc_verify_release "$tmp" "$installed" || die "release verification failed: not installing"

rm -rf "$SRC.new" && mkdir -p "$SRC.new"
tar -xzf "$tmp/hermes-call.tar.gz" -C "$SRC.new"
rm -rf "$SRC" && mv "$SRC.new" "$SRC"

exec "$SRC/hermes-call/bridge/install.sh" install --configure-hermes --hermes-user "$user"
