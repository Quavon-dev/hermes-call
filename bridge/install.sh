#!/usr/bin/env bash
# hermes-call-bridge installer for the Hermes container (Ubuntu 24.04 / Debian 12+).
#
#   install.sh [install]          install or reconfigure (idempotent)
#   install.sh update             redeploy code from this checkout, keep keys and pairings
#   install.sh uninstall [--purge]
#   install.sh … --instance NAME  a second bridge for another agent on this host (own config, state,
#                                  port and systemd unit hermes-call-bridge@NAME); default: the single bridge
#
# The bridge only makes outbound connections (to your relay) and binds its
# control API to 127.0.0.1. Nothing listens on the network.
# shellcheck disable=SC2016  # the sh -c snippets receive their paths as $1/$2 on purpose
set -Eeuo pipefail

readonly PREFIX=/opt/hermes-call-bridge
readonly SERVICE_USER=hermes-call-bridge
# Per instance (set_paths): the default instance keeps the historical paths and unit.
ETC=/etc/hermes-call-bridge
STATE=/var/lib/hermes-call-bridge
WRAPPER=/usr/local/bin/hermes-call-bridge
UNIT=hermes-call-bridge.service
UNIT_FILE=hermes-call-bridge.service
declare -A MODEL_REVISIONS=(
  [small.en]=d1d751a5f8271d482d14ca55d9e2deeebbae577f
  [base.en]=3d3d5dee26484f91867d81cb899cfcf72b96be6c
  [small]=536b0662742c02347bc0e980a01041f333bce120
)
declare -A MODEL_SHA256=(
  [small.en]=62b2a45b05ee59acb4a5341b33ee35e041395d378d418a18acfe4c9e768ee37a
  [base.en]=2a166925539a16005f14ff328359f9b9adb9dc4fb631bb3b227526862e93e2ef
  [small]=3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671
)
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SRC_ROOT

# Empty = keep the installed value (bridge.toml / install.env), else the default (see load_settings).
HERMES_USER=${HERMES_USER:-}
HERMES_MODEL=${HERMES_MODEL:-}
HERMES_PROVIDER=${HERMES_PROVIDER:-}
HERMES_REASONING_EFFORT=${HERMES_REASONING_EFFORT:-}
STT_MODEL=${STT_MODEL:-}
STT_LANGUAGE=${STT_LANGUAGE:-}
STT_BEAM_SIZE=${STT_BEAM_SIZE:-}
TTS_VOICE=${TTS_VOICE:-}
TTS_SPEED=${TTS_SPEED:-}
END_SILENCE_MS=${END_SILENCE_MS:-}
ACKNOWLEDGEMENT_AFTER_MS=${ACKNOWLEDGEMENT_AFTER_MS:-}
ACKNOWLEDGEMENT_TEXT=${ACKNOWLEDGEMENT_TEXT:-}
AGENT_NAME=${AGENT_NAME:-}
INSTANCE=${INSTANCE:-}
API_PORT=${API_PORT:-}
HERMES_PORT=${HERMES_PORT:-}
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
  --hermes-model NAME    model or API-server route used only for calls
  --hermes-provider NAME provider used only for calls
  --reasoning-effort NAME none, minimal, low, medium or high
  --stt-model NAME       base.en, small.en or multilingual small
  --stt-language CODE    speech language such as en or de
  --stt-beam-size N      Whisper beam size 1 to 5
  --voice NAME           Kokoro voice (default: bm_george)
  --tts-speed NUMBER     Kokoro speech speed between 0.5 and 2.0
  --end-silence-ms N     silence ending an utterance, 200 to 3000 ms
  --ack-after-ms N       0 disables; otherwise speak the acknowledgement after 1 to 5000 ms
  --ack-text TEXT        short acknowledgement spoken while Hermes is still working
  --agent-name NAME      name shown on the phone for calls (default: Hermes)
  --instance NAME        install/update/uninstall a named extra bridge (another agent on this host)
  --api-port PORT        the bridge's local API port (default 8765; each instance needs its own)
  --hermes-port PORT     that agent's Hermes API server port on 127.0.0.1 (default 8642)
  --purge                with uninstall: also delete keys, pairings and models
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hermes-user) HERMES_USER=${2:?}; shift ;;
      --configure-hermes) CONFIGURE_HERMES=1 ;;
      --hermes-model) HERMES_MODEL=${2:?}; shift ;;
      --hermes-provider) HERMES_PROVIDER=${2:?}; shift ;;
      --reasoning-effort) HERMES_REASONING_EFFORT=${2:?}; shift ;;
      --stt-model) STT_MODEL=${2:?}; shift ;;
      --stt-language) STT_LANGUAGE=${2:?}; shift ;;
      --stt-beam-size) STT_BEAM_SIZE=${2:?}; shift ;;
      --voice) TTS_VOICE=${2:?}; shift ;;
      --tts-speed) TTS_SPEED=${2:?}; shift ;;
      --end-silence-ms) END_SILENCE_MS=${2:?}; shift ;;
      --ack-after-ms) ACKNOWLEDGEMENT_AFTER_MS=${2:?}; shift ;;
      --ack-text) ACKNOWLEDGEMENT_TEXT=${2:?}; shift ;;
      --agent-name) AGENT_NAME=${2:?}; shift ;;
      --instance) INSTANCE=${2:?}; shift ;;
      --api-port) API_PORT=${2:?}; shift ;;
      --hermes-port) HERMES_PORT=${2:?}; shift ;;
      --purge) PURGE=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

# Both read files a fresh install does not have yet: never fail (set -e + pipefail).
toml_value() { { sed -n "s/^$1 = \"\\(.*\\)\"\$/\\1/p" "$ETC/bridge.toml" 2>/dev/null || true; } | head -1; }

toml_section_value() { python3 -c 'import sys,tomllib; data=tomllib.load(open(sys.argv[1], "rb")); value=data.get(sys.argv[2], {}).get(sys.argv[3], ""); print(value if isinstance(value, str) else "")' "$ETC/bridge.toml" "$1" "$2" 2>/dev/null || true; }

toml_section_number() { python3 -c 'import sys,tomllib; data=tomllib.load(open(sys.argv[1], "rb")); value=data.get(sys.argv[2], {}).get(sys.argv[3], ""); print(value if isinstance(value, (int, float)) and not isinstance(value, bool) else "")' "$ETC/bridge.toml" "$1" "$2" 2>/dev/null || true; }

toml_port() { { sed -n "s/^$1 = \\([0-9][0-9]*\\)\$/\\1/p" "$ETC/bridge.toml" 2>/dev/null || true; } | head -1; }

toml_quote() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

set_paths() {
  [[ -z $INSTANCE ]] && return 0
  [[ $INSTANCE =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid --instance (a-z, 0-9, -; up to 31 chars)"
  ETC=/etc/hermes-call-bridge-$INSTANCE
  STATE=/var/lib/hermes-call-bridge-$INSTANCE
  WRAPPER=/usr/local/bin/hermes-call-bridge-$INSTANCE
  UNIT=hermes-call-bridge@$INSTANCE.service
  UNIT_FILE=hermes-call-bridge@.service
}

# Flags win; otherwise `update` keeps what is installed; defaults only for a first install.
load_settings() {
  [[ -n $API_PORT ]] || API_PORT=$(toml_port port)
  [[ -n $HERMES_PORT ]] || HERMES_PORT=$(section_url hermes | sed -n 's|^http://127.0.0.1:\([0-9]*\)$|\1|p')
  API_PORT=${API_PORT:-8765}
  HERMES_PORT=${HERMES_PORT:-8642}
  [[ $API_PORT =~ ^[0-9]{2,5}$ && $API_PORT -le 65535 ]] || die "invalid --api-port"
  [[ $HERMES_PORT =~ ^[0-9]{2,5}$ && $HERMES_PORT -le 65535 ]] || die "invalid --hermes-port"
  [[ -n $HERMES_USER ]] || HERMES_USER=$({ sed -n 's/^HERMES_USER=//p' "$ETC/install.env" 2>/dev/null || true; } | head -1)
  [[ -n $AGENT_NAME ]] || AGENT_NAME=$(toml_value agent_name)
  [[ -n $HERMES_MODEL ]] || HERMES_MODEL=$(toml_section_value hermes model)
  [[ -n $HERMES_PROVIDER ]] || HERMES_PROVIDER=$(toml_section_value hermes provider)
  [[ -n $HERMES_REASONING_EFFORT ]] || HERMES_REASONING_EFFORT=$(toml_section_value hermes reasoning_effort)
  [[ -n $TTS_VOICE ]] || TTS_VOICE=$(toml_section_value tts voice)
  [[ -n $TTS_SPEED ]] || TTS_SPEED=$(toml_section_number tts speed)
  [[ -n $STT_MODEL ]] || STT_MODEL=$(toml_section_value stt model)
  [[ -n $STT_LANGUAGE ]] || STT_LANGUAGE=$(toml_section_value stt language)
  [[ -n $STT_BEAM_SIZE ]] || STT_BEAM_SIZE=$(toml_section_number stt beam_size)
  [[ -n $END_SILENCE_MS ]] || END_SILENCE_MS=$(toml_section_number voice end_silence_ms)
  [[ -n $ACKNOWLEDGEMENT_AFTER_MS ]] || ACKNOWLEDGEMENT_AFTER_MS=$(toml_section_number voice acknowledgement_after_ms)
  [[ -n $ACKNOWLEDGEMENT_TEXT ]] || ACKNOWLEDGEMENT_TEXT=$(toml_section_value voice acknowledgement_text)
  HERMES_USER=${HERMES_USER:-hermes}
  HERMES_MODEL=${HERMES_MODEL:-hermes-agent}
  HERMES_PROVIDER=${HERMES_PROVIDER:-}
  HERMES_REASONING_EFFORT=${HERMES_REASONING_EFFORT:-}
  STT_MODEL=${STT_MODEL:-base.en}
  STT_LANGUAGE=${STT_LANGUAGE:-en}
  STT_BEAM_SIZE=${STT_BEAM_SIZE:-1}
  TTS_VOICE=${TTS_VOICE:-bm_george}
  TTS_SPEED=${TTS_SPEED:-1.0}
  END_SILENCE_MS=${END_SILENCE_MS:-550}
  ACKNOWLEDGEMENT_AFTER_MS=${ACKNOWLEDGEMENT_AFTER_MS:-0}
  ACKNOWLEDGEMENT_TEXT=${ACKNOWLEDGEMENT_TEXT:-}
  AGENT_NAME=${AGENT_NAME:-Hermes}
  [[ -n ${MODEL_REVISIONS[$STT_MODEL]:-} ]] || die "unsupported --stt-model $STT_MODEL"
  [[ $STT_LANGUAGE =~ ^[a-z]{2,3}$ ]] || die "invalid --stt-language"
  [[ $STT_BEAM_SIZE =~ ^[1-5]$ ]] || die "invalid --stt-beam-size"
  if [[ $STT_MODEL == *.en && $STT_LANGUAGE != en ]]; then
    die "English-only STT models require --stt-language en"
  fi
  [[ $HERMES_REASONING_EFFORT =~ ^(none|minimal|low|medium|high)?$ ]] || die "invalid --reasoning-effort"
  if [[ ! $TTS_SPEED =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    ! python3 -c 'import sys; raise SystemExit(not 0.5 <= float(sys.argv[1]) <= 2.0)' "$TTS_SPEED"; then
    die "invalid --tts-speed"
  fi
  if [[ ! $END_SILENCE_MS =~ ^[0-9]+$ ]] ||
    ! python3 -c 'import sys; raise SystemExit(not 200 <= int(sys.argv[1]) <= 3000)' "$END_SILENCE_MS"; then
    die "invalid --end-silence-ms"
  fi
  if [[ ! $ACKNOWLEDGEMENT_AFTER_MS =~ ^[0-9]+$ ]] ||
    ! python3 -c 'import sys; raise SystemExit(not 0 <= int(sys.argv[1]) <= 5000)' "$ACKNOWLEDGEMENT_AFTER_MS"; then
    die "invalid --ack-after-ms"
  fi
  python3 -c 'import sys; raise SystemExit(len(sys.argv[1]) > 120)' "$ACKNOWLEDGEMENT_TEXT" || die "invalid --ack-text (at most 120 characters)"
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

# The version being installed: hermes-call/RELEASE of a release tarball, else bridge/pyproject.toml.
release_version() {
  local version
  version=$(sed -n 's/^version=//p' "$SRC_ROOT/RELEASE" 2>/dev/null || true)
  [[ -n $version ]] ||
    version=$({ sed -n 's/^version = "\(.*\)"$/\1/p' "$SRC_ROOT/bridge/pyproject.toml" 2>/dev/null || true; } | head -n 1)
  printf '%s' "$version"
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
  # get.sh compares the next release with this (downgrade check); unknown makes it require a MANIFEST.
  local version
  version=$(release_version)
  if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$version" >"$PREFIX/VERSION" && chmod 0644 "$PREFIX/VERSION"
  else
    rm -f "$PREFIX/VERSION"
    warn "unknown bridge version '${version}': updates through get.sh will need a signed release MANIFEST"
  fi
  cat >"$WRAPPER" <<EOF
#!/bin/sh
set -eu
# pct exec and cron run without a login shell: runuser lives in /usr/sbin.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "\$(id -u)" -eq 0 ] || { echo "hermes-call-bridge: run as root" >&2; exit 1; }
cd /
exec runuser -u $SERVICE_USER -- env PYTHONPATH=$PREFIX/common:$PREFIX/bridge PYTHONDONTWRITEBYTECODE=1 \\
  HF_HUB_OFFLINE=1 $PREFIX/venv/bin/python -m hermescall_bridge.cli --config $ETC/bridge.toml "\$@"
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
  # The plugin reaches this bridge's local API (the default port needs no setting).
  if [[ $API_PORT != 8765 || -n $(env_value "$env_file" HERMES_CALL_URL) ]]; then
    set_env_value "$env_file" HERMES_CALL_URL "http://127.0.0.1:$API_PORT"
  fi
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
port = $API_PORT

[hermes]
url = "http://127.0.0.1:$HERMES_PORT"
session_id = "hermes-call-phone"
model = $(toml_quote "$HERMES_MODEL")
provider = $(toml_quote "$HERMES_PROVIDER")
reasoning_effort = $(toml_quote "$HERMES_REASONING_EFFORT")

[tts]
url = "http://127.0.0.1:8880"
voice = $(toml_quote "$TTS_VOICE")
speed = $TTS_SPEED

[stt]
model = $(toml_quote "$STT_MODEL")
model_dir = "$STATE/models"
threads = $(nproc)
language = $(toml_quote "$STT_LANGUAGE")
beam_size = $STT_BEAM_SIZE

[voice]
end_silence_ms = $END_SILENCE_MS
acknowledgement_after_ms = $ACKNOWLEDGEMENT_AFTER_MS
acknowledgement_text = $(toml_quote "$ACKNOWLEDGEMENT_TEXT")

# Optional (defaults shown):
# [calls]
# ring_timeout = 45        # seconds a ring lasts
# approval_timeout = 60    # seconds to approve a command on the phone during a call
# max_call_seconds = 3600  # a call ends after this; a warning is spoken warning_seconds before
# warning_seconds = 60
# media_timeout = 20       # a call whose audio never arrives ends after this
# [turn]
# transport = "auto"       # TURN transport the bridge tries first: auto/udp, tcp or tls
# [log]
# level = "INFO"           # DEBUG, INFO, WARNING, ERROR
# format = "text"          # or "json"
EOF
  chmod 0644 "$ETC/bridge.toml.tmp"
  mv "$ETC/bridge.toml.tmp" "$ETC/bridge.toml"
}

install_unit() {
  install -m 0644 "$PREFIX/bridge/deploy/$UNIT_FILE" "/etc/systemd/system/$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
}

# `url` of a bridge.toml section ([hermes] or [tts]).
section_url() { { sed -n "/^\\[$1\\]/,/^\\[/ s/^url = \"\\(.*\\)\"\$/\\1/p" "$ETC/bridge.toml" 2>/dev/null || true; } | head -1; }

probe_dependency() {
  local name=$1 url=$2
  if "$PREFIX/venv/bin/python" - "$url" >/dev/null 2>&1 <<'PY'; then
import sys
import urllib.request

with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(sys.argv[1], timeout=3) as response:
    sys.exit(0 if response.status < 500 else 1)
PY
    log "$name reachable ($url)"
  else
    warn "$name is not reachable at $url; calls need it (is it running? see docs/bridge.md)"
  fi
}

# Reachability only: Kokoro and Hermes are installed and run by you, never by this script.
check_dependencies() {
  probe_dependency Hermes "$(section_url hermes)/health"
  probe_dependency Kokoro "$(section_url tts)/health"
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
  check_dependencies
  start_if_ready
  local cli=${WRAPPER##*/}
  cat <<EOF

hermes-call-bridge installed ($UNIT). It makes outbound connections only; its API is 127.0.0.1:$API_PORT.
  $cli relay add '<link>'     pair with your relay (stop the service first: systemctl stop $UNIT)
  $cli device add --name iPhone
  $cli device list | revoke <id>
  $cli call                   ring your paired devices
  $cli doctor                 check config, relay, Hermes, Kokoro, speech model and disk
EOF
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$WRAPPER"
  if [[ -z $INSTANCE ]] && ! compgen -G '/etc/hermes-call-bridge-*/bridge.toml' >/dev/null; then
    rm -f "/etc/systemd/system/$UNIT"
    rm -rf "$PREFIX"
  elif [[ -z $INSTANCE ]]; then
    rm -f "/etc/systemd/system/$UNIT"
    log "Kept the shared code in $PREFIX: named bridges (--instance) still use it."
  else
    log "Kept the shared code in $PREFIX and the unit template (other bridges may use them)."
  fi
  systemctl daemon-reload
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
  set_paths
  case "$command" in
    install | update) cmd_install ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
