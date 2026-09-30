"""Prometheus text exposition without a client library: counters with labels and callback gauges.

Metrics never carry identities, tokens or addresses; labels are fixed words (a result, a reason).
"""

from collections.abc import Callable
from dataclasses import dataclass, field

_Labels = tuple[tuple[str, str], ...]


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _format(name: str, labels: _Labels, value: float) -> str:
    rendered = ",".join(f'{key}="{_escape(val)}"' for key, val in labels)
    number = int(value) if float(value).is_integer() else value
    return f"{name}{{{rendered}}} {number}" if rendered else f"{name} {number}"


@dataclass
class Counter:
    name: str
    help: str
    values: dict[_Labels, float] = field(default_factory=dict)

    def inc(self, amount: float = 1, **labels: str) -> None:
        key = tuple(sorted(labels.items()))
        self.values[key] = self.values.get(key, 0) + amount

    def get(self, **labels: str) -> float:
        return self.values.get(tuple(sorted(labels.items())), 0)

    def render(self) -> list[str]:
        lines = [f"# HELP {self.name} {self.help}", f"# TYPE {self.name} counter"]
        return lines + [_format(self.name, labels, value) for labels, value in sorted(self.values.items())]


@dataclass
class Gauge:
    """A value read at scrape time; `kind="counter"` for totals kept elsewhere (e.g. push stats)."""

    name: str
    help: str
    read: Callable[[], float | dict[_Labels, float]]
    kind: str = "gauge"

    def render(self) -> list[str]:
        lines = [f"# HELP {self.name} {self.help}", f"# TYPE {self.name} {self.kind}"]
        value = self.read()
        if isinstance(value, dict):
            return lines + [_format(self.name, labels, v) for labels, v in sorted(value.items())]
        return [*lines, _format(self.name, (), value)]


class Registry:
    def __init__(self, prefix: str) -> None:
        self._prefix = prefix
        self._metrics: dict[str, Counter | Gauge] = {}

    def counter(self, name: str, help_text: str) -> Counter:
        metric = self._metrics.setdefault(f"{self._prefix}_{name}", Counter(f"{self._prefix}_{name}", help_text))
        assert isinstance(metric, Counter)
        return metric

    def gauge(self, name: str, help_text: str, read: Callable[[], float | dict[_Labels, float]], kind: str = "gauge") -> Gauge:
        metric = Gauge(f"{self._prefix}_{name}", help_text, read, kind)
        self._metrics[metric.name] = metric
        return metric

    def render(self) -> str:
        lines: list[str] = []
        for metric in self._metrics.values():
            try:
                lines += metric.render()
            except Exception:  # noqa: BLE001, S112 - one broken gauge must not hide the rest
                continue
        return "\n".join(lines) + "\n"


CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"
