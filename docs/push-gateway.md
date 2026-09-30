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

It keeps no content and no access logs (Caddy logging is off); the service log contains only a
6-character relay id prefix and the push result when Apple rejects a push. Rate counters live in
memory. On disk it keeps, for abuse protection only: SHA-256 hashes of request signatures for two
minutes (replay protection that survives a restart; see [Replay cache](#replay-cache)), per
**SHA-256 hash of a push token**, which relay ids used it in the last 30 days (see [Token
binding](#token-binding)), and which relay ids had a push accepted by Apple in the last 30 days;
rows are deleted 30 days after their last use. The raw token is never stored. It cannot read calls or messages and cannot reach your relay or bridge. A
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

The gateway accepts a time within ±60 s and rejects a signature it has already seen, also across
restarts. Response: `200 {"result": "ok" | "invalid_token" | "failed"}` (`invalid_token` makes the
relay forget the token), `401 {"error": "unauthorized" | "replayed"}` bad or replayed signature
(`unauthorized` for a correct signature almost always means the relay's clock is off), `403
{"error": "blocked" | "token_bound"}`, `413` body over 8 KiB, `429` rate limit, `503 busy`.

Relays retry `5xx` answers and connection errors twice (after 0.25 s and 1 s, each attempt freshly
signed) and never retry `4xx`. The gateway itself retries Apple's `429`/`500`/`503` the same way.

Limits (in memory, per gateway process):

| Key | Limit |
|---|---|
| device token, calls | 10 per minute, 60 per hour |
| device token, chat alerts | 20 per 10 minutes |
| device token, Live Activity updates / starts | 30 per minute / 20 per hour |
| relay | 600 requests per minute, 60 new device tokens per hour |
| IP (IPv6 /48) | 1200 requests per minute, 10 new relay keys per hour |
| device token, relays | at most 5 different relay keys within 30 days ([Token binding](#token-binding)) |
| replay cache entries | 1200 per relay and 4800 per IPv4 /24 or IPv6 /48 within 2 minutes ([Replay cache](#replay-cache)) |

The per-token limits hold across relays, so nobody who learns a push token can flood that phone.
The tables drop their least recently used entries when full instead of refusing newcomers, so
filling them with made-up tokens or addresses cannot lock anyone out. Restarting the gateway
resets the rate counters, not the replay cache or the token bindings.

### Replay cache

Every accepted signature is remembered (the first 16 bytes of its SHA-256, about 60 bytes per
entry on disk) until it is too old to pass the clock check. The request body is checked before a
signature is remembered, so malformed requests take no room. The cache holds up to 2,000,000
entries (roughly 120 MB); when it is full the gateway answers `503 busy` rather than forget a
signature. So that a flood of validly signed requests from many freshly made relay keys cannot
bring every relay to that point, two things hold: entries are capped per relay and per network
(table above), and above 500,000 entries only relays that had a push accepted by Apple in the last
30 days are admitted; other relays get `503 busy` (and retry) until the flood has aged out. A relay
proves nothing by signing, but a delivery needs a real device token of the app.

### Token binding

A push token is a secret only as long as the relays that saw it keep it. The gateway binds each
token softly to the relays that use it (trust on first use): at most **5 relay keys per token
within 30 days**; a sixth gets `403 token_bound`, the others keep working, and a relay that stops
using a token frees its place after 30 days. Only a push that passes the per-token rate limits
counts as use: a relay that is answered `429` neither takes a place nor keeps one alive. When all
five places are taken and the least recently used one has not been used for **7 days**, a relay
that had a push accepted by Apple within the last 30 days (for any token: it serves a real app
installation) takes that place over. That allows the normal cases — moving to a new relay,
reinstalling one, rotating its key, also after several moves — and stops a leaked token from being
used by any number of relay keys (which, combined with the 10 new keys per IP per hour, bounds what
one party can do). Someone who wants to keep a leaked token's places has to push to it at least
weekly, which the phone shows.

A hard binding ("only the relay this phone chose") needs proof from the app that the gateway can
check. A relay cannot give it: it registers its devices itself, so it could sign anything it likes
for a device key it made up. The sound way is Apple's **App Attest**: the app attests a key once,
then signs `(push token, relay id)` with it for each relay it pairs with; the relay forwards that
assertion with each push, and the gateway binds the token to the attested key. That needs the app,
the relay and the gateway to change together and is not implemented yet.

`hermescall-relay push-id` prints a relay's identity; the relay also logs it at start
(`push via https://hermes-push.quavon.de as relay abc123`). A relay rotates it with
`install.sh rotate push-key`.

`/healthz` answers `{"status": "ok", "version": …, "checks": {"state": "ok"}}`, or 503 when the
state database is not writable. `/metrics` (Prometheus text) is only on the separate metrics
listener (`[metrics] port` in `gateway.toml`, off by default) and never routed publicly: requests
by outcome, APNs results, state rows, blocklist size, version.

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
/root/hermes-call/relay/push-gateway-install.sh block <relay-id>    # stop one relay, at once
/root/hermes-call/relay/push-gateway-install.sh unblock <relay-id>
/root/hermes-call/relay/push-gateway-install.sh rotate-apns-key --apns-key AuthKey_NEW.p8 --apns-key-id NEWKEYID
/root/hermes-call/relay/push-gateway-install.sh status
/root/hermes-call/relay/push-gateway-install.sh uninstall         # keeps /etc/hermescall-push
```

The blocklist is `/etc/hermescall-push/blocked_relays` (one relay id per line, `#` comments); the
gateway re-reads it when it changes and on `systemctl reload hermescall-push`, no restart needed.
State (replay cache, token bindings) lives in `/var/lib/hermescall-push/gateway.db`.

Rotating the APNs key: create a new key in the Apple developer account, `rotate-apns-key`, check
that pushes arrive, then revoke the old key there. In Kubernetes, replace the sops secret and
restart the deployment the same way.

Check it from anywhere: `curl https://hermes-push.quavon.de/healthz` → `{"status": "ok", …}`.

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
# On a persistent volume, so a restart keeps the replay cache and token bindings.
state_path = "/var/lib/hermescall-push/gateway.db"
# Blocklist as a file (e.g. a ConfigMap key), re-read when it changes.
# blocklist_path = "/etc/hermescall-push/blocked_relays"

[metrics]
listen_host = "0.0.0.0"
port = 9744

[apns]
key_id = "ABCDE12345"
team_id = "CFV35FGSHF"
topic = "de.quavon.hermescall.voip"
```

Without `trusted_proxies` every request would appear to come from the ingress proxy, and all
relays would share one IP limit. Mount a volume (uid 10001) at `/var/lib/hermescall-push`. Run
exactly one replica with the `Recreate` strategy: rate limits live in memory and the state
database has a single writer. Probes: `GET /healthz` on 8744; scrape `/metrics` on 9744, which the
ingress must not route.
