# Relay: install, ports, isolation

The relay is the only internet-facing component. It forwards opaque, end-to-end
encrypted signaling between your bridge and your devices, hands out short-lived
TURN credentials, relays encrypted media (coturn) and sends pushes to the phones: through the
Hermes Call [push gateway](push-gateway.md) (`hermes-push.quavon.de`, the default, no Apple
account needed) or with your own APNs key if you build the app yourself.
It cannot read audio, text or signaling content (see [THREAT_MODEL.md](../THREAT_MODEL.md)).

Supported hosts: **Debian 12, Debian 13, Ubuntu 24.04** — a dedicated VPS or LXC.
The installer owns the host's Caddy, coturn and nftables configuration.

## Open ports (exactly these)

| Port | Proto | Why |
|---|---|---|
| 443 | TCP | TLS (Caddy): WebSocket signaling + pairing. Let's Encrypt uses TLS-ALPN on this port, so **port 80 stays closed**. |
| 3478 | UDP + TCP | TURN control (UDP preferred; TCP for networks that block UDP). |
| 49160–49200 | UDP | TURN media relay ports (≈20 concurrent calls; each call uses 2). |
| 22 | TCP | VPS only: SSH, keys only (`--harden-ssh`), fail2ban, rate-limited. |

Everything else inbound is dropped (nftables, `policy drop`). The relay daemon
itself listens only on `127.0.0.1:8743`. HTTP/3 (UDP 443) and coturn's alternate
port 3479 are disabled/blocked.

TURN is locked down: ephemeral HMAC credentials (10 min) issued only to paired
bridges/devices, no TCP relaying, bandwidth cap, and **peers in private ranges
(RFC 1918, CGNAT, loopback, link-local, ULA) are refused** so nobody can use the
relay to reach your LAN.

## Install on a VPS

Clone this repository on the VPS, then run the installer as root.
`install.sh` installs distribution packages, creates the unprivileged users
`hermescall-relay` (daemon) and `turnserver` (coturn), writes configs/secrets
(mode 600), enables the firewall and starts the services.

```bash
ssh root@relay.example.com 'apt-get install -y -qq git >/dev/null && git clone --depth 1 https://github.com/quavon-dev/hermes-call /root/hermes-call && /root/hermes-call/relay/install.sh install --domain relay.example.com --no-apns --harden-ssh'
```

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

Other commands (`install.sh` is also installed at `/opt/hermescall-relay/relay/install.sh`):

```bash
/opt/hermescall-relay/relay/install.sh update        # after copying a newer checkout: redeploy, keep keys + data
/opt/hermescall-relay/relay/install.sh status
hermescall-relay bridges                             # list paired bridges
hermescall-relay revoke-bridge <bridge-id>           # removes the bridge and all its devices
/opt/hermescall-relay/relay/install.sh uninstall     # add --purge to delete keys, config, database
```

Update to the latest version: `git -C /root/hermes-call pull && /root/hermes-call/relay/install.sh update`.

## Install on your home Proxmox (isolated LXC)

> **Check first:** many German cable/fibre lines use **DS-Lite** (no public IPv4).
> Then port forwarding from the internet to your home is impossible and the relay
> must run on a VPS. In the FritzBox: *Internet → Online Monitor* shows whether
> you have a public IPv4 address.

### 1. Create the container (Proxmox host shell)

Once the repository is published on GitHub the community-scripts helper does
all of this (see [proxmox-helper/README.md](../proxmox-helper/README.md)).
Until then, manually — all commands run as root on the Proxmox host:

```bash
pveam update && pveam available --section system | grep debian-13
```

```bash
pveam download local debian-13-standard_13.1-2_amd64.tar.zst
```

(Use the exact file name the previous command printed.) This creates an
unprivileged container with 1 core, 512 MB RAM and 4 GB disk; `nesting=1` lets
systemd apply its service sandboxing inside the container:

```bash
pct create 130 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst --hostname hermes-relay --unprivileged 1 --features nesting=1 --cores 1 --memory 512 --swap 256 --rootfs local-lvm:4 --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1 --onboot 1 --start 1
```

Clone the repository inside the container and run the installer:

```bash
pct exec 130 -- bash -c 'apt-get install -y -qq git >/dev/null && git clone --depth 1 https://github.com/quavon-dev/hermes-call /root/hermes-call && /root/hermes-call/relay/install.sh install --domain relay.example.com --no-apns --non-interactive'
```

Pushes use the [push gateway](push-gateway.md). Only for your own build of the app, add your own
APNs key (it never goes into environment variables or logs):

```bash
pct push 130 /root/AuthKey_ABCDE12345.p8 /root/AuthKey_ABCDE12345.p8 --perms 600
```

```bash
pct exec 130 -- bash -c '/opt/hermescall-relay/relay/install.sh install --apns-key /root/AuthKey_ABCDE12345.p8 --apns-key-id ABCDE12345 --team-id TEAMID1234 --bundle-id com.example.hermescall --non-interactive && shred -u /root/AuthKey_ABCDE12345.p8'
```

Behind NAT the installer detects the public IP and configures coturn's
`external-ip`; a timer re-checks it every 5 minutes (dynamic home IPs).

### 2. Isolate it from your LAN (Proxmox firewall)

The relay never needs to open connections into your LAN — the bridge connects
*out* to it. Block everything from the relay to private ranges except DNS to
your router. Create `/etc/pve/firewall/130.fw` on the host:

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
OUT ACCEPT -p udp -dest 192.168.0.1 -dport 53
OUT ACCEPT -p tcp -dest 192.168.0.1 -dport 53
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
```

The Proxmox firewall is stateful: replies to the bridge's outbound connection
are still allowed.

> **Warning — do not lock yourself out.** Container rules only take effect when
> the firewall is enabled at *Datacenter → Firewall → Options*. Enabling it there
> with an inbound policy of DROP also filters the Proxmox host itself. Before you
> switch it on, add datacenter rules that allow TCP 8006 (web UI) and TCP 22 from
> `192.168.0.0/24`, or leave the datacenter input policy at ACCEPT.

Stronger isolation: put the relay on its own bridge/VLAN (e.g. `vmbr1` on a
separate NIC connected to the FritzBox **guest LAN port 4**, which the FritzBox
keeps apart from the home network). The firewall rules above still apply.

### 3. Forward only the relay ports on the FritzBox

*Internet → Permit Access → Port Sharing → Add Device for Sharing → hermes-relay*,
then add: TCP 443, TCP 3478, UDP 3478, UDP 49160–49200 (range: "from port 49160
to port 49200"). **Nothing** is forwarded to LXC 121 (Hermes).

DNS: point a domain (A record) at your public IP and keep it updated (the
FritzBox supports DynDNS providers under *Internet → Permit Access → DynDNS*).
DNS is only a name lookup — it is not in the call path.

## Where the secrets live

| File | Owner | Mode | Content |
|---|---|---|---|
| `/etc/hermescall-relay/apns_key` | hermescall-relay | 600 | own APNs .p8 key (own app builds only) |
| `/etc/hermescall-relay/push_gateway_key` | hermescall-relay | 600 | Ed25519 key that signs requests to the push gateway |
| `/etc/hermescall-relay/turn_secret` | hermescall-relay | 600 | TURN HMAC secret |
| `/etc/hermescall-relay/turnserver.conf` | turnserver | 600 | coturn config (contains TURN secret) |
| `/etc/hermescall-relay/install.env` | root | 600 | installer answers (no secrets) |
| `/etc/caddy/hermescall/key.pem` | caddy | 600 | self-signed TLS key (IP mode) |
| `/var/lib/hermescall-relay/relay.db` | hermescall-relay | 600 | bridge/device public keys, push tokens |

Logs contain no push tokens, keys, codes or message content — only event names,
short (6-char) id prefixes and APNs status codes. Caddy access logs are off.
