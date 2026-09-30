"""Relay limits: every quota, rate and timeout in one place, overridable in `[limits]` of relay.toml.

The defaults are the values the relay has always used. Raising them costs memory, disk and the
protection they give against a misbehaving (or stolen) bridge or phone key; see docs/relay.md.
"""

import dataclasses
import math
from dataclasses import dataclass

MIB = 1024 * 1024
DAY = 86_400


@dataclass(frozen=True)
class Limits:
    # Connections
    max_connections: int = 500
    # Unauthenticated sockets (pairing, handshakes) may use at most this share, so a flood from
    # many addresses cannot lock out paired bridges and phones.
    max_unauthenticated: int = 200
    max_connections_per_ip: int = 16
    handshake_timeout: float = 15.0
    messages_per_window: int = 200
    message_window_seconds: float = 10.0
    # Pairing
    pair_per_minute: int = 20
    pair_session_timeout: float = 90.0
    slot_ttl: float = 600.0
    max_slots_per_bridge: int = 5
    max_slot_attempts: int = 3
    max_devices_per_bridge: int = 20
    # Calls
    turn_requests_per_minute: int = 6
    rings_per_minute: int = 10
    # Mailbox
    mails_per_minute: int = 120
    alerts_per_window: int = 20
    alert_window_seconds: float = 600.0
    # A phone that is online but does not ack a mail this fast is probably suspended: push it.
    mail_ack_grace: float = 3.0
    mail_max_messages: int = 500
    mail_max_bytes: int = 20 * MIB
    mail_ttl_seconds: int = 7 * DAY
    # Attachments
    blob_max_per_recipient: int = 20
    blob_quota_bytes: int = 50 * MIB
    blob_ttl_seconds: int = 7 * DAY
    blob_uploads_per_hour: int = 60
    blob_tickets_per_hour: int = 240
    blob_ticket_seconds: float = 300.0
    max_blob_transfers: int = 20
    max_blob_downloads: int = 20
    # Whole-request deadlines, so a slow sender or reader cannot hold a transfer slot forever.
    blob_upload_seconds: float = 300.0
    blob_download_seconds: float = 300.0
    # A download ticket works this many times (a retry after a dropped connection), then never.
    blob_download_uses: int = 3
    # Disk: mailbox and attachments together, and the free space kept on the data volume.
    storage_max_bytes: int = 2048 * MIB
    min_free_bytes: int = 256 * MIB
    # Background maintenance
    sweep_seconds: float = 15.0
    expiry_sweep_seconds: float = 600.0


_FIELDS = {f.name: f for f in dataclasses.fields(Limits)}


def parse(section: dict | None) -> Limits:
    """`[limits]` from relay.toml; unknown keys and non-positive values are errors."""
    section = section or {}
    unknown = sorted(set(section) - set(_FIELDS))
    if unknown:
        raise ValueError(f"unknown limits: {', '.join(unknown)}")
    values = {}
    for name, value in section.items():
        kind = type(_FIELDS[name].default)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"limits.{name} must be a number")
        if kind is int and not float(value).is_integer():
            raise ValueError(f"limits.{name} must be a whole number")
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"limits.{name} must be positive")
        values[name] = kind(value)
    limits = Limits(**values)
    if limits.max_unauthenticated > limits.max_connections:
        raise ValueError("limits.max_unauthenticated must not exceed limits.max_connections")
    return limits
