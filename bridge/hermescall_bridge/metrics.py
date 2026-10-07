"""Prometheus text exposition for `/metrics`, hand-written (no client library).

Only counts, timings and queue depths; never ids, names or content.
"""

import math
import sqlite3
import threading
from collections.abc import Awaitable, Callable, Iterable

LATENCY_BUCKETS = (0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0, 10.0)
RTF_BUCKETS = (0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.0)
STAGE_BUCKETS = (0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0)


class Counter:
    def __init__(self, name: str, help_text: str, labels: tuple[str, ...] = ()) -> None:
        self.name, self.help, self.labels = name, help_text, labels
        self._values: dict[tuple[str, ...], float] = {}
        self._lock = threading.Lock()

    def inc(self, *label_values: str, amount: float = 1.0) -> None:
        with self._lock:
            self._values[label_values] = self._values.get(label_values, 0.0) + amount

    def value(self, *label_values: str) -> float:
        return self._values.get(label_values, 0.0)

    def render(self) -> Iterable[str]:
        yield f"# HELP {self.name} {self.help}"
        yield f"# TYPE {self.name} counter"
        with self._lock:
            items = sorted(self._values.items()) or ([((), 0.0)] if not self.labels else [])
        for values, value in items:
            yield f"{self.name}{_labels(self.labels, values)} {_num(value)}"


class Histogram:
    def __init__(self, name: str, help_text: str, buckets: tuple[float, ...]) -> None:
        self.name, self.help, self.buckets = name, help_text, buckets
        self._counts = [0] * len(buckets)
        self._sum = 0.0
        self._count = 0
        self._lock = threading.Lock()

    def observe(self, value: float) -> None:
        if not math.isfinite(value) or value < 0:
            return
        with self._lock:
            self._sum += value
            self._count += 1
            for index, bound in enumerate(self.buckets):
                if value <= bound:
                    self._counts[index] += 1

    @property
    def count(self) -> int:
        return self._count

    def render(self) -> Iterable[str]:
        yield f"# HELP {self.name} {self.help}"
        yield f"# TYPE {self.name} histogram"
        with self._lock:
            counts, total, count = list(self._counts), self._sum, self._count
        for bound, value in zip(self.buckets, counts, strict=True):
            yield f'{self.name}_bucket{{le="{_num(bound)}"}} {value}'
        yield f'{self.name}_bucket{{le="+Inf"}} {count}'
        yield f"{self.name}_sum {_num(total)}"
        yield f"{self.name}_count {count}"


class Gauge:
    """Read at scrape time from a callback (queue depths, connection state)."""

    def __init__(self, name: str, help_text: str, read: Callable[[], float] | None = None) -> None:
        self.name, self.help, self.read = name, help_text, read

    def render(self) -> Iterable[str]:
        if self.read is None:
            return
        yield f"# HELP {self.name} {self.help}"
        yield f"# TYPE {self.name} gauge"
        yield f"{self.name} {_num(float(self.read()))}"


def _labels(names: tuple[str, ...], values: tuple[str, ...]) -> str:
    if not names:
        return ""
    pairs = ",".join(f'{n}="{_escape(v)}"' for n, v in zip(names, values, strict=True))
    return "{" + pairs + "}"


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _num(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else repr(float(value))


class Registry:
    def __init__(self) -> None:
        self.call_latency = Histogram(
            "hermescall_bridge_call_latency_seconds", "End of the owner's speech to the agent's first audio.", LATENCY_BUCKETS
        )
        self.acknowledgement_latency = Histogram(
            "hermescall_bridge_acknowledgement_latency_seconds",
            "End of the owner's speech to the acknowledgement audio (excluded from call_latency).",
            LATENCY_BUCKETS,
        )
        self.hermes_first_text = Histogram(
            "hermescall_bridge_hermes_first_text_seconds", "Transcript ready to Hermes' first reply text.", STAGE_BUCKETS
        )
        self.tts_first_audio = Histogram(
            "hermescall_bridge_tts_first_audio_seconds", "Speech synthesis request to its first audio.", STAGE_BUCKETS
        )
        self.speech_gaps = Counter(
            "hermescall_bridge_speech_gaps_total", "Mid-reply silences: playback ran dry before the next sentence."
        )
        self.stt_seconds = Histogram(
            "hermescall_bridge_stt_seconds", "Speech recognition time of a live-call utterance.", STAGE_BUCKETS
        )
        self.utterance_seconds = Histogram(
            "hermescall_bridge_utterance_seconds", "Length of the owner's utterances sent to recognition.", STAGE_BUCKETS
        )
        self.playback_ignored_seconds = Counter(
            "hermescall_bridge_playback_ignored_seconds_total",
            "Microphone audio dropped while the agent was audible (barge_in = false: speakerphone echo guard).",
        )
        self.barge_ins = Counter("hermescall_bridge_barge_ins_total", "Owner speech or taps that cut the agent off.")
        self.stt_rtf = Histogram(
            "hermescall_bridge_stt_realtime_factor", "Speech recognition time divided by audio duration.", RTF_BUCKETS
        )
        self.turn_errors = Counter("hermescall_bridge_turn_errors_total", "Call turns that failed, by cause.", ("cause",))
        self.calls = Counter("hermescall_bridge_calls_total", "Calls started, by direction.", ("direction",))
        self.chat_messages = Counter("hermescall_bridge_chat_messages_total", "Chat messages, by direction.", ("direction",))
        self.gauges: dict[str, Gauge] = {}
        # Awaited before a scrape (reads that belong on another thread, e.g. SQLite queue depths).
        self.refresh: Callable[[], Awaitable[None]] | None = None

    def gauge(self, name: str, help_text: str, read: Callable[[], float]) -> None:
        self.gauges[name] = Gauge(name, help_text, read)

    def render(self) -> str:
        lines: list[str] = []
        for metric in (
            self.call_latency,
            self.acknowledgement_latency,
            self.hermes_first_text,
            self.tts_first_audio,
            self.speech_gaps,
            self.stt_seconds,
            self.utterance_seconds,
            self.playback_ignored_seconds,
            self.barge_ins,
            self.stt_rtf,
            self.turn_errors,
            self.calls,
            self.chat_messages,
        ):
            lines.extend(metric.render())
        for gauge in self.gauges.values():
            try:
                lines.extend(gauge.render())
            except (sqlite3.Error, OSError, RuntimeError, ValueError, AttributeError, KeyError):
                continue  # a broken gauge (or one not refreshed yet) must not break the scrape
        return "\n".join(lines) + "\n"


METRICS = Registry()
