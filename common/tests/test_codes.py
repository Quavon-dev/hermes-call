import pytest

from hermescall_common import codes
from hermescall_common.errors import ProtocolError

PIN = "A" * 43


def test_new_code_shape() -> None:
    code = codes.new_code(codes.new_device_slot())
    assert len(code.slot) == 3 and len(code.secret) == 5
    assert set(code.slot + code.secret) <= set(codes.ALPHABET)
    assert codes.parse_code(code.display()) == code


def test_parse_code_normalizes_confusables() -> None:
    assert codes.parse_code("r7k-q4mop") == codes.Code("R7K", "Q4M0P")
    assert codes.parse_code("ilx 23456") == codes.Code("11X", "23456")


@pytest.mark.parametrize("bad", ["", "ABC", "ABC-12", "ABC-1234U", "ABC-12345*", "A" * 30])
def test_parse_code_rejects(bad: str) -> None:
    with pytest.raises(ProtocolError):
        codes.parse_code(bad)


@pytest.mark.parametrize("pin", ["", PIN])
@pytest.mark.parametrize("host,port", [("relay.example.com", 443), ("203.0.113.7", 8443), ("[2001:db8::1]", 443)])
def test_uri_roundtrip(host: str, port: int, pin: str) -> None:
    invite = codes.PairingInvite("device", host, port, pin, codes.new_code(codes.new_device_slot(), codes.QR_SECRET_LEN))
    assert codes.parse_uri(invite.to_uri()) == invite


@pytest.mark.parametrize(
    "uri",
    [
        "https://pair?v=1&k=relay&r=a.example&c=ABC12345",
        "hermescall://pair?v=2&k=relay&r=a.example&c=ABC12345",
        "hermescall://pair?v=1&k=admin&r=a.example&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=evil.example/x&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=a.example:99999&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=a.example&c=ABC12345&pin=short",
        "hermescall://pair?v=1&k=relay&r=a.example&c=ABC12345&c=DEF12345",
        "hermescall://pair?v=1&k=relay&r=user@a.example&c=ABC12345",
        "hermescall://pair?v=1&k=relay&r=-bad.example&c=ABC12345",
        "hermescall://pair?garbage",
    ],
)
def test_parse_uri_rejects(uri: str) -> None:
    with pytest.raises(ProtocolError):
        codes.parse_uri(uri)


def test_authority() -> None:
    assert codes.parse_authority("Relay.Example.COM.") == ("relay.example.com", 443)
    assert codes.parse_authority("relay.example.com:8443") == ("relay.example.com", 8443)
    assert codes.format_authority("relay.example.com", 8443) == "relay.example.com:8443"


def test_slot_namespaces_are_disjoint() -> None:
    relay_slots = {codes.new_relay_slot() for _ in range(200)}
    device_slots = {codes.new_device_slot() for _ in range(200)}
    assert all(codes.is_relay_slot(s) for s in relay_slots)
    assert not any(codes.is_relay_slot(s) for s in device_slots)
    assert all(codes.is_valid_slot(s) for s in relay_slots | device_slots)


@pytest.mark.parametrize("text", ["AB", "QR", "AAB", "AA\n", "A=="])
def test_base64url_is_strict_and_canonical(text: str) -> None:
    from hermescall_common import wire

    with pytest.raises(ProtocolError):
        wire.b64d(text)
    assert wire.b64d("AA") == b"\x00"


def test_pin_with_trailing_newline_is_rejected() -> None:
    with pytest.raises(ProtocolError):
        codes.validate_pin("A" * 43 + "\n")
