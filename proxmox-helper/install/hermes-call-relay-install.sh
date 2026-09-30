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
RELEASE_SIGNER="${RELEASE_SIGNER:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZcryC9omwjnjag9wJHwPgVH4MH+sfVxJAMs/NeplTx}"

# BEGIN verify_release (identical in proxmox-helper/ct, proxmox-helper/install and bridge/get.sh;
# tools/tests/test_release.py checks that and runs it). See docs/releasing.md.
# hc_verify_release DIR [INSTALLED_VERSION]: DIR holds hermes-call.tar.gz, SHA256SUMS, SHA256SUMS.sig
# and, from 0.7 on, MANIFEST and MANIFEST.sig. Succeeds only if RELEASE_SIGNER signed the release
# and, with a MANIFEST, its version is not older than INSTALLED_VERSION (HC_ALLOW_DOWNGRADE=1 allows
# it). Releases up to 0.6.2 have no MANIFEST: accepted only while nothing newer is installed and
# HC_REQUIRE_MANIFEST is not 1.
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
  (cd "$dir" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 ||
    { echo "release checksum mismatch: not installing" >&2; return 1; }
  echo "warning: release without MANIFEST (0.6.2 or older): its version is not checked" >&2
}
# END verify_release

# Downloads the latest release (HC_RELEASE_URL: only for tests of this script, e.g. file:///dist;
# installs use GitHub), verifies it and unpacks it to /opt/hermes-call. A fresh install has no
# installed version to compare with.
fetch_verified_release() {
  local tmp file reason base="${HC_RELEASE_URL:-https://github.com/Quavon-dev/hermes-call/releases/latest/download}"
  tmp=$(mktemp -d)
  for file in hermes-call.tar.gz SHA256SUMS SHA256SUMS.sig; do
    curl -fsSL -o "$tmp/$file" "$base/$file" || { msg_error "could not download $file from $base"; rm -rf "$tmp"; exit 1; }
  done
  # Releases from 0.7 on carry a signed MANIFEST; older ones do not (hc_verify_release decides).
  if curl -fsSL -o "$tmp/MANIFEST" "$base/MANIFEST" 2>/dev/null; then
    curl -fsSL -o "$tmp/MANIFEST.sig" "$base/MANIFEST.sig" || { msg_error "release has a MANIFEST without MANIFEST.sig"; rm -rf "$tmp"; exit 1; }
  else
    rm -f "$tmp/MANIFEST"
  fi
  if ! reason=$(hc_verify_release "$tmp" "" 2>&1 >/dev/null); then
    msg_error "${reason:-release verification failed}"
    rm -rf "$tmp"
    exit 1
  fi
  [[ -z $reason ]] || echo "$reason" >&2
  rm -rf /opt/hermes-call
  tar -xzf "$tmp/hermes-call.tar.gz" -C /opt
  rm -rf "$tmp"
}

# The install script runs inside the container without a terminal, so it cannot ask. A domain comes
# from the host (var_relay_address=relay.example.com before the one-liner); without one the relay
# starts on the public IP with a self-signed certificate that the app pins through the pairing QR.
# Switch to a domain later with: /opt/hermescall-relay/relay/install.sh install --domain <name>
if [[ -z ${var_relay_address:-} || ${var_relay_address} == CHANGE_ME ]]; then
  msg_info "Detecting the public IP address"
  var_relay_address=$(curl -4fsS --max-time 10 https://api.ipify.org || curl -4fsS --max-time 10 https://ifconfig.me || true)
  [[ $var_relay_address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
    { msg_error "Could not detect the public IP; run again with var_relay_address=<domain or IP>"; exit 1; }
  msg_ok "Public IP: ${var_relay_address} (self-signed certificate; set a domain any time)"
fi

msg_info "Downloading and verifying the signed release"
$STD apt-get install -y openssh-client
fetch_verified_release
msg_ok "Release signature and checksum verified"

msg_info "Setting up Hermes Call Relay"
tls_args=()
if [[ ${var_relay_tls:-} == proxy ]]; then
  tls_args=(--tls proxy)
  [[ -z ${var_relay_proxy_from:-} ]] || tls_args+=(--proxy-from "$var_relay_proxy_from")
fi
$STD /opt/hermes-call/relay/install.sh install --address "$var_relay_address" "${tls_args[@]}" --no-apns --non-interactive
msg_ok "Set up Hermes Call Relay"

motd_ssh
customize
cleanup_lxc
