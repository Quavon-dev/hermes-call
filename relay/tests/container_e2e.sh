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
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv openssh-server python3 openssl dbus curl >/dev/null \
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
check "healthz reports version and checks" "curl -sk https://$IP/healthz | grep -q '\"database\": \"ok\"' &&
  curl -sk https://$IP/healthz | grep -q \"\$(sed -n 's/^version=//p' /opt/hermescall-relay/VERSION)\""
check "metrics are not public" "[[ \$(curl -sk -o /dev/null -w '%{http_code}' https://$IP/metrics) == 404 ]]"
check "coturn sandboxed (PrivateUsers, no privileged syscalls)" "
  [[ \$(systemctl show -p PrivateUsers --value hermescall-turn) == yes ]] &&
  systemctl show -p SystemCallFilter --value hermescall-turn | grep -q . &&
  systemctl is-active -q hermescall-turn"
check "TURN credentials cover the longest call" "grep -q '^ttl = 5400' /etc/hermescall-relay/relay.toml"
check "status shows the installed version" "/root/hc/relay/install.sh status 2>/dev/null | grep -q '^Hermes Call relay 0\.'"

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
check "update keeps the old code and a database snapshot" "
  [[ -d /opt/hermescall-relay.old && -s /var/lib/hermescall-relay/relay.db.pre-update ]] &&
  [[ \$(stat -c '%a %U' /var/lib/hermescall-relay/relay.db.pre-update) == '600 hermescall-relay' ]]"
check "rollback and forward again" "
  /opt/hermescall-relay/relay/install.sh rollback >/root/rollback.log 2>&1 && systemctl is-active -q hermescall-relay &&
  /opt/hermescall-relay/relay/install.sh rollback >>/root/rollback.log 2>&1 && systemctl is-active -q hermescall-relay &&
  hermescall-relay bridges | grep -q paired"
check "doctor finds a healthy relay" "hermescall-relay doctor >/root/doctor.log 2>&1; cat /root/doctor.log;
  grep -q '^ok    database' /root/doctor.log && grep -q '^ok    turn' /root/doctor.log && grep -q '^ok    relay' /root/doctor.log"
check "backup is private and restores on a wiped host" "
  PIN=\$(grep tls_pin /etc/hermescall-relay/relay.toml)
  /root/hc/relay/install.sh backup /root/relay-backup.tar.gz >/root/backup.log 2>&1 &&
  [[ \$(stat -c '%a' /root/relay-backup.tar.gz) == 600 ]] &&
  /root/hc/relay/install.sh uninstall --purge >/root/wipe.log 2>&1 && [[ ! -e /etc/hermescall-relay ]] &&
  /root/hc/relay/install.sh restore /root/relay-backup.tar.gz >/root/restore.log 2>&1 &&
  hermescall-relay bridges | grep -q paired && [[ \$(grep tls_pin /etc/hermescall-relay/relay.toml) == \"\$PIN\" ]] &&
  systemctl is-active -q hermescall-relay hermescall-turn"
check "own settings in relay.local.toml survive an update" "
  printf '[limits]\\nmax_devices_per_bridge = 7\\n' >/etc/hermescall-relay/relay.local.toml &&
  /opt/hermescall-relay/relay/install.sh update >/root/update2.log 2>&1 &&
  grep -q 'max_devices_per_bridge = 7' /etc/hermescall-relay/relay.local.toml && systemctl is-active -q hermescall-relay"
# A relay installed before the push gateway existed (no HC_PUSH_GATEWAY saved, no own key) must
# not start sending pushes through it on update: opt-in only.
check "update does not switch old relays to the push gateway" "
  sed -i -e '/^HC_PUSH_GATEWAY=/d' -e 's/^HC_APNS=.*/HC_APNS=no/' /etc/hermescall-relay/install.env &&
  /opt/hermescall-relay/relay/install.sh update >/root/update3.log 2>&1 &&
  grep -A1 '^\[push_gateway\]' /etc/hermescall-relay/relay.toml | grep -q 'enabled = false' &&
  grep -q '^HC_PUSH_GATEWAY=no' /etc/hermescall-relay/install.env &&
  /opt/hermescall-relay/relay/install.sh update --push-gateway default >/root/update4.log 2>&1 &&
  grep -A1 '^\[push_gateway\]' /etc/hermescall-relay/relay.toml | grep -q 'enabled = true'"
check "rotate TURN secret and push key" "
  SEC=\$(cat /etc/hermescall-relay/turn_secret); ID=\$(hermescall-relay push-id)
  /opt/hermescall-relay/relay/install.sh rotate turn-secret >/root/rotate.log 2>&1 &&
  /opt/hermescall-relay/relay/install.sh rotate push-key >>/root/rotate.log 2>&1 &&
  [[ \$(cat /etc/hermescall-relay/turn_secret) != \"\$SEC\" && \$(hermescall-relay push-id) != \"\$ID\" ]] &&
  grep -qF \"static-auth-secret=\$(cat /etc/hermescall-relay/turn_secret)\" /etc/hermescall-relay/turnserver.conf &&
  systemctl is-active -q hermescall-relay hermescall-turn"
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
