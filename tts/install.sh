#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# hermes-call-tts installer: German speech for Hermes Call on 127.0.0.1 (Debian 12/13, Ubuntu 24.04).
#
#   install.sh [install]      install or update (idempotent; keeps the chosen voices)
#   install.sh uninstall [--purge]
#
# Sources are pinned: Python wheels by SHA-256 (requirements.lock), the German kokoro/misaki forks by
# commit, the voice models by Hugging Face revision and SHA-256. The service listens on loopback only
# and the systemd unit allows no network traffic other than localhost.
set -Eeuo pipefail

readonly PREFIX=/opt/hermes-call-tts
readonly STATE=/var/lib/hermes-call-tts
readonly ETC=/etc/hermes-call-tts
readonly SERVICE_USER=hermes-call-tts
readonly UNIT=hermes-call-tts.service
readonly KOKORO_REPO=https://github.com/semidark/kokoro.git
readonly KOKORO_COMMIT=b96fef95e6a746495f92443fac7c688f90fc57fc
readonly MISAKI_REPO=https://github.com/semidark/misaki.git
readonly MISAKI_COMMIT=6d252a2e02f3b030f22f56686f1a73786c16ffc8
readonly CONFIG_URL=https://huggingface.co/Thorsten-Voice/Kokoro/resolve/734e593d320a3d876bede7020f773dfd481a0cc7/config.json
readonly CONFIG_SHA256=5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f
# voice -> "<model URL> <model SHA-256> <voice pack URL> <voice pack SHA-256>"
declare -A VOICE_FILES=(
  [dm_thorsten]="https://huggingface.co/Thorsten-Voice/Kokoro/resolve/734e593d320a3d876bede7020f773dfd481a0cc7/model.pth 36dde15c4a800cfd1ab540ccb4476dbab604fe03ff7c937d976ebbf3b49e59ce https://huggingface.co/Thorsten-Voice/Kokoro/resolve/734e593d320a3d876bede7020f773dfd481a0cc7/voices/thorsten.pt 9d98b775ebce1cfc369e8f9a3ee8ee260cd612dffb477cba85749112362306d7"
  [dm_martin]="https://huggingface.co/kikiri-tts/kikiri-german-martin/resolve/1e9dcd16ed48fda0a7a1f62e5e37130a5fdf10d9/kikiri_german_martin_ep10.pth f194905cc97d4ef16e0f2613c2d277203e0c0f0f533e0a468c7ec76c566259dc https://huggingface.co/kikiri-tts/kikiri-german-martin/resolve/1e9dcd16ed48fda0a7a1f62e5e37130a5fdf10d9/voices/martin.pt dc2e245e631ceaa9d30b327dac076342649c62f953021bcccafbe254ee43e553"
  [df_victoria]="https://huggingface.co/kikiri-tts/kikiri-german-victoria/resolve/ce81e200ff9203e1a3b042cd678c48e3ffb85cef/kikiri_german_victoria_ep10.pth 128d1c4a4184a459f23cb307a6cbbb8e9c076c2526f86e18594c1b320a81e00c https://huggingface.co/kikiri-tts/kikiri-german-victoria/resolve/ce81e200ff9203e1a3b042cd678c48e3ffb85cef/voices/victoria.pt 18dbcf0afa7b737e450e6ba769ee898a5aae1d90218265ff4c95422f4693da50"
)
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SRC_ROOT

VOICES=${VOICES:-}
THREADS=${THREADS:-}
PORT=${PORT:-}
PURGE=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [install|uninstall] [options]

  --voices LIST   comma-separated German voices, the first is the default (default: dm_thorsten);
                  available: dm_thorsten, dm_martin, df_victoria (each one needs about 400 MB of memory)
  --threads N     CPU threads for synthesis (default: number of CPUs)
  --port PORT     loopback port (default 8881)
  --purge         with uninstall: also delete the models
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --voices) VOICES=${2:?}; shift ;;
      --threads) THREADS=${2:?}; shift ;;
      --port) PORT=${2:?}; shift ;;
      --purge) PURGE=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

installed() { { sed -n "s/^$1=//p" "$ETC/tts.env" 2>/dev/null || true; } | head -1; }

load_settings() {
  [[ -n $VOICES ]] || VOICES=$(installed VOICES)
  [[ -n $THREADS ]] || THREADS=$(installed THREADS)
  [[ -n $PORT ]] || PORT=$(installed PORT)
  VOICES=${VOICES:-dm_thorsten}
  THREADS=${THREADS:-$(nproc)}
  PORT=${PORT:-8881}
  local voice
  for voice in ${VOICES//,/ }; do
    [[ -n ${VOICE_FILES[$voice]:-} ]] || die "unknown voice $voice (dm_thorsten, dm_martin, df_victoria)"
  done
  [[ $THREADS =~ ^[1-9][0-9]?$ ]] || die "invalid --threads"
  [[ $PORT =~ ^[0-9]{2,5}$ && $PORT -le 65535 ]] || die "invalid --port"
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
  log "Installing distribution packages (espeak-ng for German phonemes)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 python3-venv espeak-ng git curl ca-certificates >/dev/null
}

create_user() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --home-dir "$STATE" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0755 -o root -g root "$ETC" "$PREFIX"
  install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE" "$STATE/models"
}

pinned_checkout() {
  local repo=$1 commit=$2 target=$3
  if [[ $(git -C "$target" rev-parse HEAD 2>/dev/null) != "$commit" ]]; then
    rm -rf "$target"
    git clone -q --filter=blob:none "$repo" "$target"
    git -C "$target" -c advice.detachedHead=false checkout -q "$commit"
  fi
  [[ $(git -C "$target" rev-parse HEAD) == "$commit" ]] || die "$repo is not at the pinned commit $commit"
}

deploy_code() {
  log "Deploying the speech service to $PREFIX (hash-pinned wheels, pinned kokoro/misaki commits)"
  install -d -m 0755 "$PREFIX/src"
  pinned_checkout "$KOKORO_REPO" "$KOKORO_COMMIT" "$PREFIX/src/kokoro"
  pinned_checkout "$MISAKI_REPO" "$MISAKI_COMMIT" "$PREFIX/src/misaki"
  rm -rf "$PREFIX/app.new" && install -d -m 0755 "$PREFIX/app.new"
  cp -r "$SRC_ROOT/tts/hermescall_tts" "$SRC_ROOT/tts/requirements.lock" "$PREFIX/app.new/"
  find "$PREFIX/app.new" -name '__pycache__' -prune -exec rm -rf {} +
  [[ -x $PREFIX/venv/bin/python ]] || python3 -m venv "$PREFIX/venv"
  "$PREFIX/venv/bin/pip" install -q --disable-pip-version-check --no-deps --require-hashes --only-binary=:all: \
    --index-url https://pypi.org/simple --extra-index-url https://download.pytorch.org/whl/cpu \
    -r "$PREFIX/app.new/requirements.lock"
  rm -rf "$PREFIX/app" && mv "$PREFIX/app.new" "$PREFIX/app"
  chown -R root:root "$PREFIX"
  chmod -R go-w "$PREFIX"
}

fetch() {
  local url=$1 sha=$2 target=$3
  [[ -f $target ]] && echo "$sha  $target" | sha256sum -c --quiet - 2>/dev/null && return 0
  runuser -u "$SERVICE_USER" -- curl -fsSL --proto '=https' --retry 3 -o "$target.part" "$url"
  echo "$sha  $target.part" | sha256sum -c --quiet - || { rm -f "$target.part"; die "$url does not match the pinned SHA-256"; }
  mv "$target.part" "$target"
}

download_models() {
  log "Downloading voices $VOICES (pinned revisions, verified)"
  fetch "$CONFIG_URL" "$CONFIG_SHA256" "$STATE/models/config.json"
  local voice files
  for voice in ${VOICES//,/ }; do
    read -r -a files <<<"${VOICE_FILES[$voice]}"
    runuser -u "$SERVICE_USER" -- install -d -m 0750 "$STATE/models/$voice"
    fetch "${files[0]}" "${files[1]}" "$STATE/models/$voice/model.pth"
    fetch "${files[2]}" "${files[3]}" "$STATE/models/$voice/voice.pt"
  done
}

write_settings() {
  cat >"$ETC/tts.env.tmp" <<EOF
VOICES=$VOICES
THREADS=$THREADS
PORT=$PORT
EOF
  chmod 0644 "$ETC/tts.env.tmp" && mv "$ETC/tts.env.tmp" "$ETC/tts.env"
}

start() {
  install -m 0644 "$SRC_ROOT/tts/deploy/$UNIT" "/etc/systemd/system/$UNIT"
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
  systemctl restart "$UNIT"
  log "Waiting for the voices to load"
  local _
  for _ in $(seq 120); do
    if curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      log "hermes-call-tts running on 127.0.0.1:$PORT with $VOICES"
      return 0
    fi
    sleep 1
  done
  die "hermes-call-tts did not answer on 127.0.0.1:$PORT (journalctl -u $UNIT)"
}

cmd_install() {
  need_root
  check_os
  load_settings
  install_packages
  create_user
  deploy_code
  download_models
  write_settings
  start
  cat <<EOF

German speech is ready. Point the bridge at it:
  bridge/install.sh update --language de --tts-url http://127.0.0.1:$PORT --voice ${VOICES%%,*}
EOF
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$UNIT"
  systemctl daemon-reload
  rm -rf "$PREFIX"
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$STATE" "$ETC"
    userdel "$SERVICE_USER" 2>/dev/null || true
    log "Removed the speech service and its models."
  else
    log "Removed the speech service; kept $STATE and $ETC (use --purge to delete)."
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

[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
