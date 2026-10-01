"""Device ids are base64url: about one in 64 starts with "-", which argparse would take for an option."""

from hermescall_bridge import cli


def test_device_revoke_accepts_an_id_starting_with_a_dash() -> None:
    assert cli.protect_ids(["device", "revoke", "-AbCd"]) == ["device", "revoke", "--", "-AbCd"]


def test_call_device_accepts_an_id_starting_with_a_dash() -> None:
    assert cli.protect_ids(["call", "--device", "-AbCd"]) == ["call", "--device=-AbCd"]


def test_other_arguments_are_left_alone() -> None:
    argv = ["--config", "/etc/x.toml", "device", "revoke", "AbCd"]
    assert cli.protect_ids(argv) == argv
    assert cli.protect_ids(["device", "revoke", "--help"]) == ["device", "revoke", "--help"]
