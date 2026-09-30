#!/usr/bin/env bash
# Install or update hermes-call-bridge next to Hermes, from the signed release:
#
#   curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | sudo bash
#
# From a Proxmox host into the container that runs Hermes (121 = its ID):
#
#   pct exec 121 -- bash -c "curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | bash"
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
printf 'release@quavon %s\n' "$RELEASE_SIGNER" >"$tmp/allowed_signers"
ssh-keygen -Y verify -f "$tmp/allowed_signers" -I release@quavon -n hermes-call-release \
  -s "$tmp/SHA256SUMS.sig" <"$tmp/SHA256SUMS" >/dev/null 2>&1 || die "release signature is invalid: not installing"
(cd "$tmp" && sha256sum -c --quiet SHA256SUMS) || die "release checksum mismatch: not installing"

rm -rf "$SRC.new" && mkdir -p "$SRC.new"
tar -xzf "$tmp/hermes-call.tar.gz" -C "$SRC.new"
rm -rf "$SRC" && mv "$SRC.new" "$SRC"

exec "$SRC/hermes-call/bridge/install.sh" install --configure-hermes --hermes-user "$user"
