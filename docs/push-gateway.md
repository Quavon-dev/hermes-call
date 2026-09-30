# Push gateway

iPhones only accept pushes signed with the APNs key of the team that published the app. So that
incoming calls, chat notifications and Live Activities work for everyone who uses the published
app (`de.quavon.hermescall`, Quavon UG) with their own relay, Quavon runs a push gateway at
**`https://hermes-push.quavon.de`**. A relay without its own APNs key sends its pushes there;
this is the default and needs no setup or sign-up.

| Your setup | Pushes |
|---|---|
| Published app (App Store/TestFlight), relay without APNs key | through the gateway (default) |
| Published app, relay with `--no-push-gateway` | none: incoming calls ring only while the app is open |
| Your own build (own team and bundle ID) | your own APNs key on your relay (`install.sh --apns-key …`, see [iOS app](ios.md#create-the-apns-key-p8-for-the-relay)); the gateway cannot push to other apps |

## What the gateway sees

The gateway receives exactly what the relay would otherwise send to Apple, and nothing else:

- the device's push token and whether it is a sandbox or production build;
- for a call: a random call id (`{"c": …}`) — no name, no number, no reason;
- for a chat message: the generic "New message" alert and the end-to-end ciphertext that only the
  phone's notification extension can open;
- for a Live Activity: step, total, state, start time and a label (generic unless you allow
  details in the app), the same fields Apple sees;
- the relay's public key (its identity at the gateway) and its IP address.

It stores nothing: no database, no access logs (Caddy logging is off); the service log contains
only a 6-character relay id prefix and the push result when Apple rejects a push. It keeps rate
counters in memory. It cannot read calls or messages and cannot reach your relay or bridge. A
ring it sends for a call your bridge did not confirm is ended by the app after asking the bridge
over the E2E channel (see [iOS app](ios.md)), as with a misbehaving relay.

Like a relay, anyone who holds a phone's Live Activity token (the relay, or the gateway itself)
can put a short label of their choice (up to 60 characters) on that phone's Lock Screen; the
gateway checks the fields and limits, not the wording.

What it can do if it is compromised or misbehaves: drop pushes (calls then ring only while the app
is open), or learn when your relay pushes to which token. If you do not want that, run your own
build with your own APNs key, or disable the gateway on your relay (`--no-push-gateway`).

## Protocol

`POST https://hermes-push.quavon.de/v1/push`, JSON body, one of:

```json
{"kind": "voip", "token": "<hex>", "env": "production", "call_id": "<16 bytes b64url>"}
{"kind": "alert", "token": "<hex>", "env": "sandbox", "ciphertext": "<b64url> or null"}
{"kind": "liveactivity", "token": "<hex>", "env": "production", "event": "start|update|end", "content_state": {…}}
```

Any other field or shape is rejected (`400`). The request is signed with the relay's Ed25519 key
(`/etc/hermescall-relay/push_gateway_key`, created by the installer, never leaves the relay):

```
Authorization: HC-Relay <public key>.<unix time>.<nonce>.<signature>      (base64url)
signature = Ed25519("hermescall-push-v1\n" + time + "\n" + nonce + "\n" + SHA-256(body))
```

The gateway accepts a time within ±60 s and rejects a signature it has already seen. Response:
`200 {"result": "ok" | "invalid_token" | "failed"}` (`invalid_token` makes the relay forget the
token), `401` bad or replayed signature, `403` blocked relay, `413` body over 8 KiB, `429` rate
limit.

Limits (in memory, per gateway process):

| Key | Limit |
|---|---|
| device token, calls | 10 per minute, 60 per hour |
| device token, chat alerts | 20 per 10 minutes |
| device token, Live Activity updates / starts | 30 per minute / 20 per hour |
| relay | 600 requests per minute, 60 new device tokens per hour |
| IP (IPv6 /48) | 1200 requests per minute, 10 new relay keys per hour |

The per-token limits hold across relays, so nobody who learns a push token can flood that phone.
The tables drop their least recently used entries when full instead of refusing newcomers, so
filling them with made-up tokens or addresses cannot lock anyone out. Restarting the gateway
resets the counters and the replay cache.

`hermescall-relay push-id` prints a relay's identity; the relay also logs it at start
(`push via https://hermes-push.quavon.de as relay abc123`).

## Running the gateway (publisher)

On a dedicated Debian 12/13 or Ubuntu 24.04 host with port 443 open and the DNS name pointing at
it (Let's Encrypt via TLS-ALPN, port 80 stays closed):

```bash
scp ~/Downloads/AuthKey_ABCDE12345.p8 root@hermes-push.quavon.de:/root/
```

```bash
ssh root@hermes-push.quavon.de 'apt-get install -y -qq git >/dev/null && git clone --depth 1 https://github.com/quavon-dev/hermes-call /root/hermes-call && /root/hermes-call/relay/push-gateway-install.sh install --domain hermes-push.quavon.de --apns-key /root/AuthKey_ABCDE12345.p8 --apns-key-id ABCDE12345 --team-id CFV35FGSHF && shred -u /root/AuthKey_ABCDE12345.p8'
```

The APNs key must be enabled for **Sandbox & Production** (Xcode builds use sandbox, TestFlight
and App Store builds production). It is stored as `/etc/hermescall-push/apns_key` (0600, user
`hermescall-push`); the service runs sandboxed like the relay and listens on `127.0.0.1:8744`
behind Caddy, which forwards only `/v1/push` and `/healthz`.

```bash
git -C /root/hermes-call pull && /root/hermes-call/relay/push-gateway-install.sh update
/root/hermes-call/relay/push-gateway-install.sh block <relay-id>  # stop one relay
/root/hermes-call/relay/push-gateway-install.sh status
/root/hermes-call/relay/push-gateway-install.sh uninstall         # keeps /etc/hermescall-push
```

Check it from anywhere: `curl https://hermes-push.quavon.de/healthz` → `ok`.

### As a container (Kubernetes)

`ghcr.io/quavon-dev/hermes-call-relay` (built by `.github/workflows/relay-image.yml` from
`relay/Dockerfile`, amd64 and arm64) runs the gateway by default as uid 10001 with a read-only
root filesystem. Mount `gateway.toml` and `apns_key` at `/etc/hermescall-push/`:

```toml
listen_host = "0.0.0.0"
listen_port = 8744
secrets_dir = "/etc/hermescall-push"
# The ingress proxy's pod network: its X-Forwarded-For is believed, anyone else's is ignored.
trusted_proxies = ["10.42.0.0/16"]

[apns]
key_id = "ABCDE12345"
team_id = "CFV35FGSHF"
topic = "de.quavon.hermescall.voip"
```

Without `trusted_proxies` every request would appear to come from the ingress proxy, and all
relays would share one IP limit. Run exactly one replica: the rate limits and the replay cache
live in memory.
