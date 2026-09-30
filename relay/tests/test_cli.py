from pathlib import Path

from hermescall_relay import cli
from hermescall_relay.store import Store


def test_cli_pair_list_revoke(tmp_path: Path, capsys, monkeypatch) -> None:
    monkeypatch.setattr(cli.shutil, "which", lambda name: None)
    config = tmp_path / "relay.toml"
    config.write_text(f'authority = "relay.test"\ntls_pin = "{"P" * 43}"\ndb_path = "{tmp_path / "db"}"\n')
    assert cli.main(["--config", str(config), "pair"]) == 0
    out = capsys.readouterr().out
    assert "hermescall://pair?v=1&k=relay&r=relay.test" in out and "P" * 43 in out
    bridge = Store(tmp_path / "db").add_bridge(b"k" * 32)
    assert cli.main(["--config", str(config), "bridges"]) == 0
    assert bridge in capsys.readouterr().out
    assert cli.main(["--config", str(config), "revoke-bridge", bridge]) == 0
    assert cli.main(["--config", str(config), "revoke-bridge", bridge]) == 1
    assert cli.main(["--config", str(config), "check-config"]) == 0
    assert cli.main(["--config", str(tmp_path / "missing.toml"), "check-config"]) == 2
