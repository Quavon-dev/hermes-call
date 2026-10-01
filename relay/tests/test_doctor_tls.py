"""doctor's certificate verdict: relative to the certificate's lifetime (Let's Encrypt also issues 6-day certificates)."""

import datetime

from hermescall_relay.doctor import cert_verdict

DAY = datetime.timedelta(days=1)
NOW = datetime.datetime(2026, 10, 1, 18, 0, tzinfo=datetime.UTC)


def test_a_fresh_short_lived_certificate_is_fine() -> None:
    level, text = cert_verdict(NOW - DAY / 4, NOW + 6.6 * DAY, NOW)
    assert level == "ok", text


def test_a_short_lived_certificate_past_two_thirds_warns() -> None:
    level, _ = cert_verdict(NOW - 5 * DAY, NOW + 1.5 * DAY, NOW)
    assert level == "warn"


def test_a_90_day_certificate_warns_two_weeks_ahead() -> None:
    assert cert_verdict(NOW - 70 * DAY, NOW + 20 * DAY, NOW)[0] == "ok"
    assert cert_verdict(NOW - 80 * DAY, NOW + 10 * DAY, NOW)[0] == "warn"


def test_an_expired_certificate_fails() -> None:
    level, text = cert_verdict(NOW - 10 * DAY, NOW - DAY, NOW)
    assert level == "fail" and "expired" in text
