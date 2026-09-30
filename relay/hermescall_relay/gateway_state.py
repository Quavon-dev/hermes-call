"""What the push gateway remembers across restarts: seen request signatures and token use.

Replay cache: a SHA-256 (first SEEN_HASH_BYTES bytes) of every accepted signature until it is too
old to pass the clock check, so a restart cannot re-open the window for a captured request. About
60 bytes per entry on disk, so MAX_SEEN costs ~120 MB at worst. Above PRESSURE_SEEN entries only
relays that recently had a push delivered (`delivered`) may add more: a flood of signed requests
from fresh relay keys cannot lock out the relays already in use (docs/push-gateway.md, "Replay
cache").

Token binding (trust on first use, soft): per device token (stored as its SHA-256, never the
token) the relays that pushed to it. At most MAX_RELAYS_PER_TOKEN relays may use one token within
RELAY_WINDOW; a relay that stops using a token frees its place after that, and a binding unused
for STALE_BINDING can be taken over earlier by a relay that has had a push delivered (so a phone
that moved relays is not locked out for a month by old or abandoned relay keys). Only pushes that
pass the per-token rate limits count as use. Moving to a new relay,
reinstalling one or rotating its key keeps working; a token that leaked cannot be used by an
unbounded number of relay keys. A hard binding (only the relay the app chose) needs a key the
gateway can trust to speak for the app, i.e. App Attest; relays cannot provide that proof, since
a relay registers its devices itself. See docs/push-gateway.md, "Token binding".

Rows unused for FORGET_AFTER are deleted.
"""

import hashlib
import sqlite3
from dataclasses import dataclass
from pathlib import Path

REPLAY_SECONDS = 120
SEEN_HASH_BYTES = 16  # 128 bits: no accidental collision among a few million entries
MAX_SEEN = 2_000_000
PRESSURE_SEEN = MAX_SEEN // 4
MAX_RELAYS_PER_TOKEN = 5
RELAY_WINDOW = 30 * 86_400
STALE_BINDING = 7 * 86_400
FORGET_AFTER = RELAY_WINDOW

_SCHEMA = (
    "CREATE TABLE IF NOT EXISTS seen(sig BLOB PRIMARY KEY, expires INTEGER NOT NULL) WITHOUT ROWID",
    "CREATE INDEX IF NOT EXISTS seen_expires ON seen(expires)",
    """CREATE TABLE IF NOT EXISTS token_relays(
        token BLOB NOT NULL,
        relay TEXT NOT NULL,
        last_used INTEGER NOT NULL,
        PRIMARY KEY(token, relay)
    ) WITHOUT ROWID""",
    "CREATE INDEX IF NOT EXISTS token_relays_used ON token_relays(last_used)",
    # Relays whose last push was accepted by APNs: a real app installation receives from them.
    "CREATE TABLE IF NOT EXISTS delivered(relay TEXT PRIMARY KEY, last_ok INTEGER NOT NULL) WITHOUT ROWID",
)
SCHEMA_VERSION = 2


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: str = ""  # "token_bound" when refused


def token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


class GatewayState:
    def __init__(self, path: Path | str | None) -> None:
        """`path` None keeps everything in memory (tests, or a gateway without a volume)."""
        self._db = sqlite3.connect(str(path) if path else ":memory:", isolation_level=None, check_same_thread=False)
        self._db.execute("PRAGMA busy_timeout=2000")
        if path:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute("PRAGMA synchronous=NORMAL")
        for statement in _SCHEMA:
            self._db.execute(statement)
        if self._db.execute("PRAGMA user_version").fetchone()[0] < 2:
            # Schema 1 stored the full SHA-256; the prefix is the same hash, shortened.
            self._db.execute("UPDATE OR REPLACE seen SET sig = substr(sig, 1, ?) WHERE length(sig) > ?", (SEEN_HASH_BYTES,) * 2)
        self._db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        self._seen_count = self._db.execute("SELECT COUNT(*) FROM seen").fetchone()[0]

    def close(self) -> None:
        self._db.close()

    # ---- replay cache ---------------------------------------------------

    @property
    def seen_count(self) -> int:
        """Rows in the replay cache (kept in memory: no COUNT(*) per request)."""
        return self._seen_count

    @staticmethod
    def _seen_hash(signature: bytes) -> bytes:
        return hashlib.sha256(signature).digest()[:SEEN_HASH_BYTES]

    def seen_signature(self, signature: bytes, now: float) -> bool:
        digest = self._seen_hash(signature)
        return self._db.execute("SELECT 1 FROM seen WHERE sig = ? AND expires > ?", (digest, int(now))).fetchone() is not None

    def remember_signature(self, signature: bytes, now: float) -> str:
        """ "new", "replayed", or "full" (the caller refuses rather than forgetting a signature)."""
        digest = self._seen_hash(signature)
        if self.seen_signature(signature, now):
            return "replayed"
        if self._seen_count >= MAX_SEEN:
            self._prune_seen(int(now))
            if self._seen_count >= MAX_SEEN:
                return "full"
        cursor = self._db.execute("INSERT OR IGNORE INTO seen(sig, expires) VALUES(?, ?)", (digest, int(now) + REPLAY_SECONDS))
        if cursor.rowcount:
            self._seen_count += 1
        else:  # an expired row with the same hash (not pruned yet): renew it
            self._db.execute("UPDATE seen SET expires = ? WHERE sig = ?", (int(now) + REPLAY_SECONDS, digest))
        return "new"

    def under_pressure(self) -> bool:
        return self._seen_count >= PRESSURE_SEEN

    def _prune_seen(self, now: int) -> None:
        self._db.execute("DELETE FROM seen WHERE expires <= ?", (now,))
        self._seen_count = self._db.execute("SELECT COUNT(*) FROM seen").fetchone()[0]

    # ---- relays that delivered -------------------------------------------------

    def mark_delivered(self, relay: str, now: float) -> None:
        self._db.execute(
            "INSERT INTO delivered(relay, last_ok) VALUES(?, ?) ON CONFLICT(relay) DO UPDATE SET last_ok = excluded.last_ok",
            (relay, int(now)),
        )

    def delivered(self, relay: str, now: float) -> bool:
        """True when APNs accepted a push from this relay within RELAY_WINDOW."""
        row = self._db.execute("SELECT 1 FROM delivered WHERE relay = ? AND last_ok > ?", (relay, int(now) - RELAY_WINDOW))
        return row.fetchone() is not None

    # ---- token bindings ---------------------------------------------------

    def check_token(self, token: str, relay: str, now: float) -> Decision:
        """token_allowed, and when allowed, record_token (for callers without further limits)."""
        decision = self.token_allowed(token, relay, now)
        if decision.allowed:
            self.record_token(token, relay, now)
        return decision

    def token_allowed(self, token: str, relay: str, now: float) -> Decision:
        """Applies the binding rule without recording anything."""
        relays = self._bound_relays(token_hash(token), int(now))
        if relay in relays or len(relays) < MAX_RELAYS_PER_TOKEN:
            return Decision(True)
        if self._stale(relays, int(now)) is not None and self.delivered(relay, now):
            return Decision(True)
        return Decision(False, "token_bound")

    def record_token(self, token: str, relay: str, now: float) -> None:
        """Records a use (after the rate limits passed); takes over the oldest stale binding when
        the token has no free place (token_allowed only allows that for a relay that delivered)."""
        digest, now = token_hash(token), int(now)
        relays = self._bound_relays(digest, now)
        if relay not in relays and len(relays) >= MAX_RELAYS_PER_TOKEN:
            stale = self._stale(relays, now)
            if stale is not None:
                self._db.execute("DELETE FROM token_relays WHERE token = ? AND relay = ?", (digest, stale))
        self._db.execute(
            "INSERT INTO token_relays(token, relay, last_used) VALUES(?, ?, ?)"
            " ON CONFLICT(token, relay) DO UPDATE SET last_used = excluded.last_used",
            (digest, relay, now),
        )

    def _bound_relays(self, digest: bytes, now: int) -> dict[str, int]:
        rows = self._db.execute(
            "SELECT relay, last_used FROM token_relays WHERE token = ? AND last_used > ?", (digest, now - RELAY_WINDOW)
        ).fetchall()
        return dict(rows)

    @staticmethod
    def _stale(relays: dict[str, int], now: int) -> str | None:
        """The least recently used binding if it is older than STALE_BINDING."""
        if not relays:
            return None
        oldest = min(relays, key=relays.__getitem__)
        return oldest if relays[oldest] <= now - STALE_BINDING else None

    def forget(self, token: str) -> None:
        """An invalid token (APNs 410) is dead: drop its binding."""
        self._db.execute("DELETE FROM token_relays WHERE token = ?", (token_hash(token),))

    # ---- housekeeping --------------------------------------------------------

    def prune(self, now: float) -> None:
        now = int(now)
        self._prune_seen(now)
        self._db.execute("DELETE FROM token_relays WHERE last_used <= ?", (now - FORGET_AFTER,))
        self._db.execute("DELETE FROM delivered WHERE last_ok <= ?", (now - FORGET_AFTER,))

    def writable(self) -> bool:
        try:
            self._db.execute("BEGIN IMMEDIATE")
            self._db.execute("ROLLBACK")
        except sqlite3.Error:
            return False
        return True

    def counts(self) -> dict[str, int]:
        return {
            "tokens": self._db.execute("SELECT COUNT(DISTINCT token) FROM token_relays").fetchone()[0],
            "seen_signatures": self._seen_count,
        }
