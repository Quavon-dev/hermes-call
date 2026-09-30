# Security policy

Hermes Call carries voice calls, chat and personal phone data between your iPhone and
your agent. We take reports seriously and are grateful for them.

## Reporting a vulnerability

Please report privately through GitHub's
[private vulnerability reporting](https://github.com/quavon-dev/hermes-call/security/advisories/new)
(Security tab → "Report a vulnerability").

**Do not open a public issue, discussion or pull request for a security bug.**

Helpful to include:

- the affected component and version (or commit),
- what an attacker can do and under which position (network, relay operator, paired
  device, local user, …),
- steps or a proof of concept,
- any fix you have in mind.

## Scope

- **Relay** (`relay/`): pairing rendezvous, message routing, mailbox and blobs, TURN
  credentials, APNs pushes, installer.
- **Bridge** (`bridge/`): local API, call and chat handling, phone queries, presentations,
  installer.
- **Hermes plugin** (`hermes-integration/`).
- **iOS app** (`ios/`), including its extensions, widgets and the watch app.
- **Crypto and pairing** (`common/`, `ios/HermesCallKit`): CPace pairing, identities,
  end-to-end encryption, the wire protocol ([docs/protocol.md](docs/protocol.md)).
- The signed-release and Proxmox helper scripts (`tools/release.sh`, `proxmox-helper/`,
  `bridge/get.sh`), the release workflows (`.github/workflows`) and the relay container image.
- The push gateway (`relay/hermescall_relay/gateway.py`) and its deployment at `hermes-push.quavon.de`.

The security design and its assumptions are in [THREAT_MODEL.md](THREAT_MODEL.md).

## Out of scope

The risks listed under "Out of scope / accepted" in [THREAT_MODEL.md](THREAT_MODEL.md),
among them: denial of service by the relay operator or the network, a compromised bridge
host or Hermes itself (they are the trust anchor), the missing forward secrecy of
signaling, and conversation text kept in Hermes' own session store. Also out of scope:
vulnerabilities in Hermes, iOS, Kokoro, Whisper or other third-party software (please report
those upstream), and findings that need a jailbroken or already compromised phone.

## Supported versions

| Component | Supported | How to update |
|---|---|---|
| Relay, bridge, Hermes plugin | the latest `v*` release (the one marked *latest*) | run the installer again ([README](README.md)); the relay's `install.sh update` |
| Push gateway `hermes-push.quavon.de` | the running deployment | operated by Quavon |
| iOS app | the latest App Store / TestFlight build | automatic through the App Store |
| Older releases, `main` between releases | not supported | – |

Security fixes ship as a new patch release (for example 0.7.1), announced in a GitHub security
advisory and the changelog. Relays and bridges do not update themselves: subscribe to releases
(Watch → Custom → Releases) to hear about them. Please check that an issue still exists in the
latest release or on `main` before reporting.

Releases are signed with an offline key; the installers verify the signature and refuse older
versions than the installed one ([docs/releasing.md](docs/releasing.md)). The container image is
signed with cosign (keyless, this repository's workflow).

## What to expect

Hermes Call is maintained by a small team, so please be patient:

- we aim to acknowledge a report within a week,
- we will keep you informed while we investigate and fix it,
- we publish a GitHub security advisory with the fix and credit you, unless you prefer
  otherwise.

Please give us reasonable time to release a fix before disclosing publicly.
