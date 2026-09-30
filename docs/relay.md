# Relay: install, operate, troubleshoot

The relay is the only internet-facing component. It forwards opaque, end-to-end
encrypted signaling between your bridge and your devices, hands out short-lived
TURN credentials, relays encrypted media (coturn) and sends pushes to the phones: through the
Hermes Call [push gateway](push-gateway.md) (`hermes-push.quavon.de`, the default for new
installs, no Apple account needed) or with your own APNs key if you build the app yourself.
It cannot read audio, text or signaling content (see [THREAT_MODEL.md](../THREAT_MODEL.md)).

Supported hosts: **Debian 12, Debian 13, Ubuntu 24.04** — a dedicated VPS, an LXC or a VM.
The installer owns the host's Caddy, coturn and nftables configuration. Prefer containers?
See [Docker Compose](#docker-compose).

## Open ports (exactly these)

| Port | Proto | Why |
|---|---|---|
| 443 | TCP | TLS (Caddy): WebSocket signaling + pairing. Let's Encrypt uses TLS-ALPN on this port, so **port 80 stays closed**. |
| 3478 | UDP + TCP | TURN control (UDP preferred; TCP for networks that block UDP). |
| 49160–49200 | UDP | TURN media relay ports (≈20 concurrent calls; each call uses 2). `--turn-ports` changes the range. |
| 5349 | TCP | Only with `--turns`: TURN over TLS, for networks that let nothing but TLS through. |
| 22 | TCP | VPS only: SSH, keys only (`--harden-ssh`), fail2ban, rate-limited. |

Everything else inbound is dropped (nftables, `policy drop`). The relay daemon
itself listens only on `127.0.0.1:8743`. HTTP/3 (UDP 443) and coturn's alternate
port 3479 are disabled/blocked.

TURN is locked down: ephemeral HMAC credentials issued only to paired bridges/devices, no TCP
relaying, bandwidth cap, and **peers in private ranges (RFC 1918, CGNAT, loopback, link-local,
ULA) are refused** so nobody can use the relay to reach your LAN. Credentials are valid for 90
minutes: longer than the longest call (the bridge ends calls after 60 minutes) plus ringing and
ICE restarts. coturn checks the credential's expiry when an allocation is created; refreshes of a
running allocation keep working after it (coturn caches the key per session), so only a new
allocation mid-call (network change) needs credentials that are still valid.

IPv6: if the host has a global IPv6 address and the domain an AAAA record, phones and bridges
reach signaling and TURN over IPv6 as well; the firewall rules cover both families, TURN needs no
NAT mapping for IPv6, and the private-range block list includes the IPv6 ones. An IPv6-only host
works for phones on IPv6 networks only; keep IPv4.

## Install on a VPS

Install from a **signed release**, not from a checkout of `main` (which may hold unreleased code).
On the VPS, as root, download the latest release and check its signature and checksum as described in
[Verify a release by hand](releasing.md#verify-a-release-by-hand): the release key, `ssh-keygen -Y verify`
on `MANIFEST`, the tarball's SHA-256. Only when both checks pass, unpack it and run the installer:

```bash
tar -xzf /tmp/hc/hermes-call.tar.gz -C /opt
/opt/hermes-call/relay/install.sh install --domain relay.example.com --no-apns --harden-ssh
```

`install.sh` installs distribution packages, creates the unprivileged users
`hermescall-relay` (daemon) and `turnserver` (coturn), writes configs/secrets
(mode 600), enables the firewall and starts the services. It installs the relay code into
`/opt/hermescall-relay`; the unpacked `/opt/hermes-call` is only the installer's source.

Pushes then go through the [push gateway](push-gateway.md): incoming calls ring and chat
notifications arrive also when the app is closed. `--no-push-gateway` turns that off (calls then
ring only while the app is open).

**Your own build of the app** (own team and bundle ID) needs your own APNs key instead, because
the gateway can only push to the published app:

```bash
scp ~/Downloads/AuthKey_ABCDE12345.p8 root@relay.example.com:/root/
```

```bash
ssh root@relay.example.com '/opt/hermescall-relay/relay/install.sh install --apns-key /root/AuthKey_ABCDE12345.p8 --apns-key-id ABCDE12345 --team-id TEAMID1234 --bundle-id com.example.hermescall && shred -u /root/AuthKey_ABCDE12345.p8'
```

The DNS A record for the domain must point at the VPS before you run it
(Let's Encrypt validates on 443). With only an IP, use `--ip 203.0.113.7`: the
relay gets a 10-year self-signed certificate and the app pins its public key via
the QR code/pairing handshake.

The installer ends by printing a **one-time bridge pairing code + QR**. New code
any time (valid 10 minutes, 3 attempts):

```bash
hermescall-relay pair
```

Installer options worth knowing: `--turn-ports 50000-50100` (a bigger media range: 2 ports per
call), `--turn-quota 200` (concurrent TURN allocations in total), `--turns` (TURN over TLS on
5349, with `--tls acme` only: phones check the certificate), `--no-firewall` (you manage the
firewall, e.g. in Proxmox). `install.sh --help` lists all of them.

### Updates, rollback and status

Download and verify the next release the same way as for the install
([Verify a release by hand](releasing.md#verify-a-release-by-hand)), replace the unpacked copy with it and
run `update` from there:

```bash
rm -rf /opt/hermes-call && tar -xzf /tmp/hc/hermes-call.tar.gz -C /opt
/opt/hermes-call/relay/install.sh update
/opt/hermescall-relay/relay/install.sh status        # installed version and commit, services
/opt/hermescall-relay/relay/install.sh rollback      # back to the code before the last update
```

`update` keeps settings, keys and paired devices, keeps the previous code in
`/opt/hermescall-relay.old` and takes a database snapshot
(`/var/lib/hermescall-relay/relay.db.pre-update`); running the same update again keeps both. `rollback` swaps the code back (run it again to
return); the database stays, because schema changes so far only add. `rollback --restore-db` also
puts the snapshot back (whatever was paired or queued since the update is then lost).

`update` refuses code older than the installed version (a replayed old release). To go back on
purpose, prefer `rollback`; to install an older release anyway, add `--allow-downgrade` (or put
`HC_ALLOW_DOWNGRADE=1` in front of the command).

A relay installed before the push gateway existed keeps sending no pushes after `update`, as
before. To use the gateway: `install.sh update --push-gateway default`.

### Everyday commands

```bash
hermescall-relay bridges                  # paired bridges and their device count
hermescall-relay devices                  # paired devices (id, bridge, push kinds)
hermescall-relay revoke-device <id>       # a lost phone; it is disconnected within 15 s
hermescall-relay revoke-bridge <id>       # removes the bridge and all its devices
hermescall-relay stats                    # counts, stored bytes, disk space, schema version
hermescall-relay doctor                   # DNS, TLS expiry, TURN, push, clock, disk, the service
hermescall-relay push-id                  # this relay's identity at the push gateway
/opt/hermescall-relay/relay/install.sh uninstall    # add --purge to delete keys, config, database
```

## Backup and restore

What matters: the database (paired bridges and devices, queued messages, attachments' index),
the keys in `/etc/hermescall-relay` and, for a relay on an IP address, the self-signed TLS key in
`/etc/caddy/hermescall` (phones pin it: a new key means pairing everything again).

```bash
/opt/hermescall-relay/relay/install.sh backup                    # /root/hermescall-relay-backup-<date>.tar.gz
/opt/hermescall-relay/relay/install.sh backup /root/relay.tar.gz
```

The database is copied with SQLite's online backup API, so the relay keeps running. The archive
(mode 600) contains the relay's secrets: keep it like a password, off the host. Attachments
themselves (`/var/lib/hermescall-relay/blobs`) are not in it; they expire after 7 days anyway,
and phones fetch the rest from the bridge.

Restore, on the same host or a new one with the same address (clone the repository first there):

```bash
/root/hermes-call/relay/install.sh restore /root/relay.tar.gz
```

It checks the archive's database first (integrity, schema), stops the services, keeps the current
database as `relay.db.pre-restore`, puts back the database, config and keys, then runs the normal
install with the restored settings. Bridges and phones reconnect by themselves when the address and TLS key are
unchanged. Moving to a new domain needs a new pairing of the bridge.

Docker users: `hermescall-relay backup FILE` / `restore FILE` (see [Docker Compose](#docker-compose)).

## Rotating secrets

| What | Command | Effect |
|---|---|---|
| TURN secret | `install.sh rotate turn-secret` | new coturn secret; calls in progress may drop; do it when nobody is on a call |
| Push gateway key | `install.sh rotate push-key` | new relay identity at the gateway (`hermescall-relay push-id`); blocks nothing, pushes continue |
| Own APNs key | `install.sh rotate apns-key --apns-key AuthKey_NEW.p8 --apns-key-id NEWKEYID` | switch to the new .p8, then revoke the old one at developer.apple.com |
| TLS key (IP relays) | `rm /etc/caddy/hermescall/*.pem && install.sh update` | new pin: bridges and phones must pair again |

A leaked relay backup means: rotate the TURN secret and the push key, and revoke devices you do not
trust. Device and bridge keys never leave their devices, so the relay cannot leak those.

## Limits and settings

The installer writes `/etc/hermescall-relay/relay.toml` on every install and update. Your own
settings go into **`/etc/hermescall-relay/relay.local.toml`**, which is read on top of it and never
touched by the installer (restart with `systemctl restart hermescall-relay`):

```toml
log_level = "info"      # debug, info, warning, error
log_format = "json"     # or "text"

[limits]
max_devices_per_bridge = 5
storage_max_bytes = 4294967296

[metrics]
port = 9743             # Prometheus /metrics on 127.0.0.1:9743; off (0) by default
```

`[limits]` (all optional; unknown names and non-positive values are refused at start):

| Name | Default | Meaning |
|---|---|---|
| `max_connections` / `max_unauthenticated` / `max_connections_per_ip` | 500 / 200 / 16 | WebSocket connections |
| `handshake_timeout` | 15 s | time for the authentication handshake |
| `messages_per_window` / `message_window_seconds` | 200 / 10 s | messages per connection before it is closed |
| `pair_per_minute`, `pair_session_timeout` | 20, 90 s | pairing attempts per IP, duration of one |
| `slot_ttl`, `max_slots_per_bridge`, `max_slot_attempts` | 600 s, 5, 3 | device pairing codes |
| `max_devices_per_bridge` | 20 | paired phones per bridge |
| `turn_requests_per_minute`, `rings_per_minute` | 6, 10 | per identity / per bridge |
| `mails_per_minute`, `alerts_per_window`, `alert_window_seconds`, `mail_ack_grace` | 120, 20, 600 s, 3 s | mailbox |
| `mail_max_messages`, `mail_max_bytes`, `mail_ttl_seconds` | 500, 20 MiB, 7 days | per phone |
| `blob_max_per_recipient`, `blob_quota_bytes`, `blob_ttl_seconds` | 20, 50 MiB, 7 days | attachments per recipient |
| `blob_uploads_per_hour`, `blob_tickets_per_hour`, `blob_ticket_seconds` | 60, 240, 300 s | attachment tickets |
| `max_blob_transfers`, `max_blob_downloads` | 20, 20 | transfers at the same time (a full relay answers 503; clients retry) |
| `blob_upload_seconds`, `blob_download_seconds`, `blob_download_uses` | 300 s, 300 s, 3 | per transfer; a download ticket works 3 times |
| `storage_max_bytes` | 2 GiB | mailbox + attachments on this relay in total |
| `min_free_bytes` | 256 MiB | free disk kept; below it new mail/attachments are refused and `/healthz` is 503 |
| `sweep_seconds`, `expiry_sweep_seconds` | 15 s, 600 s | revocation check; expiry of mail/attachments and space reclaim |

Live Activity push limits (1 update per 3 s, 1 start per 30 s and 20 per hour, 30 ends per hour
per phone) are fixed.

**Scaling:** one relay is one process with one SQLite database (single writer). It is sized for
households and small teams (hundreds of connections); there is no clustering or high
availability. Run more relays rather than a bigger one.

## Health, metrics, logs

`GET /healthz` (public, also through Caddy): `200 {"status": "ok", "checks": {"database",
"disk", "push"}}`; `"degraded"` (still 200) when the push gateway is unreachable; **503**
`"unhealthy"` when the database is not writable or the disk is below `min_free_bytes`. The answer
is cached for 5 seconds and each address may ask 60 times a minute (then `429`). The exact
`"version"` is added only for local requests (from `127.0.0.1` straight to port 8743, as the
installer, `doctor` and the Docker health check do: `curl -s http://127.0.0.1:8743/healthz`); to
show it to everyone, set `public_version = true` under `[health]` in `relay.local.toml`. The
version is also on `/metrics` (`hermescall_relay_build_info`) and in `install.sh status`.

`/metrics` (Prometheus text format) is served only on the separate metrics listener
(`[metrics] port`, default off, `127.0.0.1`), never on the public port. It has connections by
role, paired bridges/devices, stored bytes and items, disk free, transfers in progress,
refusals by limit (`hermescall_relay_rate_limited_total{limit=…}`), push results and APNs/gateway
answers by status, expired items and the version. No identities, tokens or addresses.

Logs go to the journal (`journalctl -u hermescall-relay`) as text or JSON lines (`log_format`).
They contain no push tokens, keys, codes or message content — only event names, short (6-char)
id prefixes and APNs status codes. Caddy access logs are off.

Maintenance runs inside the relay: expired mail and attachments are removed every 10 minutes
even when nobody sends anything, and freed database pages go back to the disk bit by bit. A
database from relay 0.6.2 or older is converted to incremental vacuum once it is mostly empty;
`hermescall-relay compact` does it at once (the database is locked while it runs). The schema is
versioned (`PRAGMA user_version`) and migrated automatically at start.

On `systemctl stop` / restart the relay closes connections with "going away" (clients reconnect
at once) and first sends the chat notifications that were still waiting for a phone's ack.

## Behind your own reverse proxy (Nginx Proxy Manager, Traefik, Caddy)

If a reverse proxy already publishes your services on 443, let it terminate TLS for the relay too:

```bash
/opt/hermescall-relay/relay/install.sh install --domain relay.example.com --tls proxy --proxy-from 192.168.0.10
```

The relay then listens on plain HTTP port **8743**; the firewall lets only `--proxy-from` (comma-
separated addresses or CIDRs, default: the private ranges) reach it, and only their
`X-Forwarded-For` is believed, so phones and bridges keep their own rate limits. With several
proxies in a row (e.g. a CDN, then your proxy) list all of them: the relay takes the first address
from the right that is not one of your proxies. The installer's Caddy is switched off. In Nginx
Proxy Manager: a proxy host for the domain, scheme `http`, forward to the relay's LAN address,
port 8743, **Websockets Support** on, an SSL certificate and *Force SSL*. TURN cannot go through
an HTTP proxy: forward TCP/UDP 3478 and UDP 49160–49200 from the router straight to the relay.
Back to the relay's own certificate: `install.sh install --tls acme`.

## Docker Compose

`relay/deploy/docker-compose.yml` runs the relay image (`ghcr.io/quavon-dev/hermes-call-relay`,
non-root, read-only root file system, health check), coturn (host network, for its port range)
and Caddy (Let's Encrypt via TLS-ALPN). Copy `relay/deploy/` to the host and follow the steps at
the top of the file: `config/relay.toml` from `compose/relay.toml.example`, `config/turnserver.conf`
from `compose/turnserver.conf.example` with the same TURN secret as `config/turn_secret`, a push
gateway key, then `RELAY_DOMAIN=relay.example.com docker compose up -d`.

`trusted_proxies` in `relay.toml` must be Caddy's fixed address (`172.30.87.10/32` in the
file): without it every client would share Caddy's address and one set of rate limits. Trust only
that address, not the whole Compose network: `172.30.87.1` is the bridge gateway, i.e. the host
and anything Docker forwards, and whatever is trusted may set `X-Forwarded-For` to any address.
The same applies in Kubernetes (the ingress controller's pod network).

**Docker's userland proxy.** Caddy only sees real client addresses when Docker forwards port 443
with iptables/nftables NAT (the default on Linux). Where Docker uses its userland proxy instead
(`"userland-proxy": true` together with `"iptables": false` in `/etc/docker/daemon.json`, rootless
Docker, Docker Desktop), and whenever a client connects over IPv6 to a host whose Compose network
is IPv4 only, Docker's proxy opens the connection to Caddy itself: every phone and bridge then
appears as `172.30.87.1` and shares one set of rate limits, pairing lockouts and connection caps.
If failed pairing attempts from one phone lock out every other client, this is the cause. Then publish 443 with NAT (keep
`iptables` on), give the Compose network IPv6 (`enable_ipv6: true` with an IPv6 subnet) if clients
reach the host over IPv6, or run Caddy with `network_mode: host`. Do not add `172.30.87.1` to
`trusted_proxies`; that would not bring the addresses back and would let the host forge them.

```bash
docker compose exec relay python3 -m hermescall_relay.cli --config /etc/hermescall-relay/relay.toml pair
docker compose exec relay python3 -m hermescall_relay.cli --config /etc/hermescall-relay/relay.toml backup /var/lib/hermescall-relay/backup.tar.gz
```

`restore` runs with the relay stopped (`docker compose run --rm relay -m hermescall_relay.cli
--config … restore FILE`). Pin the image digests once it works.

## Install on a home server (Proxmox or any LXC/VM host)

> **Check first:** many cable and fibre lines have **no public IPv4** (DS-Lite, carrier-grade
> NAT). Then nothing from the internet can reach your home and the relay must run on a VPS. Your
> router's status page shows whether its WAN address is public (not `100.64.x.x`, not private).

On Proxmox the [helper script](../proxmox-helper/README.md) creates the container and installs the
relay in one command. By hand:

### 1. Create the container (Proxmox host shell)

```bash
pveam update && pveam available --section system | grep debian-13
```

```bash
pveam download local debian-13-standard_13.1-2_amd64.tar.zst
```

(Use the exact file name the previous command printed.) This creates an unprivileged container
with 1 core, 512 MB RAM and 4 GB disk; `nesting=1` lets systemd apply its service sandboxing
inside the container. `130` is the container id, pick a free one:

```bash
pct create 130 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst --hostname hermes-relay --unprivileged 1 --features nesting=1 --cores 1 --memory 512 --swap 256 --rootfs local-lvm:4 --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1 --onboot 1 --start 1
```

Download and verify the release on the Proxmox host
([Verify a release by hand](releasing.md#verify-a-release-by-hand)), then copy it into the container
and install from it:

```bash
pct push 130 /tmp/hc/hermes-call.tar.gz /root/hermes-call.tar.gz
```

```bash
pct exec 130 -- bash -c 'tar -xzf /root/hermes-call.tar.gz -C /opt && /opt/hermes-call/relay/install.sh install --domain relay.example.com --no-apns --non-interactive'
```

Updates work as on a VPS: verify the next release on the host, `pct push` it, unpack it over a
removed `/opt/hermes-call` and run `/opt/hermes-call/relay/install.sh update` in the container.

Behind NAT the installer detects the public IP and configures coturn's `external-ip`; a timer
re-checks it every 5 minutes (dynamic home IPs). Own APNs key (own app builds only): copy it in
with `pct push 130 AuthKey_X.p8 /root/AuthKey_X.p8 --perms 600` and add the `--apns-key` options.

### 2. Isolate it from your LAN

The relay never needs to open connections into your LAN — the bridge connects *out* to it. Block
everything from the relay to private ranges except DNS to your router. On Proxmox, create
`/etc/pve/firewall/130.fw` on the host (replace `192.168.1.1` with your router/DNS server):

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p tcp -dport 443
IN ACCEPT -p tcp -dport 3478
IN ACCEPT -p udp -dport 3478
IN ACCEPT -p udp -dport 49160:49200
OUT ACCEPT -p udp -dest 192.168.1.1 -dport 53
OUT ACCEPT -p tcp -dest 192.168.1.1 -dport 53
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
```

The Proxmox firewall is stateful: replies to the bridge's outbound connection are still allowed.

> **Warning — do not lock yourself out.** Container rules only take effect when the firewall is
> enabled at *Datacenter → Firewall → Options*. Enabling it there with an inbound policy of DROP
> also filters the Proxmox host itself. Before you switch it on, add datacenter rules that allow
> TCP 8006 (web UI) and TCP 22 from your LAN, or leave the datacenter input policy at ACCEPT.

Stronger isolation: put the relay on its own bridge/VLAN, for example a guest network or DMZ port
your router keeps apart from the home network. The rules above still apply. Other hypervisors
(libvirt, TrueNAS, a plain Docker host) have equivalent per-guest firewalls; the rule set is the
same.

### 3. Forward only the relay ports

On the router, forward TCP 443, TCP 3478, UDP 3478 and UDP 49160–49200 (plus TCP 5349 with
`--turns`) to the relay container — **nothing** to the bridge or the Hermes host. Point a domain
(A record) at your public IP and keep it updated with the router's DynDNS client. DNS is only a
name lookup; it is not in the call path.

Example (one owner's setup): Proxmox with the relay as LXC 130 on `vmbr0`, the Hermes agent and
bridge in another container that gets no port forward at all, a FRITZ!Box forwarding the four
relay ports (*Internet → Permit Access → Port Sharing*) and updating DynDNS.

## Where the secrets live

| File | Owner | Mode | Content |
|---|---|---|---|
| `/etc/hermescall-relay/apns_key` | hermescall-relay | 600 | own APNs .p8 key (own app builds only) |
| `/etc/hermescall-relay/push_gateway_key` | hermescall-relay | 600 | Ed25519 key that signs requests to the push gateway |
| `/etc/hermescall-relay/turn_secret` | hermescall-relay | 600 | TURN HMAC secret |
| `/etc/hermescall-relay/turnserver.conf` | turnserver | 600 | coturn config (contains TURN secret) |
| `/etc/hermescall-relay/turn-tls/` | root:turnserver | 640 | copy of the TLS certificate for TURNS (`--turns` only) |
| `/etc/hermescall-relay/install.env` | root | 600 | installer answers (no secrets) |
| `/etc/caddy/hermescall/key.pem` | caddy | 600 | self-signed TLS key (IP mode) |
| `/var/lib/hermescall-relay/relay.db` | hermescall-relay | 600 | bridge/device public keys, push tokens, queued ciphertext |
| `/var/lib/hermescall-relay/relay.db.pre-update` | hermescall-relay | 600 | snapshot from the last update |

## Troubleshooting

More symptoms across the app, bridge and relay are in [Troubleshooting](troubleshooting.md). Start with `hermescall-relay doctor`: it checks the database, disk, the running service, DNS, the
TLS certificate's expiry, whether coturn answers, push (own key or gateway) and the clock.

**Calls connect but there is no audio, or they fail on mobile data.** TURN is not reachable. Check
from outside your network that UDP 3478 and the media range reach the relay (router forwards,
cloud firewall, Proxmox firewall). Behind NAT, `grep external-ip /etc/hermescall-relay/turnserver.conf`
must show your current public IP (`install.sh refresh-ip` updates it). `journalctl -u
hermescall-turn` shows `401` for wrong credentials (clock off by more than the credential
lifetime, or a rotated secret while a call ran) and `403 Forbidden IP` for blocked peers.
Networks that allow only TLS: install with `--turns`.

**Pushes do not arrive (calls ring only while the app is open).** `hermescall-relay doctor` shows
the push mode. With the gateway: `journalctl -u hermescall-relay | grep "push gateway"`:
`status=401 error=unauthorized` means the relay's **clock** is off by more than 60 s (`timedatectl`
should say "System clock synchronized: yes"; install `systemd-timesyncd` or `chrony`);
`status=403 error=blocked` means the gateway operator blocked this relay; `error=token_bound`
means more than five relays used this phone's push token within 30 days (wait, or reinstall the
app for a new token). With your own key: `apns rejected push: status=403 reason=InvalidProviderToken`
is a wrong key id/team id, `BadDeviceToken` a sandbox build talking to production or vice versa
(the app reports which it is). `hermescall-relay devices` shows whether a phone registered a push
token at all (`push=voip,alert`).

**"try again later" / 429 when pairing or connecting.** Ten failed pairing or authentication
attempts from one address (IPv6: its /64, and 30 from its /48) lock it out for 15 minutes. Wait,
then use a fresh code (`hermescall-relay pair`). Behind a reverse proxy that is not in
`--proxy-from`/`trusted_proxies`, all clients share the proxy's address and lock each other out:
fix the proxy list. A restart of the relay clears lockouts.

**Mailbox full / attachment refused.** A phone that stays offline fills its mailbox (500 messages,
20 MiB); the relay refuses more until it fetches. `hermescall-relay stats` shows the totals;
`storage_max_bytes` and `min_free_bytes` protect the disk (`/healthz` is 503 below the floor).

**The relay does not start after an update.** `journalctl -u hermescall-relay -n 50`; then
`install.sh rollback` (and report the error). "database schema N needs a newer relay" means the
database came from a newer version: update instead, or `rollback --restore-db`.

**Certificate problems.** `doctor` warns 14 days before expiry. With `--tls acme`, Caddy renews on
443 (TLS-ALPN): the port must stay forwarded to the relay. Self-signed (IP) relays have a 10-year
certificate; bridges and phones pin its key.
