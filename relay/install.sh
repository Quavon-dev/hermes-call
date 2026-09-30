#!/usr/bin/env bash
# Hermes Call relay installer for Debian 12/13 and Ubuntu 24.04.
#
#   install.sh [install]        install or reconfigure (idempotent)
#   install.sh update           redeploy code from this checkout, keep settings and data
#   install.sh rollback         go back to the code before the last update
#   install.sh backup [FILE]    archive database, config and keys (mode 600)
#   install.sh restore FILE     restore such an archive (also on a fresh host)
#   install.sh rotate turn-secret|push-key|apns-key
#   install.sh uninstall [--purge]
#   install.sh pair             print a new one-time bridge pairing code
#   install.sh status
#
# Every prompt can be answered up front (flags or HC_* environment variables);
# --non-interactive fails instead of prompting.
set -Eeuo pipefail

readonly PREFIX=/opt/hermescall-relay
readonly ETC=/etc/hermescall-relay
readonly SETTINGS=$ETC/install.env
readonly CADDY_TLS=/etc/caddy/hermescall
# In /usr/local/bin so `pct exec <id> -- hermescall-relay pair` finds it (no login shell, no sbin
# in PATH); the old sbin path stays as a link.
readonly WRAPPER=/usr/local/bin/hermescall-relay
readonly OLD_WRAPPER=/usr/local/sbin/hermescall-relay
readonly SERVICE_USER=hermescall-relay
readonly LISTEN_PORT=8743
readonly TURN_PORT=3478
readonly TURNS_PORT=5349
readonly DATA=/var/lib/hermescall-relay
# TURN credentials outlive the longest call (60 min) plus ringing and ICE restarts.
readonly TURN_TTL=5400
readonly UNITS=(hermescall-relay.service hermescall-turn.service)
readonly DEFAULT_PUSH_GATEWAY=https://hermes-push.quavon.de
readonly SETTING_KEYS=(HC_DOMAIN HC_IP HC_TLS HC_ACME_EMAIL HC_APNS HC_APNS_KEY_ID HC_TEAM_ID HC_BUNDLE_ID HC_PUSH_GATEWAY HC_PROXY_FROM HC_EXTERNAL_IP HC_FIREWALL HC_HARDEN_SSH HC_TURN_PORTS HC_TURN_QUOTA HC_TURNS)
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SRC_ROOT

HC_DOMAIN=${HC_DOMAIN:-}
HC_IP=${HC_IP:-}
HC_TLS=${HC_TLS:-}
HC_PROXY_FROM=${HC_PROXY_FROM:-}
HC_ACME_EMAIL=${HC_ACME_EMAIL:-}
HC_APNS=${HC_APNS:-}
HC_APNS_KEY_FILE=${HC_APNS_KEY_FILE:-}
HC_APNS_KEY_ID=${HC_APNS_KEY_ID:-}
HC_TEAM_ID=${HC_TEAM_ID:-}
HC_BUNDLE_ID=${HC_BUNDLE_ID:-}
HC_PUSH_GATEWAY=${HC_PUSH_GATEWAY:-}
HC_EXTERNAL_IP=${HC_EXTERNAL_IP:-}
HC_FIREWALL=${HC_FIREWALL:-}
HC_HARDEN_SSH=${HC_HARDEN_SSH:-}
HC_TURN_PORTS=${HC_TURN_PORTS:-}
HC_TURN_QUOTA=${HC_TURN_QUOTA:-}
HC_TURNS=${HC_TURNS:-}
INTERACTIVE=1
PURGE=0
RESTORE_DB=0
ALLOW_DOWNGRADE=${HC_ALLOW_DOWNGRADE:-0}
TURN_MIN_PORT=49160
TURN_MAX_PORT=49200

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [install|update|rollback|backup|restore|rotate|uninstall|pair|status] [options]

  --domain NAME          public DNS name of the relay (Let's Encrypt via TLS-ALPN on 443)
  --ip ADDRESS           public IP instead of a domain (self-signed certificate + pin)
  --address VALUE        domain or IP, detected automatically
  --tls acme|self-signed|proxy
                         TLS mode (default: acme for --domain, self-signed for --ip); proxy = an
                         external reverse proxy (NPM, Traefik, Caddy) terminates TLS for --domain
                         and forwards to http://<this host>:8743
  --proxy-from CIDRS     proxy mode: addresses of the reverse proxy, comma-separated (default: the
                         private ranges); only they reach port 8743, only their X-Forwarded-For counts
  --acme-email EMAIL     optional contact address for Let's Encrypt
  --apns-key FILE        your own APNs auth key (.p8); only for your own build of the app
  --apns-key-id ID       10-character APNs key ID
  --team-id ID           10-character Apple Team ID
  --bundle-id ID         iOS app bundle ID (default de.quavon.hermescall)
  --no-apns              no own APNs key: pushes go through the push gateway (default)
  --push-gateway URL     push gateway for relays without an own key ("default" = $DEFAULT_PUSH_GATEWAY;
                         new installs use it; relays installed before it existed keep pushes off
                         until you pass this flag)
  --no-push-gateway      no pushes at all: incoming calls ring only while the app is open
  --external-ip ADDRESS  public IP when the relay sits behind NAT (auto-detected)
  --turn-ports MIN-MAX   UDP ports for relayed media (default 49160-49200, 2 per call)
  --turn-quota N         concurrent TURN allocations in total (default 100)
  --turns                also offer TURN over TLS on 5349/tcp (needs --tls acme): gets calls
                         through networks that allow only TLS; --no-turns turns it off again
  --no-firewall          do not manage nftables (e.g. Proxmox firewall does it)
  --harden-ssh           disable SSH password logins (requires an authorized key)
  --non-interactive      never prompt; fail on missing settings
  --purge                with uninstall: also delete keys, config and database
  --restore-db           with rollback: also restore the database snapshot taken before the update
  --allow-downgrade      with update: allow code older than the installed version (or HC_ALLOW_DOWNGRADE=1)
EOF
}

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
      --domain) HC_DOMAIN=${2:?}; shift ;;
      --ip) HC_IP=${2:?}; shift ;;
      --address) if is_ip "${2:?}"; then HC_IP=$2; else HC_DOMAIN=${2,,}; fi; shift ;;
      --tls) HC_TLS=${2:?}; shift ;;
      --proxy-from) HC_PROXY_FROM=${2:?}; shift ;;
      --acme-email) HC_ACME_EMAIL=${2:?}; shift ;;
      --apns-key) HC_APNS_KEY_FILE=${2:?}; HC_APNS=yes; shift ;;
      --apns-key-id) HC_APNS_KEY_ID=${2:?}; shift ;;
      --team-id) HC_TEAM_ID=${2:?}; shift ;;
      --bundle-id) HC_BUNDLE_ID=${2:?}; shift ;;
      --no-apns) HC_APNS=no ;;
      --push-gateway) HC_PUSH_GATEWAY=${2:?}; [[ $HC_PUSH_GATEWAY != default ]] || HC_PUSH_GATEWAY=$DEFAULT_PUSH_GATEWAY; shift ;;
      --no-push-gateway) HC_PUSH_GATEWAY=no ;;
      --external-ip) HC_EXTERNAL_IP=${2:?}; shift ;;
      --turn-ports) HC_TURN_PORTS=${2:?}; shift ;;
      --turn-quota) HC_TURN_QUOTA=${2:?}; shift ;;
      --turns) HC_TURNS=yes ;;
      --no-turns) HC_TURNS=no ;;
      --restore-db) RESTORE_DB=1 ;;
      --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
      --no-firewall) HC_FIREWALL=no ;;
      --harden-ssh) HC_HARDEN_SSH=yes ;;
      --non-interactive) INTERACTIVE=0 ;;
      --purge) PURGE=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -t 0 ]] || INTERACTIVE=0
}

load_settings() {
  [[ -f $SETTINGS ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ " ${SETTING_KEYS[*]} " == *" $key "* ]] || continue
    [[ -n ${!key} ]] || printf -v "$key" '%s' "$value"
  done <"$SETTINGS"
}

save_settings() (
  local key
  umask 077
  : >"$SETTINGS"
  for key in "${SETTING_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "${!key}" >>"$SETTINGS"
  done
)

ask() {
  local var=$1 prompt=$2 default=${3:-}
  [[ -n ${!var} ]] && return 0
  if [[ $INTERACTIVE -eq 0 ]]; then
    [[ -n $default ]] && { printf -v "$var" '%s' "$default"; return 0; }
    die "missing setting ${var} (pass it as a flag or environment variable)"
  fi
  local answer
  read -r -p "$prompt${default:+ [$default]}: " answer
  printf -v "$var" '%s' "${answer:-$default}"
}

is_ipv4() {
  local IFS=. octet
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for octet in $1; do ((10#$octet <= 255)) || return 1; done
}
is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]{2,45}$ ]]; }
is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_domain() { [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

collect_settings() {
  if [[ -z $HC_DOMAIN && -z $HC_IP ]]; then
    local target=""
    ask target "Public domain name (recommended) or public IP of this relay"
    if is_ip "$target"; then HC_IP=$target; else HC_DOMAIN=${target,,}; fi
  fi
  [[ -z $HC_DOMAIN ]] || is_domain "$HC_DOMAIN" || die "invalid domain: $HC_DOMAIN"
  [[ -z $HC_IP ]] || is_ip "$HC_IP" || die "invalid IP address: $HC_IP"
  [[ -n $HC_TLS ]] || { [[ -n $HC_DOMAIN ]] && HC_TLS=acme || HC_TLS=self-signed; }
  [[ $HC_TLS == acme || $HC_TLS == self-signed || $HC_TLS == proxy ]] || die "--tls must be acme, self-signed or proxy"
  [[ $HC_TLS == self-signed || -n $HC_DOMAIN ]] || die "--tls $HC_TLS needs a domain; use --tls self-signed with --ip"
  if [[ $HC_TLS == proxy ]]; then
    [[ -n $HC_PROXY_FROM ]] || HC_PROXY_FROM=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7
    local net
    for net in ${HC_PROXY_FROM//,/ }; do
      [[ $net =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || die "invalid --proxy-from entry: $net"
    done
  fi
  [[ -z $HC_ACME_EMAIL || $HC_ACME_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "invalid email"

  if [[ -z $HC_APNS ]]; then
    ask HC_APNS "Use your own APNs key? Only needed for your own build of the app; 'no' uses the Hermes Call push service (yes/no)" no
  fi
  if [[ $HC_APNS == yes ]]; then
    if [[ ! -s $ETC/apns_key || -n $HC_APNS_KEY_FILE ]]; then
      ask HC_APNS_KEY_FILE "Path to APNs auth key (.p8)"
    fi
    ask HC_APNS_KEY_ID "APNs Key ID (10 characters)"
    ask HC_TEAM_ID "Apple Team ID (10 characters)"
    ask HC_BUNDLE_ID "iOS bundle ID" de.quavon.hermescall
    [[ $HC_APNS_KEY_ID =~ ^[A-Z0-9]{10}$ ]] || die "invalid APNs Key ID"
    [[ $HC_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || die "invalid Team ID"
    [[ $HC_BUNDLE_ID =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "invalid bundle ID"
    if [[ -n $HC_APNS_KEY_FILE ]]; then
      [[ -r $HC_APNS_KEY_FILE ]] || die "cannot read $HC_APNS_KEY_FILE"
      openssl pkey -in "$HC_APNS_KEY_FILE" -noout -text 2>/dev/null | grep -q 'prime256v1\|P-256' ||
        die "$HC_APNS_KEY_FILE is not an APNs ES256 (.p8) key"
    fi
  elif [[ $HC_APNS != no ]]; then
    die "answer yes or no for APNs"
  fi
  if [[ -z $HC_PUSH_GATEWAY ]]; then
    if [[ ! -f $SETTINGS || $HC_APNS == yes ]]; then
      HC_PUSH_GATEWAY=$DEFAULT_PUSH_GATEWAY
    else
      # Installed before the push gateway existed: that relay sent no pushes. Keep it that way
      # unless the owner opts in; the gateway sees push tokens and timing (docs/push-gateway.md).
      ask HC_PUSH_GATEWAY "Send pushes through the Hermes Call push gateway ($DEFAULT_PUSH_GATEWAY)? It sees push tokens and timing, never content (yes/no)" no
      case "$HC_PUSH_GATEWAY" in
        yes) HC_PUSH_GATEWAY=$DEFAULT_PUSH_GATEWAY ;;
        no) log "Pushes stay off. To use the push gateway: install.sh update --push-gateway default" ;;
      esac
    fi
  fi
  [[ $HC_PUSH_GATEWAY == no || $HC_PUSH_GATEWAY =~ ^https://[A-Za-z0-9.:/_-]{1,190}$ ]] || die "--push-gateway must be an https URL"
  [[ -z $HC_EXTERNAL_IP ]] || is_ipv4 "$HC_EXTERNAL_IP" || die "invalid --external-ip"
  collect_turn_settings
  [[ -n $HC_FIREWALL ]] || HC_FIREWALL=yes
  [[ -n $HC_HARDEN_SSH ]] || HC_HARDEN_SSH=no
}

collect_turn_settings() {
  [[ -n $HC_TURN_PORTS ]] || HC_TURN_PORTS=49160-49200
  [[ $HC_TURN_PORTS =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || die "--turn-ports must look like 49160-49200"
  TURN_MIN_PORT=${BASH_REMATCH[1]} TURN_MAX_PORT=${BASH_REMATCH[2]}
  ((TURN_MIN_PORT >= 1024 && TURN_MAX_PORT <= 65535 && TURN_MAX_PORT - TURN_MIN_PORT >= 1)) ||
    die "--turn-ports: two or more ports between 1024 and 65535"
  [[ -n $HC_TURN_QUOTA ]] || HC_TURN_QUOTA=100
  [[ $HC_TURN_QUOTA =~ ^[1-9][0-9]{0,4}$ ]] || die "--turn-quota must be a number"
  [[ -n $HC_TURNS ]] || HC_TURNS=no
  [[ $HC_TURNS == no || $HC_TLS == acme ]] || die "--turns needs --tls acme (a certificate that phones trust)"
}

host() { printf '%s' "${HC_DOMAIN:-$HC_IP}"; }
url_host() { if [[ $(host) == *:* ]]; then printf '[%s]' "$(host)"; else host; fi; }

install_packages() {
  log "Installing distribution packages (security updates via unattended-upgrades)"
  local packages=(python3 python3-aiohttp python3-httpx python3-h2 python3-cryptography libsodium23
    caddy coturn qrencode openssl ca-certificates nftables unattended-upgrades iproute2)
  has_sshd && packages+=(fail2ban python3-systemd)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${packages[@]}" >/dev/null
  systemctl disable --now coturn.service >/dev/null 2>&1 || true
  systemctl mask coturn.service >/dev/null 2>&1 || true
}

has_sshd() { command -v sshd >/dev/null 2>&1; }

create_user() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0755 -o root -g root "$ETC"
}

deploy_code() {
  log "Deploying relay code to $PREFIX"
  local staging
  staging=$(mktemp -d "${PREFIX}.new.XXXXXX")
  install -d -m 0755 "$staging/common" "$staging/relay"
  cp -r "$SRC_ROOT/common/hermescall_common" "$staging/common/"
  cp -r "$SRC_ROOT/relay/hermescall_relay" "$SRC_ROOT/relay/deploy" "$SRC_ROOT/relay/install.sh" "$staging/relay/"
  find "$staging" -name '__pycache__' -prune -exec rm -rf {} +
  chown -R root:root "$staging"
  find "$staging" -type d -exec chmod 0755 {} + && find "$staging" -type f -exec chmod 0644 {} +
  chmod 0755 "$staging/relay/install.sh"
  write_version_file "$staging/VERSION"
  # The previous code stays as ${PREFIX}.old for `install.sh rollback` -- unless this is the same
  # build again (a retried or repeated update), which must not replace the real previous version.
  if [[ -d $PREFIX ]] && [[ $(build_of "$PREFIX") == "$(build_of "$staging")" ]]; then
    rm -rf "$PREFIX"
  elif [[ -d $PREFIX ]]; then
    rm -rf "${PREFIX}.old"
    mv "$PREFIX" "${PREFIX}.old"
  fi
  mv "$staging" "$PREFIX"
  write_wrapper
}

# "version commit" of an installed tree (empty before 0.7).
build_of() {
  [[ -f $1/VERSION ]] || return 0
  sed -n 's/^version=//p; s/^commit=//p' "$1/VERSION" | paste -sd' ' -
}

source_version() { sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$SRC_ROOT/relay/hermescall_relay/version.py"; }

write_version_file() {
  local version commit
  version=$(source_version)
  # A git checkout knows its commit; a release tarball carries it in RELEASE (tools/release.sh).
  commit=$(git -C "$SRC_ROOT" rev-parse --short=12 HEAD 2>/dev/null ||
    sed -n 's/^commit=\([0-9a-f]\{12\}\).*/\1/p' "$SRC_ROOT/RELEASE" 2>/dev/null || true)
  printf 'version=%s\ncommit=%s\ninstalled=%s\n' "${version:-unknown}" "${commit:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$1"
  chmod 0644 "$1"
}

write_wrapper() {
  cat >"$WRAPPER" <<EOF
#!/bin/sh
set -eu
# pct exec and cron run without a login shell: runuser lives in /usr/sbin.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "\$(id -u)" -eq 0 ] || { echo "hermescall-relay: run as root" >&2; exit 1; }
cd /
exec runuser -u $SERVICE_USER -- env PYTHONPATH=$PREFIX/common:$PREFIX/relay PYTHONDONTWRITEBYTECODE=1 \\
  python3 -m hermescall_relay.cli "\$@"
EOF
  chmod 0755 "$WRAPPER"
  ln -sfn "$WRAPPER" "$OLD_WRAPPER"
}

# Runs the relay CLI as root (backup/restore need the root-owned config and the TLS key).
relay_cli_as_root() {
  env PYTHONPATH="$PREFIX/common:$PREFIX/relay" PYTHONDONTWRITEBYTECODE=1 python3 -m hermescall_relay.cli "$@"
}

write_secret() (
  local path=$1 owner=$2
  umask 077
  cat >"$path.tmp"
  chmod 0600 "$path.tmp"
  chown "$owner:$owner" "$path.tmp"
  mv "$path.tmp" "$path"
)

write_secrets() {
  [[ -s $ETC/turn_secret ]] || openssl rand -hex 32 | write_secret "$ETC/turn_secret" "$SERVICE_USER"
  # The relay's identity at the push gateway (signs its push requests; never leaves this host).
  [[ -s $ETC/push_gateway_key ]] || openssl genpkey -algorithm ed25519 | write_secret "$ETC/push_gateway_key" "$SERVICE_USER"
  if [[ $HC_APNS == yes && -n $HC_APNS_KEY_FILE ]]; then
    write_secret "$ETC/apns_key" "$SERVICE_USER" <"$HC_APNS_KEY_FILE"
    log "APNs key stored in $ETC/apns_key (mode 600). You may delete your copy at $HC_APNS_KEY_FILE."
  fi
  chown "$SERVICE_USER:$SERVICE_USER" "$ETC/turn_secret"
  [[ ! -e $ETC/apns_key ]] || chown "$SERVICE_USER:$SERVICE_USER" "$ETC/apns_key"
  chown "$SERVICE_USER:$SERVICE_USER" "$ETC/push_gateway_key"
}

setup_tls() {
  TLS_PIN=""
  [[ $HC_TLS == self-signed ]] || return 0  # acme: Caddy's certificate; proxy: the proxy's
  install -d -m 0750 -o root -g caddy "$CADDY_TLS"
  local san
  if is_ip "$(host)"; then san="IP:$(host)"; else san="DNS:$(host)"; fi
  if [[ ! -s $CADDY_TLS/key.pem ]] || ! openssl x509 -in "$CADDY_TLS/cert.pem" -noout -ext subjectAltName 2>/dev/null |
    tr ',' '\n' | sed 's/^ *//' | grep -qxF -e "DNS:$(host)" -e "IP Address:$(host)"; then
    log "Generating long-lived self-signed certificate (the app pins its public key)"
    ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$CADDY_TLS/key.pem" )
    openssl req -x509 -new -key "$CADDY_TLS/key.pem" -out "$CADDY_TLS/cert.pem" -days 3650 -subj "/CN=hermes-call-relay" \
      -addext "subjectAltName=$san" -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
  fi
  chown caddy:caddy "$CADDY_TLS/key.pem" "$CADDY_TLS/cert.pem"
  chmod 0600 "$CADDY_TLS/key.pem"
  chmod 0644 "$CADDY_TLS/cert.pem"
  TLS_PIN=$(openssl pkey -in "$CADDY_TLS/key.pem" -pubout -outform DER | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
}

# Proxy mode: the reverse proxy's addresses as a TOML list ("a", "b"), else empty.
proxy_list() {
  [[ $HC_TLS == proxy ]] || return 0
  local net out=""
  for net in ${HC_PROXY_FROM//,/ }; do out+="${out:+, }\"$net\""; done
  printf '%s' "$out"
}

write_relay_config() {
  local apns_enabled=false
  [[ $HC_APNS == yes ]] && apns_enabled=true
  cat >"$ETC/relay.toml.tmp" <<EOF
authority = "$(url_host)"
tls_pin = "$TLS_PIN"
listen_host = "$([[ $HC_TLS == proxy ]] && echo 0.0.0.0 || echo 127.0.0.1)"
listen_port = $LISTEN_PORT
db_path = "/var/lib/hermescall-relay/relay.db"
trust_proxy = true
trusted_proxies = [$(proxy_list)]

[turn]
urls = [$(turn_urls)]
ttl = $TURN_TTL

[apns]
enabled = $apns_enabled
key_id = "$HC_APNS_KEY_ID"
team_id = "$HC_TEAM_ID"
topic = "${HC_BUNDLE_ID}.voip"

[push_gateway]
enabled = $([[ $HC_PUSH_GATEWAY == no ]] && echo false || echo true)
url = "$([[ $HC_PUSH_GATEWAY == no ]] && echo "$DEFAULT_PUSH_GATEWAY" || echo "$HC_PUSH_GATEWAY")"
EOF
  chmod 0644 "$ETC/relay.toml.tmp"
  mv "$ETC/relay.toml.tmp" "$ETC/relay.toml"
  [[ ! -f $ETC/relay.local.toml ]] || log "Your own settings in $ETC/relay.local.toml apply on top (kept on updates)"
}

turn_urls() {
  printf '"turn:%s:%s?transport=udp", "turn:%s:%s?transport=tcp"' "$(url_host)" "$TURN_PORT" "$(url_host)" "$TURN_PORT"
  [[ $HC_TURNS != yes ]] || printf ', "turns:%s:%s?transport=tcp"' "$(url_host)" "$TURNS_PORT"
}

public_ipv4() {
  if [[ -n $HC_EXTERNAL_IP ]]; then printf '%s' "$HC_EXTERNAL_IP"; return; fi
  if [[ -n $HC_IP ]]; then printf '%s' "$HC_IP"; return; fi
  getent ahostsv4 "$HC_DOMAIN" | awk 'NR==1 {print $1}'
}

local_ipv4() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}'; }

nat_mapping() {
  local public private
  public=$(public_ipv4)
  private=$(local_ipv4)
  [[ -n $public && -n $private ]] || return 0
  ip -4 -o addr show | grep -qw "inet $public" && return 0
  printf '%s/%s' "$public" "$private"
}

write_turn_config() {
  local mapping
  mapping=$(nat_mapping)
  {
    cat <<EOF
listening-port=$TURN_PORT
realm=$(host)
use-auth-secret
static-auth-secret=$(cat "$ETC/turn_secret")
fingerprint
$(turn_tls_lines)
no-dtls
no-tcp-relay
no-cli
no-multicast-peers
no-software-attribute
no-rfc5780
alt-listening-port=0
no-stun-backward-compatibility
response-origin-only-with-rfc5780
min-port=$TURN_MIN_PORT
max-port=$TURN_MAX_PORT
total-quota=$HC_TURN_QUOTA
user-quota=12
max-bps=64000
stale-nonce=600
simple-log
log-file=stdout
pidfile=/run/hermescall-turn/turnserver.pid
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=::1
denied-peer-ip=fec0::-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=2001::-2001:0:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=64:ff9b:1::-64:ff9b:1:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255
denied-peer-ip=2002::-2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
EOF
    [[ -z $mapping ]] || printf 'external-ip=%s\n' "$mapping"
  } | write_secret "$ETC/turnserver.conf" turnserver
  if [[ -n $mapping ]]; then
    log "Relay is behind NAT; TURN advertises ${mapping%%/*}"
  fi
}

readonly TURN_TLS=$ETC/turn-tls

turn_tls_lines() {
  if [[ $HC_TURNS != yes || ! -s $TURN_TLS/cert.pem ]]; then
    echo no-tls
    return
  fi
  cat <<EOF
tls-listening-port=$TURNS_PORT
cert=$TURN_TLS/cert.pem
pkey=$TURN_TLS/key.pem
no-tlsv1
no-tlsv1_1
EOF
}

# The ACME certificate Caddy keeps for the domain (any issuer directory).
caddy_cert() {
  { find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$HC_DOMAIN.$1" 2>/dev/null || true; } | head -n 1
}

# TURNS uses Caddy's certificate; coturn gets its own copy (it runs as another user). Run before
# coturn starts and daily by a timer: a renewed certificate is copied and coturn restarted.
cmd_turn_cert() {
  need_root
  load_settings
  [[ ${HC_TURNS:-no} == yes ]] || return 0
  local cert key
  cert=$(caddy_cert crt) key=$(caddy_cert key)
  if [[ -z $cert || -z $key ]]; then
    warn "no certificate for $HC_DOMAIN from Caddy yet; TURNS starts once Caddy has one"
    return 0
  fi
  install -d -m 0750 -o root -g turnserver "$TURN_TLS"
  if ! cmp -s "$cert" "$TURN_TLS/cert.pem" || ! cmp -s "$key" "$TURN_TLS/key.pem"; then
    install -m 0644 -o root -g turnserver "$cert" "$TURN_TLS/cert.pem"
    install -m 0640 -o root -g turnserver "$key" "$TURN_TLS/key.pem"
    collect_turn_settings
    write_turn_config
    systemctl try-restart hermescall-turn.service
    log "TURNS certificate updated"
  fi
}

write_caddy_config() {
  local site tls_line global_extra=""
  if [[ $HC_TLS == proxy ]]; then
    # The external proxy terminates TLS; the relay listens itself (only for the proxy, see firewall).
    systemctl disable --now caddy.service >/dev/null 2>&1 || true
    return 0
  fi
  [[ -f /etc/caddy/Caddyfile.hermescall-backup || ! -f /etc/caddy/Caddyfile ]] ||
    cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.hermescall-backup
  site="https://$(url_host)"
  if [[ $HC_TLS == acme ]]; then
    tls_line="tls ${HC_ACME_EMAIL} {
		issuer acme {
			disable_http_challenge
		}
	}"
  else
    tls_line="tls $CADDY_TLS/cert.pem $CADDY_TLS/key.pem"
    global_extra="	default_sni $(host)"
  fi
  cat >/etc/caddy/Caddyfile.tmp <<EOF
# Managed by hermes-call relay/install.sh
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
$global_extra
}

$site {
	$tls_line
	header -Server
	request_body {
		max_size 11MB
	}
	reverse_proxy 127.0.0.1:$LISTEN_PORT
}
EOF
  caddy validate --config /etc/caddy/Caddyfile.tmp --adapter caddyfile >/dev/null 2>&1 ||
    { rm -f /etc/caddy/Caddyfile.tmp; die "generated Caddyfile is invalid"; }
  chmod 0644 /etc/caddy/Caddyfile.tmp
  mv /etc/caddy/Caddyfile.tmp /etc/caddy/Caddyfile
  install -d -m 0755 /etc/systemd/system/caddy.service.d
  install -m 0644 "$PREFIX/relay/deploy/caddy-override/hermescall.conf" /etc/systemd/system/caddy.service.d/hermescall.conf
}

install_units() {
  local unit
  for unit in "${UNITS[@]}"; do
    install -m 0644 "$PREFIX/relay/deploy/$unit" "/etc/systemd/system/$unit"
  done
  if [[ $HC_TURNS == yes ]]; then
    install -m 0644 "$PREFIX/relay/deploy/hermescall-turn-cert.service" /etc/systemd/system/
    install -m 0644 "$PREFIX/relay/deploy/hermescall-turn-cert.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now hermescall-turn-cert.timer >/dev/null
  else
    systemctl disable --now hermescall-turn-cert.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/hermescall-turn-cert.{service,timer}
  fi
  if [[ -n $(nat_mapping) && -n $HC_DOMAIN && -z $HC_EXTERNAL_IP ]]; then
    install -m 0644 "$PREFIX/relay/deploy/hermescall-ip-refresh.service" /etc/systemd/system/
    install -m 0644 "$PREFIX/relay/deploy/hermescall-ip-refresh.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now hermescall-ip-refresh.timer >/dev/null
  fi
  systemctl daemon-reload
}

# SSH ports from sshd's config and, on Ubuntu 24.04 (socket activation), from ssh.socket, which
# may listen elsewhere than sshd -T reports.
ssh_ports() {
  install -d -m 0755 /run/sshd
  {
    { sshd -T 2>/dev/null || true; } | awk '$1 == "port" {print $2}'
    { systemctl show -p Listen --value ssh.socket 2>/dev/null || true; } | tr ' ' '\n' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'
  } | sort -un | paste -sd, -
}

setup_firewall() {
  [[ $HC_FIREWALL == yes ]] || { warn "firewall management disabled; open only the ports listed in docs"; return 0; }
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "ufw is active; adding relay rules to it"
    if [[ $HC_TLS == proxy ]]; then
      local net
      for net in ${HC_PROXY_FROM//,/ }; do ufw allow from "$net" to any port "$LISTEN_PORT" proto tcp >/dev/null; done
    else
      ufw allow 443/tcp >/dev/null
    fi
    ufw allow "$TURN_PORT" >/dev/null
    ufw allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp" >/dev/null
    [[ $HC_TURNS != yes ]] || ufw allow "$TURNS_PORT/tcp" >/dev/null
    return 0
  fi
  log "Configuring nftables (default deny inbound)"
  local ports="" ssh_rule=""
  if has_sshd; then
    ports=$(ssh_ports)
    [[ -n $ports ]] || die "could not determine the SSH port (sshd -T failed); refusing to enable a firewall that could lock you out"
  fi
  [[ -z $ports ]] || ssh_rule="tcp dport { $ports } ct state new limit rate 30/minute accept"
  local signaling_rule="tcp dport 443 accept" turns_rule="" v4="" v6="" net
  [[ $HC_TURNS != yes ]] || turns_rule="tcp dport $TURNS_PORT accept"
  if [[ $HC_TLS == proxy ]]; then
    # Only the reverse proxy reaches the relay's plain-HTTP port.
    for net in ${HC_PROXY_FROM//,/ }; do
      if [[ $net == *:* ]]; then v6+="${v6:+, }$net"; else v4+="${v4:+, }$net"; fi
    done
    signaling_rule=""
    [[ -z $v4 ]] || signaling_rule="ip saddr { $v4 } tcp dport $LISTEN_PORT accept"
    [[ -z $v6 ]] || signaling_rule+="${signaling_rule:+$'\n\t\t'}ip6 saddr { $v6 } tcp dport $LISTEN_PORT accept"
  fi
  [[ -f /etc/nftables.conf.hermescall-backup || ! -f /etc/nftables.conf ]] ||
    cp -p /etc/nftables.conf /etc/nftables.conf.hermescall-backup
  cat >/etc/nftables.conf.tmp <<EOF
#!/usr/sbin/nft -f
# Managed by hermes-call relay/install.sh
# Only our own table is replaced; other tables (e.g. Docker's) are left alone.
table inet hermescall {}
delete table inet hermescall

table inet hermescall {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		ct state invalid drop
		meta l4proto icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } limit rate 10/second accept
		meta l4proto ipv6-icmp accept
		$ssh_rule
		$signaling_rule
		meta l4proto { tcp, udp } th dport $TURN_PORT accept
		$turns_rule
		udp dport $TURN_MIN_PORT-$TURN_MAX_PORT accept
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
	}
}
EOF
  nft -c -f /etc/nftables.conf.tmp || die "nftables ruleset failed validation"
  mv /etc/nftables.conf.tmp /etc/nftables.conf
  chmod 0755 /etc/nftables.conf
  if ! systemctl enable --now nftables.service >/dev/null 2>&1 || ! nft -f /etc/nftables.conf 2>/dev/null; then
    warn "could not load nftables here (unprivileged container?); use the Proxmox firewall instead (see docs)"
  fi
}

setup_fail2ban() {
  has_sshd || return 0
  cat >/etc/fail2ban/jail.d/hermescall.local <<'EOF'
[DEFAULT]
backend = systemd
banaction = nftables-multiport
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "fail2ban did not start"
}

setup_unattended_upgrades() {
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

harden_ssh() {
  [[ $HC_HARDEN_SSH == yes ]] && has_sshd || return 0
  if ! compgen -G '/root/.ssh/authorized_keys' >/dev/null && ! compgen -G '/home/*/.ssh/authorized_keys' >/dev/null; then
    warn "no authorized_keys found; NOT disabling SSH passwords (you would be locked out)"
    return 0
  fi
  cat >/etc/ssh/sshd_config.d/00-hermescall.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t || { rm -f /etc/ssh/sshd_config.d/00-hermescall.conf; die "sshd rejected the hardening drop-in"; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  log "SSH: key-only login enabled"
}

start_services() {
  log "Starting services"
  if [[ $HC_TLS == proxy ]]; then
    systemctl enable "${UNITS[@]}" >/dev/null
    systemctl restart hermescall-turn.service hermescall-relay.service
  else
    systemctl enable "${UNITS[@]}" caddy.service >/dev/null
    systemctl restart hermescall-turn.service hermescall-relay.service caddy.service
  fi

  for _ in $(seq 1 30); do
    if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$LISTEN_PORT/healthz', timeout=2)" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  journalctl -u hermescall-relay.service -n 30 --no-pager >&2 || true
  die "relay did not become healthy"
}

signaling_summary() {
  if [[ $HC_TLS == proxy ]]; then
    printf '%s/tcp (plain HTTP, only from %s, behind your reverse proxy)' "$LISTEN_PORT" "$HC_PROXY_FROM"
  else
    printf '443/tcp (TLS signaling)'
  fi
}

push_summary() {
  if [[ $HC_APNS == yes ]]; then
    echo "own APNs key (sandbox + production)"
  elif [[ $HC_PUSH_GATEWAY != no ]]; then
    echo "via $HC_PUSH_GATEWAY (relay id $("$WRAPPER" push-id 2>/dev/null || echo unknown))"
  else
    echo "disabled (incoming calls ring only while the app is open)"
  fi
}

print_summary() {
  cat <<EOF

Hermes Call relay is running for $(url_host).
Open ports: $(signaling_summary), $TURN_PORT/udp+tcp (TURN)$([[ $HC_TURNS != yes ]] || printf ', %s/tcp (TURNS)' "$TURNS_PORT"), $TURN_MIN_PORT-$TURN_MAX_PORT/udp (TURN media relay)$(if has_sshd; then printf ', SSH'; fi)
Push: $(push_summary)
EOF
  if [[ $HC_TLS == proxy ]]; then
    cat <<EOF

Reverse proxy (e.g. Nginx Proxy Manager): a proxy host for $(host) with scheme http, forward
host $(local_ipv4), port $LISTEN_PORT, Websockets Support on, an SSL certificate for $(host) and
Force SSL. TURN does not go through the proxy: forward $TURN_PORT/udp+tcp and
$TURN_MIN_PORT-$TURN_MAX_PORT/udp from the router straight to $(local_ipv4).
EOF
  fi
  [[ -z $TLS_PIN ]] || printf 'TLS public-key pin: %s\n' "$TLS_PIN"
  printf '\n'
  "$WRAPPER" pair
}

cmd_install() {
  need_root
  check_os
  load_settings
  collect_settings
  install_packages
  create_user
  deploy_code
  write_secrets
  setup_tls
  write_relay_config
  write_turn_config
  write_caddy_config
  install_units
  setup_firewall
  setup_fail2ban
  setup_unattended_upgrades
  harden_ssh
  save_settings
  start_services
  [[ ${1:-} == quiet ]] || print_summary
}

snapshot_db() {
  local db=$DATA/relay.db new
  [[ -f $db ]] || return 0
  new=$(mktemp -d)
  write_version_file "$new/VERSION"
  if [[ -n $(build_of "$PREFIX") && $(build_of "$PREFIX") == "$(build_of "$new")" ]]; then
    rm -rf "$new"
    return 0  # same build again: keep the snapshot from before the real update
  fi
  rm -rf "$new"
  log "Snapshot of the database before the update: $db.pre-update"
  runuser -u "$SERVICE_USER" -- python3 -c \
    'import sqlite3, sys; s = sqlite3.connect(sys.argv[1]); d = sqlite3.connect(sys.argv[2]); s.backup(d); d.close()' \
    "$db" "$db.pre-update.tmp" || { warn "database snapshot failed"; return 0; }
  chmod 0600 "$db.pre-update.tmp"
  mv "$db.pre-update.tmp" "$db.pre-update"
}

cmd_update() {
  [[ -f $SETTINGS ]] || die "not installed; run install first"
  INTERACTIVE=0
  need_root
  check_not_downgrade
  snapshot_db
  cmd_install quiet
  log "Updated to $(installed_version). Settings, keys and paired devices were kept; 'install.sh rollback' goes back."
}

# Rollback protection: `update` never deploys older code than the installed one unless asked to
# ('install.sh rollback' is the way back to the previous code).
check_not_downgrade() {
  local installed new
  installed=$(sed -n 's/^version=//p' "$PREFIX/VERSION" 2>/dev/null || true)
  new=$(source_version)
  [[ $installed =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $installed != "$new" ]] || return 0
  [[ $(printf '%s\n%s\n' "$installed" "$new" | sort -V | head -1) == "$new" ]] || return 0
  [[ $ALLOW_DOWNGRADE == 1 ]] ||
    die "this code is $new, older than the installed $installed: not downgrading (--allow-downgrade forces it; 'install.sh rollback' returns to the previous code)"
  warn "downgrading from $installed to $new (--allow-downgrade)"
}

installed_version() {
  local dir=${1:-$PREFIX}
  if [[ -f $dir/VERSION ]]; then
    sed -n 's/^version=//p; s/^commit=/commit /p' "$dir/VERSION" | paste -sd' ' -
  else
    echo "unknown (installed before 0.7)"
  fi
}

cmd_rollback() {
  need_root
  [[ -d ${PREFIX}.old ]] || die "nothing to roll back to (no ${PREFIX}.old)"
  log "Rolling back from $(installed_version) to $(installed_version "${PREFIX}.old")"
  systemctl stop hermescall-relay.service
  rm -rf "${PREFIX}.rollback"
  mv "$PREFIX" "${PREFIX}.rollback"
  mv "${PREFIX}.old" "$PREFIX"
  mv "${PREFIX}.rollback" "${PREFIX}.old"
  local unit
  for unit in "${UNITS[@]}"; do
    [[ ! -f $PREFIX/relay/deploy/$unit ]] || install -m 0644 "$PREFIX/relay/deploy/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
  if [[ $RESTORE_DB -eq 1 ]]; then
    [[ -f $DATA/relay.db.pre-update ]] || die "no database snapshot at $DATA/relay.db.pre-update"
    rm -f "$DATA/relay.db-wal" "$DATA/relay.db-shm"
    install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA/relay.db.pre-update" "$DATA/relay.db"
    log "Database restored from the snapshot taken before the update"
  fi
  systemctl restart hermescall-turn.service hermescall-relay.service
  log "Rolled back. 'install.sh rollback' again returns to the newer code."
}

cmd_backup() {
  need_root
  local target=${1:-/root/hermescall-relay-backup-$(date +%Y%m%d-%H%M%S).tar.gz}
  local include=()
  [[ ! -d $CADDY_TLS ]] || include=(--include "$CADDY_TLS")
  (umask 077; relay_cli_as_root backup "$target" "${include[@]}")
  log "Keep $target offline and private: it holds the relay's keys. Restore: install.sh restore $target"
}

# Restores an archive from `install.sh backup` (or `hermescall-relay backup`), also on a fresh
# host: put the files back, then run the normal install, which keeps them.
cmd_restore() {
  need_root
  local archive=${1:-}
  [[ -f $archive ]] || die "usage: install.sh restore FILE"
  local work
  work=$(mktemp -d)
  RESTORE_WORK=$work
  trap 'rm -rf "$RESTORE_WORK"' EXIT
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$work" manifest.json relay.db files ||
    die "not a relay backup: $archive"
  [[ -f $work/relay.db && -d $work/files$ETC ]] || die "backup lacks the database or $ETC"
  check_backup_db "$work/relay.db"
  systemctl stop hermescall-relay.service hermescall-turn.service 2>/dev/null || true
  create_user
  install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA"
  local file
  for file in "$work/files$ETC"/*; do
    [[ -f $file && ! -L $file ]] || continue
    install -m 0600 -o root -g root "$file" "$ETC/$(basename "$file")"
  done
  chmod 0644 "$ETC"/*.toml 2>/dev/null || true
  if [[ -d $work/files$CADDY_TLS ]]; then
    install -d -m 0750 "$CADDY_TLS"
    for file in "$work/files$CADDY_TLS"/*; do
      [[ -f $file && ! -L $file ]] && install -m 0600 "$file" "$CADDY_TLS/$(basename "$file")"
    done
  fi
  if [[ -f $DATA/relay.db ]]; then
    cp -p "$DATA/relay.db" "$DATA/relay.db.pre-restore"
    log "The database it replaces is kept as $DATA/relay.db.pre-restore"
  fi
  rm -f "$DATA/relay.db-wal" "$DATA/relay.db-shm"
  install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" "$work/relay.db" "$DATA/relay.db"
  log "Restored $ETC and the database; reinstalling with the restored settings"
  INTERACTIVE=0
  cmd_install quiet
  log "Restore complete. Bridges and phones reconnect by themselves if the address and TLS key are unchanged."
}

# Integrity and schema of a backup's database, checked before anything is replaced.
check_backup_db() {
  command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 >/dev/null; }
  PYTHONPATH="$SRC_ROOT/relay" python3 - "$1" <<'EOF' || die "the backup's database is damaged or from a newer relay; nothing was changed"
import sqlite3, sys
from hermescall_relay import schema
db = sqlite3.connect(sys.argv[1])
ok = db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
sys.exit(0 if ok and (schema.version(db) <= schema.LATEST or schema.min_reader(db) <= schema.LATEST) else 1)
EOF
}

cmd_rotate() {
  need_root
  load_settings
  collect_turn_settings
  case "${1:-}" in
    turn-secret)
      openssl rand -hex 32 | write_secret "$ETC/turn_secret" "$SERVICE_USER"
      write_turn_config
      systemctl restart hermescall-turn.service hermescall-relay.service
      log "TURN secret rotated. Calls in progress may drop; new calls get new credentials."
      ;;
    push-key)
      openssl genpkey -algorithm ed25519 | write_secret "$ETC/push_gateway_key" "$SERVICE_USER"
      systemctl restart hermescall-relay.service
      log "Push gateway key rotated; new relay id: $("$WRAPPER" push-id)"
      ;;
    apns-key)
      [[ -n $HC_APNS_KEY_FILE ]] || die "usage: install.sh rotate apns-key --apns-key FILE [--apns-key-id ID]"
      HC_APNS=yes
      collect_settings
      write_secrets
      write_relay_config
      save_settings
      systemctl restart hermescall-relay.service
      log "APNs key replaced (key id $HC_APNS_KEY_ID). Revoke the old key at developer.apple.com once pushes work."
      ;;
    *) die "usage: install.sh rotate turn-secret|push-key|apns-key [--apns-key FILE --apns-key-id ID]" ;;
  esac
}

cmd_status() {
  printf 'Hermes Call relay %s\n' "$(installed_version)"
  [[ ! -d ${PREFIX}.old ]] || printf 'rollback available to %s\n' "$(installed_version "${PREFIX}.old")"
  systemctl --no-pager status "${UNITS[@]}" caddy.service || true
}

cmd_refresh_ip() {
  need_root
  load_settings
  collect_turn_settings
  local before after
  before=$(grep '^external-ip=' "$ETC/turnserver.conf" 2>/dev/null || true)
  after=$(nat_mapping)
  [[ -n $after && "external-ip=$after" != "$before" ]] || return 0
  write_turn_config
  systemctl restart hermescall-turn.service
}

remove_firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    ufw delete allow "$TURN_PORT" >/dev/null 2>&1 || true
    ufw delete allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp" >/dev/null 2>&1 || true
    ufw delete allow "$TURNS_PORT/tcp" >/dev/null 2>&1 || true
    local net
    for net in ${HC_PROXY_FROM//,/ }; do
      ufw delete allow from "$net" to any port "$LISTEN_PORT" proto tcp >/dev/null 2>&1 || true
    done
  fi
  # Our table goes in any case; the rules that were loaded before the relay are still loaded (the
  # relay only ever replaced its own table). The previous nftables.conf is put back for the next
  # boot, not loaded now: Debian's default one starts with "flush ruleset" (Docker, Proxmox).
  nft delete table inet hermescall 2>/dev/null || true
  if [[ -f /etc/nftables.conf.hermescall-backup ]]; then
    mv /etc/nftables.conf.hermescall-backup /etc/nftables.conf
  elif grep -q 'Managed by hermes-call relay/install.sh' /etc/nftables.conf 2>/dev/null; then
    printf '#!/usr/sbin/nft -f\n# The Hermes Call relay was removed; there was no nftables.conf before it.\n' >/etc/nftables.conf
  fi
}

cmd_uninstall() {
  need_root
  load_settings
  HC_TLS=${HC_TLS:-self-signed} HC_TURNS=${HC_TURNS:-no}
  collect_turn_settings
  log "Stopping and removing Hermes Call relay"
  local unit
  for unit in "${UNITS[@]}" hermescall-ip-refresh.timer hermescall-turn-cert.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  rm -f /etc/systemd/system/hermescall-{relay,turn,ip-refresh,turn-cert}.{service,timer} /etc/systemd/system/caddy.service.d/hermescall.conf
  systemctl daemon-reload
  systemctl unmask coturn.service >/dev/null 2>&1 || true
  rm -rf "$PREFIX" "${PREFIX}.old" "$WRAPPER" "$OLD_WRAPPER" /etc/fail2ban/jail.d/hermescall.local
  if [[ -f /etc/caddy/Caddyfile.hermescall-backup ]]; then
    mv /etc/caddy/Caddyfile.hermescall-backup /etc/caddy/Caddyfile
    systemctl restart caddy.service 2>/dev/null || true
  fi
  remove_firewall
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$ETC" "$DATA" "$CADDY_TLS"
    userdel "$SERVICE_USER" 2>/dev/null || true
    log "Purged keys, configuration and database."
  else
    log "Kept $ETC and $DATA (use --purge to delete)."
  fi
  [[ ! -f /etc/ssh/sshd_config.d/00-hermescall.conf ]] ||
    log "SSH key-only drop-in kept: /etc/ssh/sshd_config.d/00-hermescall.conf"
  log "Distribution packages (caddy, coturn, ...) were left installed."
}

main() {
  local command=install argument=""
  if [[ $# -gt 0 && $1 != -* ]]; then command=$1; shift; fi
  case "$command" in
    backup | restore | rotate) if [[ $# -gt 0 && $1 != -* ]]; then argument=$1; shift; fi ;;
  esac
  parse_flags "$@"
  case "$command" in
    install) cmd_install ;;
    update) cmd_update ;;
    rollback) cmd_rollback ;;
    backup) cmd_backup "$argument" ;;
    restore) cmd_restore "$argument" ;;
    rotate) cmd_rotate "$argument" ;;
    uninstall) cmd_uninstall ;;
    refresh-ip) cmd_refresh_ip ;;
    turn-cert) cmd_turn_cert ;;
    pair) need_root; exec "$WRAPPER" pair ;;
    status) cmd_status ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
