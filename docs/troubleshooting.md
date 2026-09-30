# Troubleshooting and FAQ

Start with the three built-in checks, then find your symptom below.

| Where | Command | Shows |
|---|---|---|
| Relay | `hermescall-relay doctor` | database, disk, service, DNS, TLS expiry, TURN, push mode, clock |
| Bridge | `hermes-call-bridge status` and `journalctl -u hermes-call-bridge -n 50` | relay connection, paired phones, errors |
| iPhone | Settings › **Diagnostics** | network, push tokens and registrations per agent, relay connection and round trip; *Export log* (tokens, ids and addresses removed) |

On Proxmox, prefix the Linux commands with `pct exec <container id> --`. More relay detail:
[relay.md, Troubleshooting](relay.md#troubleshooting).

## Pairing

**The app says it cannot reach the relay.** The phone needs TCP 443 to the relay's address from
where it is (try mobile data too). Check the domain's A/AAAA record, the router forward, and
`hermescall-relay doctor`. A relay behind your own reverse proxy needs *Websockets* enabled.

**"Wrong or expired code".** Codes are single use, valid 10 minutes, and allow 3 attempts. Make a
new one: `hermes-call-bridge device add --name iPhone` (phone) or `hermescall-relay pair` (bridge).
Typed codes ignore case, spaces and dashes; `O` and `0`, `I`/`L` and `1` are the same.

**"Try again later" / rate limited.** Ten failed attempts from one address (IPv6: its /64) lock it
out for 15 minutes. Wait, then use a fresh code. If *everyone* is locked out at once, the relay sees
all clients as your reverse proxy's address: add the proxy to `--proxy-from`
([relay.md](relay.md#behind-your-own-reverse-proxy-nginx-proxy-manager-traefik-caddy)).

**"The relay's key changed" / TLS key mismatch.** The relay presents a different TLS key than the
one the app pinned: a new self-signed certificate (reinstall, `rm /etc/caddy/hermescall/*.pem`), a
switch between IP and domain, or somebody in between. If you changed it yourself, pair again;
otherwise check the network you are on.

**The bridge does not connect to the relay.** `hermes-call-bridge status` shows `"connected": false`:
the bridge needs outbound TCP 443 to the relay. After `relay add`, restart it
(`systemctl restart hermes-call-bridge`). A relay moved to a new domain needs a new bridge pairing.

## Calls

**No ring when the phone is locked or the app is closed.** Incoming calls wake the phone through a
VoIP push:

1. The app must be the published one with a relay using the push gateway (the default), or your own
   build with your own APNs key on your relay ([push-gateway.md](push-gateway.md)). A relay
   installed with `--no-push-gateway` rings only while the app is open.
2. `hermescall-relay devices` must list the phone with `push=voip`. If not: open the app once with
   notifications allowed, and check *Diagnostics* for the registration.
3. `journalctl -u hermescall-relay | grep push` on the relay shows the gateway's or Apple's answer
   (see *Pushes* below).
4. A ring that the bridge does not confirm within 15 s is ended by the app on purpose (a relay
   cannot fake calls). If rings stop at once, check that the bridge is connected.

**The call connects but there is no audio, or calls fail on mobile data.** Audio always goes
through TURN on the relay. From outside your network, UDP 3478 and UDP 49160-49200 must reach the
relay (router forwards, cloud firewall, Proxmox firewall). Behind NAT, `external-ip` in
`/etc/hermescall-relay/turnserver.conf` must be your current public IP (`install.sh refresh-ip`).
Networks that allow only HTTPS (some hotels, companies): install the relay with `--turns`
(TURN over TLS on 5349). `journalctl -u hermescall-turn` shows `401` for rejected credentials (see
*Clock*) and `403 Forbidden IP` for blocked peers.

**The agent does not answer / long pauses.** On the bridge: `journalctl -u hermes-call-bridge`
shows speech recognition and reply latencies. Whisper `base.en` needs about 2 cores; Kokoro must
answer on `127.0.0.1:8880`; Hermes' local API must be enabled (the installer does it) and Hermes
restarted once after installing the plugin.

## Chat and pushes

**Messages arrive only when I open the app.** Chat alerts use a normal (not VoIP) push:
notifications must be allowed for Hermes Call, the phone registered `push=voip,alert`
(`hermescall-relay devices`), and Focus must allow the agent (Settings › Focus › Hermes Call).

**Relay log: `status=401 error=unauthorized` (push gateway).** The relay's clock is off by more
than 60 s. **`403 blocked`**: the gateway operator blocked this relay (contact via the security
policy if you think that is a mistake). **`403 token_bound`**: more than five relays used this
phone's push token within 30 days; wait, or reinstall the app for a new token. With your own key:
`InvalidProviderToken` is a wrong key id or team id, `BadDeviceToken` a sandbox build talking to
production or the other way round.

**"Mailbox full".** A phone that stays offline collects at most 500 messages / 20 MiB; open the
app to fetch them. `hermescall-relay stats` shows the relay's totals.

## Clock

Three things depend on the time being right (within about a minute): end-to-end messages are
refused when their time stamp is more than **120 s** off, the push gateway refuses relay
requests more than **60 s** off, and TURN credentials are time-limited. Symptoms: messages that
never arrive, calls that never connect, push errors 401. Check `timedatectl` on the relay and the
bridge host ("System clock synchronized: yes"; install `systemd-timesyncd` or `chrony`) and that the
iPhone sets its time automatically.

## Lockouts and revoking

**A lost or stolen phone.** On the bridge: `hermes-call-bridge device list`, then
`hermes-call-bridge device revoke <device-id>` (ends an active call). On the relay,
`hermescall-relay revoke-device <id>` disconnects it within 15 s. The keys never leave the phone,
so nothing needs rotating on the relay.

**Locked out of my own relay after testing.** A relay restart clears lockouts
(`systemctl restart hermescall-relay`).

## Consent and privacy settings

**Call and send buttons do nothing / "Review consent".** The app shares nothing with your agent
until you accept the consent screen after adding your first agent. Accept it in the prompt, or turn
on Settings › Privacy › *Share with my agent*. Turning it off stops calls, sends, the outbox (also
the share sheet's) and phone-context answers again.

**The agent says it cannot read my calendar / location.** Every phone capability is **No** by
default. Set it to *Ask* or *Yes* in Settings › Privacy; with *Ask* the phone shows each request.
Answers need the app running: with the app suspended a request only shows a notification.

## Demo mode

**What is the "Atlas" demo agent?** An offline agent built into the app, for trying it without a
relay (and for App Review). It never connects anywhere: chat answers a few keywords, calls are
simulated without CallKit or audio. It is labelled *Demo* everywhere; remove it in its agent page
(*Remove demo agent*), which also deletes its chat. Pairing a real agent works alongside it.

## Updates and versions

**The installer says "refusing to downgrade".** The release it downloaded is older than what is
installed (a release was withdrawn, or someone serves an old release). Normally: wait for the next
release. To go back on purpose: `HC_ALLOW_DOWNGRADE=1` in front of the command, or on the relay
`install.sh rollback`. See [releasing.md](releasing.md#rollback-protection).

**"release signature is invalid".** The download is not what the maintainers signed. Do not
override it; try again later and report it ([SECURITY.md](../SECURITY.md)).

**The relay does not start after an update.** `journalctl -u hermescall-relay -n 50`, then
`/opt/hermescall-relay/relay/install.sh rollback` and report the error.
