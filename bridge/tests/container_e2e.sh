#!/usr/bin/env bash
# shellcheck disable=SC2016  # verdict() evaluates its condition later, on purpose
# Full call test: relay container + "LXC 121" twin (Ubuntu 24.04) with the real
# bridge, faster-whisper and Kokoro; a fake Hermes echoes the caller's question.
# Requires a Kokoro-FastAPI container named "kokoro" (ghcr.io/remsky/kokoro-fastapi-cpu).
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=hc-e2e-publicnet
RELAY=hc-m2-relay
AGENT=hc-m2-agent
FAILED=0

cleanup() { [[ -n ${KEEP:-} ]] || docker rm -f "$RELAY" "$AGENT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

image() {
  docker build -q -t "$1" - >/dev/null <<EOF
FROM $2
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv python3 openssl dbus socat iproute2 >/dev/null \
 && rm -f /etc/machine-id && systemd-machine-id-setup
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
}

start() {
  docker run -d --name "$1" --hostname "$1" --network "$NET" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$ROOT":/src:ro "$2" >/dev/null
  docker exec "$1" systemctl is-system-running --wait >/dev/null 2>&1 || true
  docker exec "$1" bash -c "cp -r /src /root/hc"
}

in_relay() { docker exec "$RELAY" bash -c "$1"; }
in_agent() { docker exec "$AGENT" bash -c "$1"; }
check() { if in_agent "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILED=1; fi; }
verdict() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILED=1; fi; }

cleanup
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet 198.51.100.0/24 "$NET" >/dev/null
docker network connect --alias kokoro "$NET" kokoro 2>/dev/null || true
image hc-m2-debian debian:12
image hc-m2-ubuntu ubuntu:24.04
start "$RELAY" hc-m2-debian
start "$AGENT" hc-m2-ubuntu

RELAY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$RELAY")
in_relay "/root/hc/relay/install.sh install --ip $RELAY_IP --no-apns --no-push-gateway --non-interactive >/root/install.log 2>&1" ||
  { in_relay "tail -30 /root/install.log"; exit 1; }
LINK=$(in_relay "hermescall-relay pair" | grep -o "hermescall://[^']*")

in_agent "useradd -m hermes && install -d -o hermes -m 700 /home/hermes/.hermes && install -o hermes -m 600 /dev/null /home/hermes/.hermes/.env"
in_agent "socat TCP-LISTEN:8880,bind=127.0.0.1,reuseaddr,fork TCP:kokoro:8880 >/dev/null 2>&1 &"
in_agent "/root/hc/bridge/install.sh install --configure-hermes >/root/install.log 2>&1" || { in_agent "tail -30 /root/install.log"; exit 1; }
KEY=$(in_agent "grep ^API_SERVER_KEY= /home/hermes/.hermes/.env | cut -d= -f2")
in_agent "systemd-run -q --uid=hermes --unit=fake-hermes python3 /root/hc/bridge/tests/fake_hermes.py $KEY /tmp/hermes.log && chmod 755 /root"
in_agent "hermes-call-bridge relay add '$LINK' && systemctl restart hermes-call-bridge"
in_agent "for i in \$(seq 60); do hermes-call-bridge status 2>/dev/null | grep -q '\"connected\": true' && exit 0; sleep 1; done; journalctl -u hermes-call-bridge -n 30 --no-pager; exit 1"

TC="PYTHONPATH=/opt/hermes-call-bridge/common:/opt/hermes-call-bridge/bridge:/root/hc/testclient HERMESCALL_TESTCLIENT_STATE=/root/tc.json /opt/hermes-call-bridge/venv/bin/python -m hermescall_testclient"
OFFER=$(in_agent "runuser -u hermes-call-bridge -- /opt/hermes-call-bridge/venv/bin/python -c \"
import json,urllib.request
t=open('/etc/hermes-call-bridge/api_token').read().strip()
r=urllib.request.Request('http://127.0.0.1:8765/v1/devices/pairing',data=b'{\\\"name\\\":\\\"E2E phone\\\"}',headers={'Authorization':'Bearer '+t})
print(json.load(urllib.request.urlopen(r))['code'])\"")
check "phone pairs with typed code (TOFU pin confirmed by CPace)" "$TC pair $RELAY_IP $OFFER --name 'E2E phone' --trust-self-signed"
check "bridge lists the device" "hermes-call-bridge device list | grep -q 'E2E phone'"

echo "--- app calls the agent (WAV question, recorded answer):"
in_agent "cd /root && $TC call --wav /root/hc/bridge/tests/data/question.wav --record /root/reply.wav --seconds 15 --approve deny" | tee /tmp/hc-call.log || true
verdict "bridge advertised relay candidates only" 'grep -q "candidate types: relay\." /tmp/hc-call.log'
TRANSCRIBE="PYTHONPATH=/opt/hermes-call-bridge/common:/opt/hermes-call-bridge/bridge /opt/hermes-call-bridge/venv/bin/python -c \"
import sys
from faster_whisper import WhisperModel
m = WhisperModel('/var/lib/hermes-call-bridge/models/base.en', compute_type='int8')
print(' '.join(s.text for s in m.transcribe(sys.argv[1], language='en')[0]))\""
REPLY=$(in_agent "$TRANSCRIBE /root/reply.wav" 2>/dev/null || true)
echo "Agent said: $REPLY"
verdict "round trip: Whisper → Hermes → Kokoro → back to phone" 'grep -qi calendar <<<"$REPLY"'
check "Hermes got session id, auth and phone system prompt" "grep -q '\"auth_ok\": true, \"session\": \"hermes-call-phone\", \"stream\": true, \"roles\": \\[\"system\", \"user\"\\]' /tmp/hermes.log"

check "call_owner plugin installed for the Hermes user" "[[ \$(stat -c '%U' /home/hermes/.hermes/plugins/hermes-call/__init__.py) == hermes ]]"
check "Hermes .env holds the ring-only token, not the admin token" "grep -qx \"HERMES_CALL_TOKEN=\$(cat /etc/hermes-call-bridge/call_token)\" /home/hermes/.hermes/.env && ! grep -q \"\$(cat /etc/hermes-call-bridge/api_token)\" /home/hermes/.hermes/.env"
check "ring-only token cannot pair devices" "python3 -c \"
import urllib.error, urllib.request
token = open('/etc/hermes-call-bridge/call_token').read().strip()
request = urllib.request.Request('http://127.0.0.1:8765/v1/devices/pairing', data=b'{}', headers={'Authorization': 'Bearer ' + token})
try:
    urllib.request.urlopen(request)
    raise SystemExit(1)
except urllib.error.HTTPError as error:
    raise SystemExit(error.code != 403)\""

echo "--- the agent calls the phone (Hermes plugin tool call_owner):"
in_agent "cd /root && ($TC listen --once --wav /root/hc/bridge/tests/data/question.wav --record /root/outbound.wav --seconds 20 --delay 7 >/tmp/listen.log 2>&1 &) ; sleep 4; runuser -u hermes -- env \$(grep ^HERMES_CALL_TOKEN= /home/hermes/.hermes/.env) python3 /root/hc/bridge/tests/hermes_plugin_call.py /home/hermes/.hermes/plugins/hermes-call/__init__.py 'backup finished' 'Good evening, this is Hermes. Your backup has finished.'" | tee /tmp/hc-ring.log
sleep 22
verdict "call_owner: ring answered by the phone" "grep -q '\"status\": \"answered\"' /tmp/hc-ring.log"
OUT=$(in_agent "$TRANSCRIBE /root/outbound.wav" 2>/dev/null || true)
echo "Agent opened with: $OUT"
verdict "first_message spoken on answer" 'grep -qi "backup has finished" <<<"$OUT"'
verdict "phone's reply answered after the greeting" 'grep -qi calendar <<<"$OUT"'

check "no transcripts or keys in bridge logs" "! journalctl -u hermes-call-bridge --no-pager | grep -qiE 'calendar|backup has|$KEY'"
check "bridge listens on loopback only" "! ss -ltnup | grep -E 'python' | grep -vq '127.0.0.1'"
check "secrets 0600 owned by hermes-call-bridge" "[[ \$(stat -c '%a %U' /etc/hermes-call-bridge/api_token /etc/hermes-call-bridge/call_token /etc/hermes-call-bridge/hermes_api_key | sort -u) == '600 hermes-call-bridge' ]]"
check "Hermes .env still 0600 owned by hermes" "[[ \$(stat -c '%a %U' /home/hermes/.hermes/.env) == '600 hermes' ]]"
in_agent "echo \"bridge memory (RSS): \$((\$(ps -o rss= -p \$(systemctl show -p MainPID --value hermes-call-bridge)) / 1024)) MB\"; journalctl -u hermes-call-bridge --no-pager | grep -E 'latency|turn timings' | sed 's/.*: //' | tail -6"

if [[ $FAILED -ne 0 ]]; then echo "FAILURES"; exit 1; fi
echo "ALL PASSED"
