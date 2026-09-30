"""What the push gateway remembers across restarts: seen request signatures and token use.

Replay cache: a SHA-256 of every accepted signature until it is too old to pass the clock check,
so a restart cannot re-open the window for a captured request.

Token binding (trust on first use, soft): per device token (stored as its SHA-256, never the
token) the relays that pushed to it. At most MAX_RELAYS_PER_TOKEN relays may use one token within
RELAY_WINDOW; a relay that stops using a token frees its place after that. Moving to a new relay,
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
MAX_SEEN = 200_000
MAX_RELAYS_PER_TOKEN = 5
RELAY_WINDOW = 30 * 86_400
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
)
SCHEMA_VERSION = 1


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
        self._db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    def close(self) -> None:
        self._db.close()

    # ---- replay cache ---------------------------------------------------

    def seen_signature(self, signature: bytes, now: float) -> bool:
        digest = hashlib.sha256(signature).digest()
        return self._db.execute("SELECT 1 FROM seen WHERE sig = ? AND expires > ?", (digest, int(now))).fetchone() is not None

    def remember_signature(self, signature: bytes, now: float) -> str:
        """ "new", "replayed", or "full" (the caller refuses rather than forgetting a signature)."""
        digest = hashlib.sha256(signature).digest()
        if self.seen_signature(signature, now):
            return "replayed"
        count = self._db.execute("SELECT COUNT(*) FROM seen").fetchone()[0]
        if count >= MAX_SEEN:
            self._db.execute("DELETE FROM seen WHERE expires <= ?", (int(now),))
            if self._db.execute("SELECT COUNT(*) FROM seen").fetchone()[0] >= MAX_SEEN:
                return "full"
        self._db.execute("INSERT OR REPLACE INTO seen(sig, expires) VALUES(?, ?)", (digest, int(now) + REPLAY_SECONDS))
        return "new"

    # ---- token bindings ---------------------------------------------------

    def check_token(self, token: str, relay: str, now: float) -> Decision:
        """Applies the binding rule and, when allowed, records the use."""
        digest, now = token_hash(token), int(now)
        if not self._relay_allowed(digest, relay, now):
            return Decision(False, "token_bound")
        self._db.execute(
            "INSERT INTO token_relays(token, relay, last_used) VALUES(?, ?, ?)"
            " ON CONFLICT(token, relay) DO UPDATE SET last_used = excluded.last_used",
            (digest, relay, now),
        )
        return Decision(True)

    def _relay_allowed(self, digest: bytes, relay: str, now: int) -> bool:
        rows = self._db.execute(
            "SELECT relay FROM token_relays WHERE token = ? AND last_used > ?", (digest, now - RELAY_WINDOW)
        ).fetchall()
        relays = {row[0] for row in rows}
        return relay in relays or len(relays) < MAX_RELAYS_PER_TOKEN

    def forget(self, token: str) -> None:
        """An invalid token (APNs 410) is dead: drop its binding."""
        self._db.execute("DELETE FROM token_relays WHERE token = ?", (token_hash(token),))

    # ---- housekeeping --------------------------------------------------------

    def prune(self, now: float) -> None:
        now = int(now)
        self._db.execute("DELETE FROM seen WHERE expires <= ?", (now,))
        self._db.execute("DELETE FROM token_relays WHERE last_used <= ?", (now - FORGET_AFTER,))

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
            "seen_signatures": self._db.execute("SELECT COUNT(*) FROM seen").fetchone()[0],
        }
