# SPDX-License-Identifier: MIT
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_spdx  # noqa: E402


def test_header_after_shebang_counts(tmp_path: Path) -> None:
    script = tmp_path / "a.sh"
    script.write_text("#!/usr/bin/env bash\n# SPDX-License-Identifier: MIT\necho hi\n")
    assert check_spdx.has_header(script)


def test_missing_header_fails_only_for_source_files(tmp_path: Path, capsys) -> None:
    swift = tmp_path / "View.swift"
    swift.write_text("import SwiftUI\n")
    notes = tmp_path / "notes.md"
    notes.write_text("no header needed\n")
    assert check_spdx.main([str(swift), str(notes)]) == 1
    assert "// SPDX-License-Identifier: MIT" in capsys.readouterr().err
    swift.write_text("// SPDX-License-Identifier: MIT\nimport SwiftUI\n")
    assert check_spdx.main([str(swift), str(notes)]) == 0


def test_vendored_code_is_excluded() -> None:
    assert not check_spdx.is_source("third_party/cpace/cpace.py")
    assert check_spdx.is_source("relay/hermescall_relay/server.py")
