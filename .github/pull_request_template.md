## What and why

## How it was tested

## Checklist

- [ ] Tests added or updated; `uv run ruff check .`, `uv run pytest -q bridge/tests common/tests relay/tests` and, for Swift changes, `swift test` / the app tests pass
- [ ] [THREAT_MODEL.md](../THREAT_MODEL.md) updated if data flows change (anything new the relay, Apple or the network can see, new phone data)
- [ ] Docs updated (`docs/`, `docs/protocol.md` for wire changes, README) and a line in `CHANGELOG.md`
- [ ] No third-party services, secrets or personal data; the look stays original
