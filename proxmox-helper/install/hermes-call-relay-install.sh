#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: quavon-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/quavon-dev/hermes-call

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Release signing key (ssh-ed25519 public key of tools/release.sh). Installs fail closed without it.
RELEASE_SIGNER="${RELEASE_SIGNER:-}"

fetch_verified_release() {
  [[ -n $RELEASE_SIGNER ]] || { msg_error "RELEASE_SIGNER is not set: refusing to install an unverified release"; exit 1; }
  # HC_RELEASE_URL: only for tests of this script (e.g. file:///dist); installs use GitHub.
  local tmp base="${HC_RELEASE_URL:-https://github.com/Quavon-dev/hermes-call/releases/latest/download}"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/hermes-call.tar.gz" "$base/hermes-call.tar.gz"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  curl -fsSL -o "$tmp/SHA256SUMS.sig" "$base/SHA256SUMS.sig"
  printf 'release@quavon %s\n' "$RELEASE_SIGNER" >"$tmp/allowed_signers"
  ssh-keygen -Y verify -f "$tmp/allowed_signers" -I release@quavon -n hermes-call-release \
    -s "$tmp/SHA256SUMS.sig" <"$tmp/SHA256SUMS" >/dev/null ||
    { msg_error "release signature is invalid"; rm -rf "$tmp"; exit 1; }
  (cd "$tmp" && sha256sum -c --quiet SHA256SUMS) || { msg_error "release checksum mismatch"; rm -rf "$tmp"; exit 1; }
  rm -rf /opt/hermes-call
  tar -xzf "$tmp/hermes-call.tar.gz" -C /opt
  rm -rf "$tmp"
}

var_relay_address=$(prompt_input_required "Public domain name (or public IP) of this relay:" "" 300 "var_relay_address")

msg_info "Downloading and verifying the signed release"
$STD apt-get install -y openssh-client
fetch_verified_release
msg_ok "Release signature and checksum verified"

msg_info "Setting up Hermes Call Relay"
$STD /opt/hermes-call/relay/install.sh install --address "$var_relay_address" --no-apns --non-interactive
msg_ok "Set up Hermes Call Relay"

motd_ssh
customize
cleanup_lxc
