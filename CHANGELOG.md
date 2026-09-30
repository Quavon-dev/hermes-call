# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). The relay, bridge, common library, test client
and iOS app share one version; the Hermes plugin (`hermes-integration/hermes-call`) is
versioned separately and is at **0.7.0** in this release.

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
