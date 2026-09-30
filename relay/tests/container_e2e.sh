#!/usr/bin/env bash
# Full installer test in a systemd container: ./relay/tests/container_e2e.sh debian:12|ubuntu:24.04
set -Eeuo pipefail

IMAGE=${1:-debian:12}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TAG=hc-e2e-$(tr ':.' '--' <<<"$IMAGE")
NAME=$TAG-run

NET=hc-e2e-publicnet
cleanup() { [[ -n ${KEEP:-} ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -q -t "$TAG" - >/dev/null <<EOF
FROM $IMAGE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv openssh-server python3 openssl dbus >/dev/null \
 && rm -f /etc/machine-id && systemd-machine-id-setup
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

cleanup
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet 198.51.100.0/24 "$NET" >/dev/null
docker run -d --name "$NAME" --network "$NET" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$ROOT":/src:ro "$TAG" >/dev/null
docker exec "$NAME" systemctl is-system-running --wait >/dev/null 2>&1 || true
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")

run() { docker exec "$NAME" bash -c "$1"; }
check() { if run "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILED=1; fi; }
FAILED=0

run "cp -r /src /root/hc && openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt > /root/AuthKey_TEST.p8"
run "/root/hc/relay/install.sh install --ip $IP --apns-key /root/AuthKey_TEST.p8 --apns-key-id ABCDEFGHIJ --team-id TEAMID1234 \
  --bundle-id de.quavon.hermescall --non-interactive >/root/install.log 2>&1" || { run "tail -40 /root/install.log"; exit 1; }

check "services active" "systemctl is-active -q hermescall-relay hermescall-turn caddy"
check "secrets are 0600 and owned by their service" "
  [[ \$(stat -c '%a %U' /etc/hermescall-relay/turn_secret) == '600 hermescall-relay' ]] &&
  [[ \$(stat -c '%a %U' /etc/hermescall-relay/apns_key) == '600 hermescall-relay' ]] &&
  [[ \$(stat -c '%a %U' /etc/hermescall-relay/push_gateway_key) == '600 hermescall-relay' ]] &&
  [[ \$(stat -c '%a %U' /etc/hermescall-relay/turnserver.conf) == '600 turnserver' ]] &&
  [[ \$(stat -c '%a %U' /etc/hermescall-relay/install.env) == '600 root' ]]"
check "coturn loaded its config (auth enabled)" "! journalctl -u hermescall-turn --no-pager | grep -q 'Cannot find config file'"
check "relay loaded TURN secret and APNs key" "journalctl -u hermescall-relay --no-pager | grep -q 'push own APNs key' && ! journalctl -u hermescall-relay --no-pager | grep -q 'TURN secret missing'"
check "services run unprivileged" "[[ \$(ps -o user= -C turnserver) == turnserver ]] && ps -o user= -p \$(systemctl show -p MainPID --value hermescall-relay) | grep -q hermescall"
check "relay only on loopback" "ss -ltn | grep -q '127.0.0.1:8743' && ! ss -ltn | grep -q '0.0.0.0:8743'"
check "no HTTP/3 or port 80 listener" "! ss -lun | grep -q ':443 ' && ! ss -ltn | grep -q ':80 '"
check "firewall default drop" "nft list chain inet hermescall input | grep -q 'policy drop'"
check "firewall keeps SSH reachable" "nft list chain inet hermescall input | grep -q 'tcp dport 22'"
check "HTTPS health through Caddy" "python3 -c \"import ssl,urllib.request; c=ssl._create_unverified_context(); urllib.request.urlopen('https://$IP/healthz', context=c, timeout=5)\""

docker cp "$ROOT/relay/tests/smoke_deployed.py" "$NAME:/root/smoke.py"
check "pairing + auth + routing + revoke over TLS with pin" "
  URI=\$(hermescall-relay pair | grep -o \"hermescall://[^']*\")
  PYTHONPATH=/opt/hermescall-relay/common python3 /root/smoke.py \"\$URI\" >/root/smoke.log 2>&1"
run "cat /root/smoke.log"
CREDS=$(run "sed -n 's/.*user=\\([^ ]*\\) cred=\\(.*\\)/\\1 \\2/p' /root/smoke.log")
TURN_USER=${CREDS% *}
TURN_CRED=${CREDS#* }
check "TURN relays with ephemeral credentials" "turnutils_uclient -u '$TURN_USER' -w '$TURN_CRED' -y -n 3 $IP 2>&1 | grep -q 'Total lost packets 0'"
check "TURN rejects wrong credentials" "! turnutils_uclient -u '$TURN_USER' -w wrong -y -n 1 $IP 2>&1 | grep -q 'Total lost packets 0'"
check "TURN refuses LAN peers" "! turnutils_uclient -u '$TURN_USER' -w '$TURN_CRED' -e 192.168.1.20 -n 1 $IP 2>&1 | grep -q 'Total lost packets 0'"
check "TURN refuses IPv4-mapped IPv6 LAN peers" "! turnutils_uclient -u '$TURN_USER' -w '$TURN_CRED' -e ::ffff:192.168.1.20 -n 1 $IP 2>&1 | grep -q 'Total lost packets 0'"
check "TURN refuses unauthenticated use" "! turnutils_uclient -y -n 1 $IP 2>&1 | grep -q 'Total lost packets 0'"
check "logs contain no secrets" "
  S=\$(cat /etc/hermescall-relay/turn_secret); ! journalctl --no-pager | grep -qF \"\$S\""

check "re-run install is idempotent (keeps pin + secret)" "
  PIN=\$(grep tls_pin /etc/hermescall-relay/relay.toml); SEC=\$(cat /etc/hermescall-relay/turn_secret)
  /root/hc/relay/install.sh install --non-interactive >/root/install2.log 2>&1 &&
  [[ \$(grep tls_pin /etc/hermescall-relay/relay.toml) == \"\$PIN\" && \$(cat /etc/hermescall-relay/turn_secret) == \"\$SEC\" ]] &&
  hermescall-relay bridges | grep -q 'devices=0'"
check "update keeps data" "/opt/hermescall-relay/relay/install.sh update >/root/update.log 2>&1 && hermescall-relay bridges | grep -q paired"
# A host that had no /etc/nftables.conf before the relay: nothing to restore, and the relay's
# default-drop table must still go (it would otherwise keep blocking every other service).
check "uninstall without an earlier nftables.conf removes the firewall table" "
  rm -f /etc/nftables.conf.hermescall-backup &&
  /opt/hermescall-relay/relay/install.sh uninstall >/root/uninstall1.log 2>&1 &&
  ! nft list table inet hermescall >/dev/null 2>&1 && ! grep -q 'table inet hermescall' /etc/nftables.conf &&
  [[ -s /var/lib/hermescall-relay/relay.db ]]"
check "uninstall --purge removes everything" "
  /root/hc/relay/install.sh uninstall --purge >/root/uninstall.log 2>&1 &&
  [[ ! -e /opt/hermescall-relay && ! -e /etc/hermescall-relay && ! -e /etc/systemd/system/hermescall-relay.service ]] &&
  ! systemctl is-active -q hermescall-turn"

if [[ $FAILED -ne 0 ]]; then echo "FAILURES ($IMAGE)"; exit 1; fi
echo "ALL PASSED ($IMAGE)"
