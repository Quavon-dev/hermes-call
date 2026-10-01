# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). The relay, bridge, common library, test client
and iOS app share one version; the Hermes plugin (`hermes-integration/hermes-call`) is
versioned separately and is at **0.8.1** in this release.

## [0.7.1] — 2026-10-01

- Hermes plugin 0.8.1: chat connects again with Hermes Agent v0.21, which calls the platform
  adapter's `connect(is_reconnect=…)`; a reconnect replaces the old poll loop. The Hermes
  compatibility check now calls `connect` with the arguments Hermes' own base class declares.
- Relay and bridge CLIs accept device and bridge ids that start with "-".
- Fresh installs require a release with a signed MANIFEST.

## [0.7.0] — 2026-10-01

### iOS app

- Consent before anything reaches your agent (what is shared, that the agent may use a third-party
  AI service); revocable in Settings › Privacy. Calls, chat, phone context and Siri stay off without it.
- Try a demo: an offline demo agent ("Atlas") with chat, cards and a simulated call, no relay needed.
- New onboarding with permission explanations; `hermescall://pair` links open pairing; clear pairing
  errors (unreachable, TLS, rate limited, busy, wrong code, device limit); camera-denied help.
- `hermescall://call` links from other apps ask "Call <agent>?" first; only the app's own widget
  links (per-install secret) call at once.
- Chats: one list of all agents with unread counts per agent (badge = their sum); up to five agents
  stay connected while the app is open.
- Chat history in SQLite (app group, WAL, data protection as before), moved over from the JSON files
  once; no 3000-message limit, and the app and share extension can write at the same time.
- Chat: paging, search ("Today"/"Yesterday", file names), delete on this iPhone, full Markdown
  (headings, lists, code blocks with wrap/copy, quotes, tables), several files at once, camera
  photos, voice notes with waveform, scrubbing and speed; readable owner bubbles (WCAG AA).
- Fixed: retrying a failed message sent it through the active agent instead of the chat's own.
- Fixed: the share sheet took the relay connection away from the running app; it now hands messages
  to the app (spoof-resistant handshake) and connects itself only when the app is not running.
- Notifications: communication notifications with the agent as sender, app badge, photo previews;
  Answer and Deny on phone-context questions.
- Approvals: a cancelled Face ID keeps the request open ("Try again"); one approval panel for calls
  and chat.
- Calls follow audio route changes and interruptions; route picker and captions on the call screen;
  agent names on incoming rings; CallKit template icon.
- Settings reorganised per agent, plus Diagnostics (network, push registration, relay version and
  round trip, redacted log export); offline banner and instant reconnect on network changes.
- The presence pauses under sheets and in the background and slows down in Low Power Mode, with
  Reduce Motion or when hot; Dynamic Type, Increase Contrast and Reduce Transparency support.
- Siri: "Call <agent>", "Ask <agent>", "Open Chat" with an agent parameter; Focus filter per agent.
- The agent can add reminders and calendar events (off by default; Ask shows the exact item).
- Widgets: agent picker, Call and chat buttons; the Live Activity names its agent and clears a lost
  task after 11 minutes.
- Apple Watch: messages queue while the iPhone is out of reach, voice notes, deny approvals, call
  haptics; updates follow new messages also in the background.
- Relay protocol: the app sends its version and caps, handles `unsupported`, retries busy (503)
  blob transfers, reconnects quickly after a relay restart and uses TURNS when offered.
- Fixed: voice note playback could stop the app (audio callbacks ran as main-actor code); framework
  callbacks no longer run on the main actor; force unwraps removed.
- UI tests on the demo agent; App Store review notes, privacy answers and captioned screenshots in
  `ios/appstore/`.

### Bridge and Hermes plugin

- Chat messages survive bridge restarts and relay outages: stored before "delivered", with a
  persistent outbox that retries.
- Fixed: owner messages lost after a bridge restart (adapter cursor epoch), ghost calls after
  hanging up during setup, and silence when Hermes or Kokoro fails mid-call.
- Live-call speech recognition is no longer held up by long voice notes.
- "Approve for this session" for command approvals; approvals expire instead of hanging.
- Calls use one Hermes session per phone and day instead of one ever-growing session.
- Configurable call timeouts; a spoken warning a minute before the call limit; calls without audio
  end on their own; pending approvals and captions are re-sent after a relay reconnect.
- TURN over TCP/TLS can be preferred (`[turn] transport`); blob transfers retry when the relay is busy.
- Phone context asks the phone you are using first; new "create reminder" and "create calendar
  event" capabilities.
- `hermes-call-bridge doctor`, `/healthz`, `/metrics`, JSON logs, systemd watchdog and graceful
  shutdown; several agents on one host (`install.sh --instance NAME`).
- Plugin: Hermes compatibility probe, tools return at once when the owner interrupts the agent.
- Revoking a phone works while the relay is offline; `relay add` refuses while the bridge runs.
- `bridge/get.sh` verifies releases with the shared block (signed MANIFEST, no downgrades).

### Calls, chat sync and versions (bridge + app)

- Calls survive Wi-Fi ↔ cellular changes: "Reconnecting…" and up to 20 s to resume the same
  conversation (both sides need `call_resume`; older peers end the call as before).
- A newly paired phone gets the recent chat from the bridge (up to 200 messages, with attachments
  within limits); photos and files sent from one phone appear on your other phones.
- Attachments no longer pass through the bridge's memory as base64; they are spooled on disk, sealed.
- "Allow for this session" for approvals (needs Face ID); Diagnostics shows the bridge version.
- App and bridge exchange protocol versions and caps (E2E `hello`), unknown types are answered with
  `unsupported`; `state.json` has a schema version.

### Relay and push gateway

- Every limit configurable in `[limits]` (`relay.local.toml` survives updates); max devices per
  bridge; global storage cap and free-space floor; background expiry and vacuum; versioned schema
  migrations.
- Blob transfers survive a busy relay (503 + retry), with deadlines and a download cap; unknown
  message types answered with `unsupported` instead of disconnecting; `ready` carries version and caps.
- Graceful shutdown (1001, pending chat alerts sent); APNs and gateway retries with backoff.
- `/healthz` with real checks (cached, rate-limited, version only locally); opt-in Prometheus
  `/metrics`; JSON logs.
- CLI: devices, revoke-device, stats, doctor, backup, restore, compact.
- Installer: rollback, backup/restore, rotate turn-secret/push-key/apns-key, `--turn-ports`,
  `--turn-quota`, `--turns` (5349), TURN credential TTL 90 min, hardened coturn unit. Old relays
  are no longer switched to the push gateway on update. Uninstall removes the firewall table without
  flushing other rules.
- Push gateway: persistent replay cache that resists floods, soft token binding (≤ 5 relays per
  token in 30 days, hashed), atomic blocklist reload, unblock and rotate-apns-key, health, metrics.
- Docker: HEALTHCHECK, volumes, non-root; `docker-compose.yml` with relay + coturn + Caddy (only
  Caddy's fixed address trusted for `X-Forwarded-For`); `:latest` only from release tags.

### Releases, CI and docs

- Releases carry a signed MANIFEST (version, commit); installers refuse downgrades unless
  `HC_ALLOW_DOWNGRADE=1` / `--allow-downgrade`; a legacy `SHA256SUMS` must be exactly one line.
- `tools/release.sh` builds reproducibly and signs CI drafts offline; `v*` tags create a draft
  release with provenance; the relay image gets semver tags, Trivy, cosign signatures.
- CI runs app unit and UI tests, the relay installer in systemd containers, pip-audit, CodeQL, a
  coverage floor, SHA-pinned actions with Dependabot, bridge end-to-end and Hermes compatibility
  workflows, and an external push gateway monitor.
- Docs: architecture with diagrams, troubleshooting, releasing, operations (backup, rollback,
  rotation), generic home-server guide; code of conduct, support policy; threat model updated.

## [0.6.2]

- Relay and bridge commands work through `pct exec` (no login shell): the relay command lives in
  `/usr/local/bin`, both wrappers set their own PATH.
- Proxmox helper: a domain without a DNS record yet only warns instead of ending the helper.

## [0.6.1]

- Relay: `--tls proxy` for running behind an existing reverse proxy (Nginx Proxy Manager, Traefik,
  Caddy): plain HTTP on 8743 reachable only from `--proxy-from`, whose `X-Forwarded-For` is
  believed (`trusted_proxies` in relay.toml).
- Proxmox helper: asks on the host, also with the default settings, for the domain and who handles
  HTTPS for it; without a domain it installs on the public IP.
- Push gateway, release pipeline for internal/external TestFlight and App Review, Recents call-back
  (`INStartCallIntent`).

## [0.6.0] — 2026-09-30

First public release.

### Protocol and crypto (`common/`, `ios/HermesCallKit`)

- Wire protocol v1: JSON over WebSocket-over-TLS, Ed25519-authenticated sessions
  ([docs/protocol.md](docs/protocol.md)).
- Pairing with CPace (wire-compatible with jedisct1/cpace) and short typed codes or QR links;
  the observed TLS key is bound into the handshake, so self-signed relays are never trusted
  silently.
- End-to-end encrypted signaling (crypto_box envelopes with replay protection), a per-device
  mailbox envelope and encrypted attachments.
- Swift core with interoperability tests against the Python relay and bridge.

### Release automation

- `ios-release.yml`: when the app changes on `main`, tests, archives, uploads to TestFlight and
  publishes the IPA as a GitHub release (`ios-v<version>-<build>`); build numbers from the run
  number, version from `MARKETING_VERSION` in `ios/project.yml` (one value for all targets).

### Relay (`relay/`)

- Pairing rendezvous and opaque E2E routing between bridge and devices.
- Short-lived TURN credentials (coturn with private ranges denied), APNs VoIP, alert and
  Live Activity pushes.
- Push gateway (`hermes-push.quavon.de`, [docs/push-gateway.md](docs/push-gateway.md)): relays
  without their own APNs key push through it by default, signing each request with their own
  Ed25519 key; strict payload shapes and per-token, per-relay and per-IP limits.
  `relay/push-gateway-install.sh` deploys it.
- Ciphertext mailbox and attachment store for chat.
- Abuse limits: per-code attempts, per-IP lockouts, connection caps, message, ring and push rate
  limits.
- Installer for Debian 12/13 and Ubuntu 24.04 (Caddy, coturn, nftables, sandboxed systemd units),
  signed release tarballs (`tools/release.sh`) and a Proxmox LXC helper.

### Bridge (`bridge/`)

- `hermes-call-bridge` next to Hermes: relay-only WebRTC calls, voice activity detection,
  faster-whisper speech recognition (or the phone's transcript), Kokoro speech, barge-in,
  push-to-talk, captions and interrupt.
- Device pairing, revocation and a local token API (loopback only).
- Chat with Hermes: shared owner chat across phones, voice notes, photos and files, spoken replies,
  missed calls as messages.
- Phone context queries with per-capability validation and rate limits; result presentations with
  SSRF-safe image fetching; task progress for the tasks ring and Live Activity; images from the
  phone's camera during calls.
- Installer with hash-pinned dependencies and a Whisper model pinned by revision and SHA-256.

### Hermes plugin (`hermes-integration/`, plugin version 0.7.0)

- Tools `call_owner`, `phone_context` and `present_to_owner`, the `hermes_call` chat platform
  adapter and tool-progress hooks.

### iOS app (`ios/`)

- CallKit calls in both directions, PushKit ringing confirmed over E2E, ringback tone.
- Speech recognition on the bridge or on the iPhone.
- Chat with notifications decrypted on the device, share extension, Siri and widgets.
- Phone access with **No / Ask / Yes** per capability (default No) and a local request log.
- Standard and presence (Metal) appearances, per-agent colours, tasks ring and Live Activity,
  place reminders, in-call camera, Apple Watch and CarPlay, switchable app icons.
- Approvals confirmed with Face ID; keys in the Keychain; "Delete all data".
