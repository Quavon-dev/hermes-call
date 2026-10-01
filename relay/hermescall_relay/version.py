"""The relay's version (kept equal to relay/pyproject.toml; a unit test checks it)."""

VERSION = "0.7.0"
# Protocol features this relay offers, returned in `ready` (see docs/protocol.md, "Versions").
CAPABILITIES = ("unsupported", "mail", "blobs", "live_activity", "turns")
