#!/usr/bin/env bash
# Hermes Call push gateway installer (Debian 12/13, Ubuntu 24.04), for the app's publisher.
# Relays without their own APNs key send their pushes here; see docs/push-gateway.md.
#
#   push-gateway-install.sh install --domain hermes-push.quavon.de --apns-key AuthKey_X.p8 --apns-key-id X --team-id T
#   push-gateway-install.sh update      redeploy code from this checkout, keep key and settings
#   push-gateway-install.sh block RELAY_ID      takes effect at once (no restart)
#   push-gateway-install.sh unblock RELAY_ID
#   push-gateway-install.sh rotate-apns-key --apns-key AuthKey_Y.p8 --apns-key-id Y
#   push-gateway-install.sh status
#
# Use a dedicated host: it writes /etc/caddy/Caddyfile and needs port 443.
set -Eeuo pipefail

readonly PREFIX=/opt/hermescall-push
readonly ETC=/etc/hermescall-push
readonly SERVICE_USER=hermescall-push
readonly LISTEN_PORT=8744
readonly STATE=/var/lib/hermescall-push
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SRC_ROOT

DOMAIN="" KEY_FILE="" KEY_ID="" TEAM_ID="" BUNDLE_ID="" ACME_EMAIL=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    debian:12 | debian:13 | ubuntu:24.04) ;;
    *) die "unsupported OS ${PRETTY_NAME:-unknown}; need Debian 12/13 or Ubuntu 24.04" ;;
  esac
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN=${2:?}; shift ;;
      --apns-key) KEY_FILE=${2:?}; shift ;;
      --apns-key-id) KEY_ID=${2:?}; shift ;;
      --team-id) TEAM_ID=${2:?}; shift ;;
      --bundle-id) BUNDLE_ID=${2:?}; shift ;;
      --acme-email) ACME_EMAIL=${2:?}; shift ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

load_settings() {
  [[ -f $ETC/install.env ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      DOMAIN | KEY_ID | TEAM_ID | BUNDLE_ID | ACME_EMAIL) [[ -n ${!key} ]] || printf -v "$key" '%s' "$value" ;;
    esac
  done <"$ETC/install.env"
}

validate() {
  [[ -n $BUNDLE_ID ]] || BUNDLE_ID=de.quavon.hermescall
  [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "--domain is required (e.g. hermes-push.quavon.de)"
  [[ $KEY_ID =~ ^[A-Z0-9]{10}$ ]] || die "--apns-key-id: 10 characters"
  [[ $TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || die "--team-id: 10 characters"
  [[ $BUNDLE_ID =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "invalid --bundle-id"
  [[ -z $ACME_EMAIL || $ACME_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "invalid email"
  if [[ -n $KEY_FILE ]]; then
    [[ -r $KEY_FILE ]] || die "cannot read $KEY_FILE"
  else
    [[ -s $ETC/apns_key ]] || die "--apns-key is required on the first install"
  fi
  if grep -q 'Managed by hermes-call relay' /etc/caddy/Caddyfile 2>/dev/null; then
    die "this host runs a Hermes Call relay; install the push gateway on its own host"
  fi
}

install_packages() {
  log "Installing distribution packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 python3-aiohttp python3-httpx python3-h2 \
    python3-cryptography libsodium23 caddy openssl ca-certificates unattended-upgrades >/dev/null
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
  # Checked only now: openssl may be missing on a minimal host before the packages are in.
  if [[ -n $KEY_FILE ]]; then
    openssl pkey -in "$KEY_FILE" -noout -text 2>/dev/null | grep -q 'prime256v1\|P-256' || die "$KEY_FILE is not an APNs .p8 key"
  fi
}

deploy() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC"
  log "Deploying code to $PREFIX"
  rm -rf "$PREFIX.new" && install -d -m 0755 "$PREFIX.new/common" "$PREFIX.new/relay"
  cp -r "$SRC_ROOT/common/hermescall_common" "$PREFIX.new/common/"
  cp -r "$SRC_ROOT/relay/hermescall_relay" "$SRC_ROOT/relay/deploy" "$PREFIX.new/relay/"
  find "$PREFIX.new" -name '__pycache__' -prune -exec rm -rf {} +
  chown -R root:root "$PREFIX.new" && chmod -R u=rwX,go=rX "$PREFIX.new"
  rm -rf "$PREFIX" && mv "$PREFIX.new" "$PREFIX"

  if [[ -n $KEY_FILE ]]; then
    install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" "$KEY_FILE" "$ETC/apns_key"
    log "APNs key stored in $ETC/apns_key; delete your copy at $KEY_FILE or keep it offline"
  fi
  touch "$ETC/blocked_relays"
  chown root:"$SERVICE_USER" "$ETC/blocked_relays" && chmod 0640 "$ETC/blocked_relays"
  write_config
  (umask 077; printf 'DOMAIN=%s\nKEY_ID=%s\nTEAM_ID=%s\nBUNDLE_ID=%s\nACME_EMAIL=%s\n' \
    "$DOMAIN" "$KEY_ID" "$TEAM_ID" "$BUNDLE_ID" "$ACME_EMAIL" >"$ETC/install.env")
}

write_config() {
  # The blocklist file is re-read by the running gateway when it changes (and on SIGHUP).
  cat >"$ETC/gateway.toml" <<EOF
listen_host = "127.0.0.1"
listen_port = $LISTEN_PORT
trust_proxy = true
secrets_dir = "$ETC"
blocklist_path = "$ETC/blocked_relays"
# Replay cache and token bindings survive restarts (systemd StateDirectory).
state_path = "$STATE/gateway.db"

[apns]
key_id = "$KEY_ID"
team_id = "$TEAM_ID"
topic = "$BUNDLE_ID.voip"
EOF
  chown root:"$SERVICE_USER" "$ETC/gateway.toml" && chmod 0640 "$ETC/gateway.toml"
}

write_caddy() {
  [[ -f /etc/caddy/Caddyfile.hermescall-backup || ! -f /etc/caddy/Caddyfile ]] ||
    cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.hermescall-backup
  cat >/etc/caddy/Caddyfile <<EOF
# Managed by hermes-call relay/push-gateway-install.sh
{
	admin off
	auto_https disable_redirects
	servers {
		protocols h1 h2
		timeouts {
			read_header 10s
			idle 2m
		}
	}
}

https://$DOMAIN {
	tls $ACME_EMAIL {
		issuer acme {
			disable_http_challenge
		}
	}
	header -Server
	request_body {
		max_size 16KB
	}
	@push path /v1/push /healthz
	handle @push {
		reverse_proxy 127.0.0.1:$LISTEN_PORT
	}
	handle {
		respond 404
	}
}
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "generated Caddyfile is invalid"
}

start() {
  install -m 0644 "$PREFIX/relay/deploy/hermescall-push.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable hermescall-push.service caddy.service >/dev/null
  systemctl restart hermescall-push.service caddy.service
  for _ in $(seq 1 20); do
    python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$LISTEN_PORT/healthz', timeout=2)" 2>/dev/null &&
      { log "Push gateway running: https://$DOMAIN (topic $BUNDLE_ID); check it from outside: curl https://$DOMAIN/healthz"; return 0; }
    sleep 1
  done
  journalctl -u hermescall-push.service -n 30 --no-pager >&2 || true
  die "push gateway did not become healthy"
}

cmd_install() {
  need_root
  check_os
  load_settings
  validate
  install_packages
  deploy
  write_caddy
  start
}

cmd_block() {
  need_root
  [[ ${1:-} =~ ^[A-Za-z0-9_-]{43}$ ]] || die "usage: block RELAY_ID (43 characters, from the relay's 'hermescall-relay push-id')"
  grep -qxF "$1" "$ETC/blocked_relays" || printf '%s\n' "$1" >>"$ETC/blocked_relays"
  systemctl kill -s HUP hermescall-push.service
  log "Blocked relay ${1:0:6}…"
}

cmd_unblock() {
  need_root
  [[ ${1:-} =~ ^[A-Za-z0-9_-]{43}$ ]] || die "usage: unblock RELAY_ID"
  local kept
  kept=$(grep -vxF "$1" "$ETC/blocked_relays" || true)
  printf '%s\n' "$kept" | sed '/^$/d' >"$ETC/blocked_relays"
  systemctl kill -s HUP hermescall-push.service
  log "Unblocked relay ${1:0:6}…"
}

# A new .p8 (e.g. the old one leaked or is being retired): swap it without losing pushes.
cmd_rotate_apns_key() {
  need_root
  load_settings
  [[ -n $KEY_FILE ]] || die "usage: rotate-apns-key --apns-key FILE --apns-key-id ID"
  validate
  openssl pkey -in "$KEY_FILE" -noout -text 2>/dev/null | grep -q 'prime256v1\|P-256' || die "$KEY_FILE is not an APNs .p8 key"
  install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" "$KEY_FILE" "$ETC/apns_key"
  write_config
  (umask 077; printf 'DOMAIN=%s\nKEY_ID=%s\nTEAM_ID=%s\nBUNDLE_ID=%s\nACME_EMAIL=%s\n' \
    "$DOMAIN" "$KEY_ID" "$TEAM_ID" "$BUNDLE_ID" "$ACME_EMAIL" >"$ETC/install.env")
  systemctl restart hermescall-push.service
  log "APNs key $KEY_ID in use. Revoke the old key at developer.apple.com once pushes arrive."
}

cmd_uninstall() {
  need_root
  systemctl disable --now hermescall-push.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hermescall-push.service
  systemctl daemon-reload
  rm -rf "$PREFIX"
  if [[ -f /etc/caddy/Caddyfile.hermescall-backup ]]; then
    mv /etc/caddy/Caddyfile.hermescall-backup /etc/caddy/Caddyfile
    systemctl restart caddy.service 2>/dev/null || true
  fi
  log "Removed the push gateway. Kept $ETC (APNs key, settings, blocked relays) and $STATE: delete them yourself when done."
}

main() {
  local command=${1:-install}
  [[ $# -eq 0 ]] || shift
  case "$command" in
    install | update) parse_flags "$@"; cmd_install ;;
    block) cmd_block "$@" ;;
    unblock) cmd_unblock "$@" ;;
    rotate-apns-key) parse_flags "$@"; cmd_rotate_apns_key ;;
    status) systemctl --no-pager status hermescall-push.service caddy.service ;;
    uninstall) cmd_uninstall ;;
    *) die "usage: push-gateway-install.sh install|update|block RELAY_ID|unblock RELAY_ID|rotate-apns-key|status|uninstall [options]" ;;
  esac
}

main "$@"
