"""Logging setup shared by the relay and the push gateway: level and text or JSON lines."""

import json
import logging
import time

LEVELS = ("debug", "info", "warning", "error")
FORMATS = ("text", "json")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + f".{int(record.msecs):03d}Z",
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


def setup(level: str = "info", fmt: str = "text") -> None:
    handler = logging.StreamHandler()
    if fmt == "json":
        handler.setFormatter(JsonFormatter())
    else:
        handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    # httpx logs every request URL at INFO, and APNs URLs contain the device token.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)


def validate(level: object, fmt: object) -> tuple[str, str]:
    if level not in LEVELS:
        raise ValueError(f"log_level must be one of {', '.join(LEVELS)}")
    if fmt not in FORMATS:
        raise ValueError(f"log_format must be one of {', '.join(FORMATS)}")
    return str(level), str(fmt)
