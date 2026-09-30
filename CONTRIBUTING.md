# Contributing

Thanks for helping. Bug reports, fixes and focused features are welcome; for larger
changes please open an issue first so we can agree on the approach. Security bugs go
through [SECURITY.md](SECURITY.md), never a public issue.

## Setup (macOS)

```bash
brew install libsodium shellcheck xcodegen
uv sync                                        # Python workspace: relay, bridge, common, testclient
xcodebuild -downloadComponent MetalToolchain   # once per Xcode install (presence shaders)
cd ios && xcodegen generate                    # after changing ios/project.yml
```

The iOS app needs Xcode 26 or newer. Your team, bundle id and app group go into
`ios/Config/Identity.local.xcconfig` (not committed); see [docs/ios.md](docs/ios.md).
On Linux, `apt install libsodium-dev` plus `uv sync` is enough for the Python side.

## Tests

```bash
uv run ruff check . && uv run ruff format --check .
uv run pytest -q bridge/tests common/tests relay/tests
shellcheck -e SC1090,SC1091 $(git ls-files '*.sh')
(cd ios/HermesCallKit && swift test)           # Swift core; InteropTests run it against the Python relay/bridge in .venv
cd ios && xcodebuild test -project HermesCall.xcodeproj -scheme HermesCall \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Heavier checks, when you touch installers or the voice pipeline: `./relay/tests/container_e2e.sh
debian:12` and `./bridge/tests/container_e2e.sh` (Docker; the bridge test needs a running Kokoro
container), and `uv run python tools/dev_stack.py --host <LAN IP>` for a local relay + bridge.
CI runs the Python checks, the Swift core tests and an unsigned simulator build of the app.

New behaviour comes with tests; bug fixes with a test that failed before.

## Code style

- **Python**: `ruff` (lint and format, config in `pyproject.toml`), type hints, Python 3.11+.
- **Swift**: Swift 6 language mode with strict concurrency; warnings are errors in the app
  targets. Keep the Python and Swift protocol code byte-for-byte compatible
  ([docs/protocol.md](docs/protocol.md)) and extend the interop tests when the wire format changes.
- **Shell**: `set -Eeuo pipefail`, clean under `shellcheck`.
- Keep files and functions small; no new dependencies without a good reason (and an entry in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): `uv run python tools/third_party_notices.py`
  for Python packages).

## Commits and pull requests

Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `perf:`, `ci:`,
e.g. `fix: reject empty pairing codes on the relay`. One logical change per pull request, with a
short description of what and why, and how you tested it.

## Privacy and security rules

These are not negotiable:

- **No third-party services**: no analytics, crash reporting, ad or tracking SDKs, remote config,
  CDNs or fonts fetched at run time. The app connects on its own only to the owner's relay (and
  Apple for pushes); the bridge only to the relay, Hermes, local services (Kokoro) and the images
  the agent explicitly presents.
- **Document what others can see**: anything new that Apple, the relay or the network can observe
  (metadata, push payloads, new relay endpoints or stored fields) must be described in
  [THREAT_MODEL.md](THREAT_MODEL.md) in the same pull request. Content stays end-to-end encrypted.
- **Phone data is opt-in**: every new phone capability is **No / Ask / Yes** on the phone,
  **No** by default, validated on the bridge and logged on the phone.
- No secrets, keys, personal data or real device identifiers in code, tests or screenshots.

## Look and naming

The app's look (presence, HUD, icons, sounds) must stay original. Do not add film or franchise
names, logos, characters, artwork, sounds or fonts, and do not describe features by reference to
them. Neutral names only.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
