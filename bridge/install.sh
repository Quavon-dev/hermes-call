#!/usr/bin/env bash
# hermes-call-bridge installer for the Hermes container (Ubuntu 24.04 / Debian 12+).
#
#   install.sh [install]          install or reconfigure (idempotent)
#   install.sh update             redeploy code from this checkout, keep keys and pairings
#   install.sh uninstall [--purge]
#
# The bridge only makes outbound connections (to your relay) and binds its
# control API to 127.0.0.1. Nothing listens on the network.
# shellcheck disable=SC2016  # the sh -c snippets receive their paths as $1/$2 on purpose
set -Eeuo pipefail

readonly PREFIX=/opt/hermes-call-bridge
readonly ETC=/etc/hermes-call-bridge
readonly STATE=/var/lib/hermes-call-bridge
readonly SERVICE_USER=hermes-call-bridge
readonly WRAPPER=/usr/local/bin/hermes-call-bridge
readonly UNIT=hermes-call-bridge.service
declare -A MODEL_REVISIONS=(
  [small.en]=d1d751a5f8271d482d14ca55d9e2deeebbae577f
  [base.en]=3d3d5dee26484f91867d81cb899cfcf72b96be6c
)
declare -A MODEL_SHA256=(
  [small.en]=62b2a45b05ee59acb4a5341b33ee35e041395d378d418a18acfe4c9e768ee37a
  [base.en]=2a166925539a16005f14ff328359f9b9adb9dc4fb631bb3b227526862e93e2ef
)
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SRC_ROOT

# Empty = keep the installed value (bridge.toml / install.env), else the default (see load_settings).
HERMES_USER=${HERMES_USER:-}
STT_MODEL=${STT_MODEL:-}
TTS_VOICE=${TTS_VOICE:-}
AGENT_NAME=${AGENT_NAME:-}
CONFIGURE_HERMES=0
PURGE=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [install|update|uninstall] [options]

  --hermes-user NAME     Unix user running Hermes (default: hermes)
  --configure-hermes     enable the Hermes API server on 127.0.0.1 in ~/.hermes/.env
                         (adds API_SERVER_ENABLED/API_SERVER_KEY), install the hermes-call plugin
                         (call_owner, phone_context, present_to_owner + hermes_call chat) and set HERMES_CALL_TOKEN
                         (restart Hermes and its gateway afterwards)
  --stt-model NAME       base.en (default: ~0.5 s per utterance on 2 cores) or small.en
                         (more accurate, ~1.7 s per utterance on 2 cores, ~300 MB more RAM)
  --voice NAME           Kokoro voice (default: bm_george)
  --agent-name NAME      name shown on the phone for calls (default: Hermes)
  --purge                with uninstall: also delete keys, pairings and models
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hermes-user) HERMES_USER=${2:?}; shift ;;
      --configure-hermes) CONFIGURE_HERMES=1 ;;
      --stt-model) STT_MODEL=${2:?}; shift ;;
      --voice) TTS_VOICE=${2:?}; shift ;;
      --agent-name) AGENT_NAME=${2:?}; shift ;;
      --purge) PURGE=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

# Both read files a fresh install does not have yet: never fail (set -e + pipefail).
toml_value() { { sed -n "s/^$1 = \"\\(.*\\)\"\$/\\1/p" "$ETC/bridge.toml" 2>/dev/null || true; } | head -1; }

# Flags win; otherwise `update` keeps what is installed; defaults only for a first install.
load_settings() {
  [[ -n $HERMES_USER ]] || HERMES_USER=$({ sed -n 's/^HERMES_USER=//p' "$ETC/install.env" 2>/dev/null || true; } | head -1)
  [[ -n $AGENT_NAME ]] || AGENT_NAME=$(toml_value agent_name)
  [[ -n $TTS_VOICE ]] || TTS_VOICE=$(toml_value voice)
  [[ -n $STT_MODEL ]] || STT_MODEL=$(toml_value model)
  HERMES_USER=${HERMES_USER:-hermes}
  STT_MODEL=${STT_MODEL:-base.en}
  TTS_VOICE=${TTS_VOICE:-bm_george}
  AGENT_NAME=${AGENT_NAME:-Hermes}
  [[ -n ${MODEL_REVISIONS[$STT_MODEL]:-} ]] || die "unsupported --stt-model $STT_MODEL"
  [[ $HERMES_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid --hermes-user"
  [[ $TTS_VOICE =~ ^[a-z]{2}_[a-z0-9_]{1,40}$ ]] || die "invalid --voice"
  [[ $AGENT_NAME =~ ^[A-Za-z0-9][A-Za-z0-9\ ._\'-]{0,31}$ ]] || die "invalid --agent-name (1-32 letters, digits, spaces, . _ ' -)"
}

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:24.04 | debian:12 | debian:13) ;;
    *) die "unsupported OS ${PRETTY_NAME:-unknown}" ;;
  esac
}

install_packages() {
  log "Installing distribution packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 python3-venv libsodium23 qrencode ca-certificates >/dev/null
}

create_user() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --home-dir "$STATE" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0755 -o root -g root "$ETC"
  install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE" "$STATE/models"
}

deploy_code() {
  log "Deploying bridge to $PREFIX (hash-pinned Python dependencies)"
  install -d -m 0755 "$PREFIX"
  rm -rf "$PREFIX/common.new" "$PREFIX/bridge.new" "$PREFIX/hermes-integration.new"
  install -d -m 0755 "$PREFIX/common.new" "$PREFIX/bridge.new" "$PREFIX/hermes-integration.new"
  cp -r "$SRC_ROOT/common/hermescall_common" "$PREFIX/common.new/"
  cp -r "$SRC_ROOT/hermes-integration/hermes-call" "$PREFIX/hermes-integration.new/"
  cp -r "$SRC_ROOT/bridge/hermescall_bridge" "$SRC_ROOT/bridge/deploy" "$SRC_ROOT/bridge/install.sh" \
    "$SRC_ROOT/bridge/requirements.lock" "$PREFIX/bridge.new/"
  find "$PREFIX"/*.new -name '__pycache__' -prune -exec rm -rf {} +
  chown -R root:root "$PREFIX"/*.new
  find "$PREFIX"/*.new -type d -exec chmod 0755 {} + && find "$PREFIX"/*.new -type f -exec chmod 0644 {} +
  chmod 0755 "$PREFIX/bridge.new/install.sh"
  if [[ ! -x $PREFIX/venv/bin/python ]]; then
    python3 -m venv "$PREFIX/venv"
  fi
  "$PREFIX/venv/bin/pip" install -q --disable-pip-version-check --no-deps --require-hashes --only-binary=:all: \
    -r "$PREFIX/bridge.new/requirements.lock"
  rm -rf "$PREFIX/common" "$PREFIX/bridge" "$PREFIX/hermes-integration"
  mv "$PREFIX/common.new" "$PREFIX/common"
  mv "$PREFIX/bridge.new" "$PREFIX/bridge"
  mv "$PREFIX/hermes-integration.new" "$PREFIX/hermes-integration"
  cat >"$WRAPPER" <<EOF
#!/bin/sh
set -eu
[ "\$(id -u)" -eq 0 ] || { echo "hermes-call-bridge: run as root" >&2; exit 1; }
cd /
exec runuser -u $SERVICE_USER -- env PYTHONPATH=$PREFIX/common:$PREFIX/bridge PYTHONDONTWRITEBYTECODE=1 \\
  HF_HUB_OFFLINE=1 $PREFIX/venv/bin/python -m hermescall_bridge.cli "\$@"
EOF
  chmod 0755 "$WRAPPER"
}

download_model() {
  local target=$STATE/models/$STT_MODEL
  [[ -f $target/model.bin && $(cat "$target/.revision" 2>/dev/null) == "${MODEL_REVISIONS[$STT_MODEL]}" ]] && return 0
  log "Downloading speech recognition model $STT_MODEL (pinned revision, one time)"
  runuser -u "$SERVICE_USER" -- env HF_HUB_DISABLE_TELEMETRY=1 "$PREFIX/venv/bin/python" - "$STT_MODEL" \
    "${MODEL_REVISIONS[$STT_MODEL]}" "$target" <<'PY'
import sys
from huggingface_hub import snapshot_download

name, revision, target = sys.argv[1:4]
snapshot_download(f"Systran/faster-whisper-{name}", revision=revision, local_dir=target)
open(f"{target}/.revision", "w").write(revision)
PY
  echo "${MODEL_SHA256[$STT_MODEL]}  $target/model.bin" | sha256sum -c --quiet - ||
    { rm -rf "$target"; die "downloaded model does not match the pinned SHA-256"; }
}

write_secret() (
  local path=$1
  umask 077
  cat >"$path.tmp"
  chown "$SERVICE_USER:$SERVICE_USER" "$path.tmp"
  chmod 0600 "$path.tmp"
  mv "$path.tmp" "$path"
)

hermes_env_file() {
  local home
  home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
  [[ -n $home ]] || return 1
  printf '%s/.hermes/.env' "$home"
}

# Everything inside ~hermes/.hermes is read and written as the Hermes user: that directory belongs to
# an LLM-driven agent, so root must not follow links planted there.
as_hermes() { runuser -u "$HERMES_USER" -- "$@"; }

env_value() { { as_hermes cat "$1" 2>/dev/null | grep -E "^$2=" || true; } | tail -1 | cut -d= -f2- | tr -d '"'"'"; }

configure_hermes_api() {
  local env_file key
  env_file=$(hermes_env_file) || { warn "Hermes user '$HERMES_USER' not found"; return 0; }
  key=$(env_value "$env_file" API_SERVER_KEY)
  if [[ -z $key && $CONFIGURE_HERMES -eq 1 ]]; then
    as_hermes test -f "$env_file" || die "$env_file not found; is Hermes installed for $HERMES_USER?"
    key=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    local additions=$'\n# Added by hermes-call-bridge: Hermes API server, loopback only\n'
    [[ -n $(env_value "$env_file" API_SERVER_ENABLED) ]] || additions+=$'API_SERVER_ENABLED=true\n'
    [[ -n $(env_value "$env_file" API_SERVER_HOST) ]] || additions+=$'API_SERVER_HOST=127.0.0.1\n'
    additions+="API_SERVER_KEY=$key"$'\n'
    printf '%s' "$additions" | as_hermes sh -c \
      'umask 077; cp -p "$1" "$1.hermes-call-bridge-backup" && cat >>"$1" && chmod 0600 "$1"' _ "$env_file"
    log "Enabled the Hermes API server in $env_file (backup: .hermes-call-bridge-backup). Restart Hermes to apply."
  fi
  if [[ -z $key ]]; then
    warn "Hermes API server key not found. Re-run with --configure-hermes, or set API_SERVER_KEY in $env_file."
    return 0
  fi
  printf '%s' "$key" | write_secret "$ETC/hermes_api_key"
}

# The value travels on stdin, never in a command line visible to other users.
set_env_value() {
  local file=$1 name=$2 value=$3
  [[ $(env_value "$file" "$name") == "$value" ]] && return 0
  printf '%s' "$value" | as_hermes sh -c 'umask 077
    IFS= read -r value || [ -n "$value" ]
    tmp=$(mktemp "$1.XXXXXX") || exit 1
    { grep -v "^$2=" "$1" || true; printf "%s=%s\n" "$2" "$value"; } >"$tmp" && mv "$tmp" "$1"' _ "$file" "$name"
}

install_hermes_plugin() {
  local env_file plugins
  env_file=$(hermes_env_file) || return 0
  as_hermes test -f "$env_file" || return 0
  plugins=$(dirname "$env_file")/plugins
  # First install only with --configure-hermes; an installed plugin is always refreshed (update).
  [[ $CONFIGURE_HERMES -eq 1 ]] || as_hermes test -d "$plugins/hermes-call" || return 0
  log "Installing the Hermes plugin 'hermes-call' (tools call_owner, phone_context, present_to_owner; chat platform hermes_call) for $HERMES_USER"
  as_hermes sh -c 'umask 022; mkdir -p "$1" && rm -rf "$1/hermes-call.new" && cp -R "$2" "$1/hermes-call.new" &&
    rm -rf "$1/hermes-call" && mv "$1/hermes-call.new" "$1/hermes-call"' _ "$plugins" "$PREFIX/hermes-integration/hermes-call"
  set_env_value "$env_file" HERMES_CALL_TOKEN "$(cat "$ETC/call_token")"
  # Chat: cron `deliver=hermes_call` goes to the owner's chat; only paired phones can reach the bridge,
  # so a global GATEWAY_ALLOWED_USERS must not lock the owner out of it.
  set_env_value "$env_file" HERMES_CALL_HOME_CHANNEL owner
  set_env_value "$env_file" HERMES_CALL_ALLOW_ALL_USERS true
  if as_hermes bash -lc 'command -v hermes' >/dev/null 2>&1; then
    as_hermes bash -lc 'hermes plugins enable hermes-call' >/dev/null ||
      warn "could not enable the plugin; run as $HERMES_USER: hermes plugins enable hermes-call"
  else
    warn "hermes CLI not found for $HERMES_USER; run as $HERMES_USER: hermes plugins enable hermes-call"
  fi
}

write_config() {
  [[ -s $ETC/api_token ]] || head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | write_secret "$ETC/api_token"
  [[ -s $ETC/call_token ]] || head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | write_secret "$ETC/call_token"
  cat >"$ETC/bridge.toml.tmp" <<EOF
# hermes-call-bridge configuration (managed by install.sh; secrets live in separate 0600 files)
agent_name = "$AGENT_NAME"
state_dir = "$STATE"
secrets_dir = "$ETC"

[api]
host = "127.0.0.1"
port = 8765

[hermes]
url = "http://127.0.0.1:8642"
session_id = "hermes-call-phone"

[tts]
url = "http://127.0.0.1:8880"
voice = "$TTS_VOICE"

[stt]
model = "$STT_MODEL"
model_dir = "$STATE/models"
threads = $(nproc)
EOF
  chmod 0644 "$ETC/bridge.toml.tmp"
  mv "$ETC/bridge.toml.tmp" "$ETC/bridge.toml"
}

install_unit() {
  install -m 0644 "$PREFIX/bridge/deploy/$UNIT" "/etc/systemd/system/$UNIT"
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
}

start_if_ready() {
  if [[ ! -s $ETC/hermes_api_key ]]; then
    warn "not starting yet: Hermes API key missing"
  elif ! "$WRAPPER" relay show 2>/dev/null | grep -qv 'not paired'; then
    log "Next: pair with your relay:  hermes-call-bridge relay add '<pairing link from hermescall-relay pair>'"
  else
    systemctl restart "$UNIT"
    log "hermes-call-bridge running"
  fi
}

save_settings() (
  umask 077
  printf 'HERMES_USER=%s\n' "$HERMES_USER" >"$ETC/install.env"
)

cmd_install() {
  need_root
  check_os
  load_settings
  install_packages
  create_user
  deploy_code
  download_model
  write_config
  configure_hermes_api
  install_hermes_plugin
  install_unit
  save_settings
  start_if_ready
  cat <<EOF

hermes-call-bridge installed. It makes outbound connections only; its API is 127.0.0.1:8765.
  hermes-call-bridge relay add '<link>'     pair with your relay (then: systemctl restart hermes-call-bridge)
  hermes-call-bridge device add --name iPhone
  hermes-call-bridge device list | revoke <id>
  hermes-call-bridge call                   ring your paired devices
EOF
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$UNIT" "$WRAPPER"
  systemctl daemon-reload
  rm -rf "$PREFIX"
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$ETC" "$STATE"
    userdel "$SERVICE_USER" 2>/dev/null || true
    log "Purged keys, pairings and models. Hermes' .env and its hermes-call plugin were not changed."
  else
    log "Kept $ETC and $STATE (use --purge to delete)."
  fi
}

main() {
  local command=install
  if [[ $# -gt 0 && $1 != -* ]]; then command=$1; shift; fi
  parse_flags "$@"
  case "$command" in
    install | update) cmd_install ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
