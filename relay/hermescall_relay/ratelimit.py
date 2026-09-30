import time
from collections import deque


class FailureLimiter:
    """Locks a key out after `max_failures` within `window` seconds."""

    def __init__(self, max_failures: int = 10, window: float = 900, lockout: float = 900, max_keys: int = 50_000) -> None:
        self._max = max_failures
        self._window = window
        self._lockout = lockout
        self._max_keys = max_keys
        self._failures: dict[str, deque[float]] = {}
        self._locked: dict[str, float] = {}

    def is_locked(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        until = self._locked.get(key)
        if until is None:
            return False
        if until <= now:
            del self._locked[key]
            return False
        return True

    def fail(self, key: str, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        if len(self._failures) >= self._max_keys or len(self._locked) >= self._max_keys:
            self._prune(now)
        hits = self._failures.setdefault(key, deque())
        hits.append(now)
        while hits and hits[0] <= now - self._window:
            hits.popleft()
        if len(hits) >= self._max:
            self._locked[key] = now + self._lockout
            del self._failures[key]

    def _prune(self, now: float) -> None:
        """Drops expired state, then the oldest entries; never wipes everyone's counters at once."""
        self._locked = {key: until for key, until in self._locked.items() if until > now}
        self._failures = {key: hits for key, hits in self._failures.items() if hits and hits[-1] > now - self._window}
        if len(self._failures) >= self._max_keys:
            newest = sorted(self._failures.items(), key=lambda item: item[1][-1])[len(self._failures) // 2 :]
            self._failures = dict(newest)


class RateLimiter:
    """Sliding-window limit of `limit` events per `window` seconds per key.

    When `max_keys` keys are tracked, a new key is denied; with `evict=True` the least recently
    used key is dropped instead, so filling the table cannot lock out newcomers (for keys an
    attacker can mint cheaply, e.g. push tokens or IPv6 prefixes).
    """

    def __init__(self, limit: int, window: float, max_keys: int = 50_000, evict: bool = False) -> None:
        self._limit = limit
        self._window = window
        self._max_keys = max_keys
        self._evict = evict
        self._events: dict[str, deque[float]] = {}

    def __contains__(self, key: str) -> bool:
        return key in self._events

    def allow(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        if self._evict:
            if key in self._events:
                self._events[key] = self._events.pop(key)  # most recently used goes last
            elif len(self._events) >= self._max_keys:
                del self._events[next(iter(self._events))]
        elif len(self._events) >= self._max_keys and key not in self._events:
            self._events = {k: v for k, v in self._events.items() if v and v[-1] > now - self._window}
            if len(self._events) >= self._max_keys:
                return False
        events = self._events.setdefault(key, deque())
        while events and events[0] <= now - self._window:
            events.popleft()
        if len(events) >= self._limit:
            return False
        events.append(now)
        return True
