#!/usr/bin/env bash
# One command on the Proxmox host (as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/proxmox-helper/ct/hermes-call-relay.sh)"
# The framework loads install/hermes-call-relay-install.sh from this repository (not from
# community-scripts), and that script installs only a release signed with RELEASE_SIGNER.
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/proxmox-helper}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# Author: quavon-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/quavon-dev/hermes-call

APP="Hermes-Call-Relay"
var_tags="${var_tags:-voip;webrtc;turn}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

export var_relay_address="${var_relay_address:-}"
export var_relay_tls="${var_relay_tls:-}"
export var_relay_proxy_from="${var_relay_proxy_from:-}"

# Asked here on the Proxmox host, before the container exists: the install script inside the
# container has no terminal and cannot ask (the framework would silently use CHANGE_ME). Also in
# "Default Settings" mode. Empty = the relay runs on the public IP with a self-signed certificate.
ask_relay_address() {
  [[ -z $var_relay_address && -t 0 ]] && command -v pct >/dev/null 2>&1 || return 0
  local prompt="Domain for the relay, e.g. relay.example.com (Let's Encrypt).

Its DNS A record must point at your public IP, with TCP 443 forwarded to the container.
Leave empty to use your public IP with a self-signed certificate (the app pins it)."
  if command -v whiptail >/dev/null 2>&1; then
    var_relay_address=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HERMES CALL RELAY" \
      --inputbox "$prompt" 14 76 "" 3>&1 1>&2 2>&3) || var_relay_address=""
  else
    read -r -p "Domain for the relay (empty = public IP): " var_relay_address
  fi
  var_relay_address=$(tr '[:upper:]' '[:lower:]' <<<"${var_relay_address// /}")
  [[ -z $var_relay_address ]] && return 0
  if [[ ! $var_relay_address =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    echo "Not a domain name: $var_relay_address" >&2
    exit 1
  fi
  local public resolved
  public=$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  # The framework runs with set -euo pipefail: a name without a DNS record yet must warn, not exit.
  resolved=$({ getent ahostsv4 "$var_relay_address" 2>/dev/null || true; } | awk 'NR==1 {print $1}')
  if [[ -n $public && $resolved != "$public" ]]; then
    echo "Warning: $var_relay_address resolves to ${resolved:-nothing}, your public IP is $public." >&2
    echo "The domain only works once its A record points at $public." >&2
  fi
  ask_tls_mode
}
# Who terminates HTTPS for the domain: the relay itself (Let's Encrypt on 443) or a reverse proxy
# that already publishes your services (Nginx Proxy Manager, Traefik, Caddy) and forwards to 8743.
ask_tls_mode() {
  [[ -z $var_relay_tls ]] || return 0
  if command -v whiptail >/dev/null 2>&1; then
    var_relay_tls=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HTTPS FOR ${var_relay_address}" \
      --menu "Who handles HTTPS for ${var_relay_address}?" 14 76 2 \
      "acme" "This relay (Let's Encrypt; forward TCP 443 to the container)" \
      "proxy" "My reverse proxy (NPM, Traefik, Caddy -> http://container:8743)" \
      3>&1 1>&2 2>&3) || var_relay_tls=acme
  else
    read -r -p "HTTPS by [a]this relay (Let's Encrypt) or [p]your reverse proxy? [a/p]: " var_relay_tls
    [[ ${var_relay_tls,,} == p* ]] && var_relay_tls=proxy || var_relay_tls=acme
  fi
  [[ $var_relay_tls == proxy && -z $var_relay_proxy_from ]] || return 0
  local prompt="IP address of your reverse proxy (only it may reach port 8743, only its
X-Forwarded-For is believed). Leave empty to allow any private address (10/8, 172.16/12,
192.168/16)."
  if command -v whiptail >/dev/null 2>&1; then
    var_relay_proxy_from=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "REVERSE PROXY" \
      --inputbox "$prompt" 12 76 "" 3>&1 1>&2 2>&3) || var_relay_proxy_from=""
  else
    read -r -p "IP of your reverse proxy (empty = any private address): " var_relay_proxy_from
  fi
  var_relay_proxy_from=${var_relay_proxy_from// /}
  if [[ -n $var_relay_proxy_from && ! $var_relay_proxy_from =~ ^[0-9a-fA-F:.,/]+$ ]]; then
    echo "Not an IP address or CIDR list: $var_relay_proxy_from" >&2
    exit 1
  fi
  if [[ $var_relay_proxy_from =~ ^[0-9.]+$ ]]; then var_relay_proxy_from+="/32"; fi
}
ask_relay_address
export var_relay_address var_relay_tls var_relay_proxy_from

header_info "$APP"
variables
color
catch_errors

# Release signing key (ssh-ed25519 public key of tools/release.sh). Installs fail closed without it.
RELEASE_SIGNER="${RELEASE_SIGNER:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZcryC9omwjnjag9wJHwPgVH4MH+sfVxJAMs/NeplTx}"

fetch_verified_release() {
  [[ -n $RELEASE_SIGNER ]] || { msg_error "RELEASE_SIGNER is not set: refusing to install an unverified release"; exit 1; }
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

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/hermescall-relay ]]; then
    msg_error "No Hermes Call Relay Installation Found!"
    exit
  fi

  if check_for_gh_release "hermes-call" "Quavon-dev/hermes-call"; then
    fetch_verified_release

    msg_info "Updating Hermes Call Relay"
    $STD /opt/hermes-call/relay/install.sh update
    msg_ok "Updated Hermes Call Relay"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Create a bridge pairing code inside the container with:${CL}"
echo -e "${TAB}${BGN}pct exec ${CTID} -- hermescall-relay pair${CL}"
if [[ ${var_relay_tls:-} == proxy ]]; then
  echo -e "${INFO}${YW}In your reverse proxy: proxy host ${var_relay_address}, scheme http, forward to ${IP} port 8743, Websockets on, SSL + Force SSL.${CL}"
  echo -e "${INFO}${YW}TURN bypasses the proxy: forward TCP/UDP 3478 and UDP 49160-49200 from the router to ${IP}.${CL}"
elif [[ -z ${var_relay_address:-} || ${var_relay_address} =~ ^[0-9.]+$ ]]; then
  echo -e "${INFO}${YW}The relay runs on your public IP. To use a domain instead (Let's Encrypt), point it at your IP, forward TCP 443 and run (then pair the bridge again):${CL}"
  echo -e "${TAB}${BGN}pct exec ${CTID} -- /opt/hermescall-relay/relay/install.sh install --domain relay.example.com --tls acme${CL}"
fi
[[ ${var_relay_tls:-} == proxy ]] || echo -e "${INFO}${YW}Forward only TCP 443, TCP/UDP 3478 and UDP 49160-49200 to ${IP}${CL}"
