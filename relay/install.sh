#!/usr/bin/env bash
# Hermes Call relay installer for Debian 12/13 and Ubuntu 24.04.
#
#   install.sh [install]        install or reconfigure (idempotent)
#   install.sh update           redeploy code from this checkout, keep settings and data
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
readonly WRAPPER=/usr/local/sbin/hermescall-relay
readonly SERVICE_USER=hermescall-relay
readonly LISTEN_PORT=8743
readonly TURN_PORT=3478
readonly TURN_MIN_PORT=49160
readonly TURN_MAX_PORT=49200
readonly UNITS=(hermescall-relay.service hermescall-turn.service)
readonly DEFAULT_PUSH_GATEWAY=https://hermes-push.quavon.de
readonly SETTING_KEYS=(HC_DOMAIN HC_IP HC_TLS HC_ACME_EMAIL HC_APNS HC_APNS_KEY_ID HC_TEAM_ID HC_BUNDLE_ID HC_PUSH_GATEWAY HC_PROXY_FROM HC_EXTERNAL_IP HC_FIREWALL HC_HARDEN_SSH)
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
INTERACTIVE=1
PURGE=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [install|update|uninstall|pair|status] [options]

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
  --push-gateway URL     push gateway for relays without an own key (default $DEFAULT_PUSH_GATEWAY)
  --no-push-gateway      no pushes at all: incoming calls ring only while the app is open
  --external-ip ADDRESS  public IP when the relay sits behind NAT (auto-detected)
  --no-firewall          do not manage nftables (e.g. Proxmox firewall does it)
  --harden-ssh           disable SSH password logins (requires an authorized key)
  --non-interactive      never prompt; fail on missing settings
  --purge                with uninstall: also delete keys, config and database
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
      --push-gateway) HC_PUSH_GATEWAY=${2:?}; shift ;;
      --no-push-gateway) HC_PUSH_GATEWAY=no ;;
      --external-ip) HC_EXTERNAL_IP=${2:?}; shift ;;
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
    HC_PUSH_GATEWAY=$DEFAULT_PUSH_GATEWAY
    [[ $HC_APNS == yes || ! -f $SETTINGS ]] ||
      warn "pushes now go through $HC_PUSH_GATEWAY (it sees push tokens and timing, never content; docs/push-gateway.md). Opt out: install.sh update --no-push-gateway"
  fi
  [[ $HC_PUSH_GATEWAY == no || $HC_PUSH_GATEWAY =~ ^https://[A-Za-z0-9.:/_-]{1,190}$ ]] || die "--push-gateway must be an https URL"
  [[ -z $HC_EXTERNAL_IP ]] || is_ipv4 "$HC_EXTERNAL_IP" || die "invalid --external-ip"
  [[ -n $HC_FIREWALL ]] || HC_FIREWALL=yes
  [[ -n $HC_HARDEN_SSH ]] || HC_HARDEN_SSH=no
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
  rm -rf "${PREFIX}.old"
  [[ -d $PREFIX ]] && mv "$PREFIX" "${PREFIX}.old"
  mv "$staging" "$PREFIX"
  rm -rf "${PREFIX}.old"
  cat >"$WRAPPER" <<EOF
#!/bin/sh
set -eu
[ "\$(id -u)" -eq 0 ] || { echo "hermescall-relay: run as root" >&2; exit 1; }
cd /
exec runuser -u $SERVICE_USER -- env PYTHONPATH=$PREFIX/common:$PREFIX/relay PYTHONDONTWRITEBYTECODE=1 \\
  python3 -m hermescall_relay.cli "\$@"
EOF
  chmod 0755 "$WRAPPER"
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
urls = ["turn:$(url_host):$TURN_PORT?transport=udp", "turn:$(url_host):$TURN_PORT?transport=tcp"]
ttl = 600

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
no-tls
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
total-quota=100
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
  if [[ -n $(nat_mapping) && -n $HC_DOMAIN && -z $HC_EXTERNAL_IP ]]; then
    install -m 0644 "$PREFIX/relay/deploy/hermescall-ip-refresh.service" /etc/systemd/system/
    install -m 0644 "$PREFIX/relay/deploy/hermescall-ip-refresh.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now hermescall-ip-refresh.timer >/dev/null
  fi
  systemctl daemon-reload
}

ssh_ports() {
  install -d -m 0755 /run/sshd
  { sshd -T 2>/dev/null || true; } | awk '$1 == "port" {print $2}' | paste -sd, -
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
    return 0
  fi
  log "Configuring nftables (default deny inbound)"
  local ports="" ssh_rule=""
  if has_sshd; then
    ports=$(ssh_ports)
    [[ -n $ports ]] || die "could not determine the SSH port (sshd -T failed); refusing to enable a firewall that could lock you out"
  fi
  [[ -z $ports ]] || ssh_rule="tcp dport { $ports } ct state new limit rate 30/minute accept"
  local signaling_rule="tcp dport 443 accept" v4="" v6="" net
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
Open ports: $(signaling_summary), $TURN_PORT/udp+tcp (TURN), $TURN_MIN_PORT-$TURN_MAX_PORT/udp (TURN media relay)$(if has_sshd; then printf ', SSH'; fi)
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

cmd_update() {
  [[ -f $SETTINGS ]] || die "not installed; run install first"
  INTERACTIVE=0
  cmd_install quiet
  log "Updated. Settings, keys and paired devices were kept."
}

cmd_refresh_ip() {
  need_root
  load_settings
  local before after
  before=$(grep '^external-ip=' "$ETC/turnserver.conf" 2>/dev/null || true)
  after=$(nat_mapping)
  [[ -n $after && "external-ip=$after" != "$before" ]] || return 0
  write_turn_config
  systemctl restart hermescall-turn.service
}

cmd_uninstall() {
  need_root
  log "Stopping and removing Hermes Call relay"
  local unit
  for unit in "${UNITS[@]}" hermescall-ip-refresh.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  rm -f /etc/systemd/system/hermescall-{relay,turn,ip-refresh}.{service,timer} /etc/systemd/system/caddy.service.d/hermescall.conf
  systemctl daemon-reload
  systemctl unmask coturn.service >/dev/null 2>&1 || true
  rm -rf "$PREFIX" "$WRAPPER" /etc/fail2ban/jail.d/hermescall.local
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    ufw delete allow "$TURN_PORT" >/dev/null 2>&1 || true
    ufw delete allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp" >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/caddy/Caddyfile.hermescall-backup ]]; then
    mv /etc/caddy/Caddyfile.hermescall-backup /etc/caddy/Caddyfile
    systemctl restart caddy.service 2>/dev/null || true
  fi
  if [[ -f /etc/nftables.conf.hermescall-backup ]]; then
    mv /etc/nftables.conf.hermescall-backup /etc/nftables.conf
    nft -f /etc/nftables.conf 2>/dev/null || true
  fi
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$ETC" /var/lib/hermescall-relay "$CADDY_TLS"
    userdel "$SERVICE_USER" 2>/dev/null || true
    log "Purged keys, configuration and database."
  else
    log "Kept $ETC and /var/lib/hermescall-relay (use --purge to delete)."
  fi
  [[ ! -f /etc/ssh/sshd_config.d/00-hermescall.conf ]] ||
    log "SSH key-only drop-in kept: /etc/ssh/sshd_config.d/00-hermescall.conf"
  log "Distribution packages (caddy, coturn, ...) were left installed."
}

main() {
  local command=install
  if [[ $# -gt 0 && $1 != -* ]]; then command=$1; shift; fi
  parse_flags "$@"
  case "$command" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    refresh-ip) cmd_refresh_ip ;;
    pair) need_root; exec "$WRAPPER" pair ;;
    status) systemctl --no-pager status "${UNITS[@]}" caddy.service ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
