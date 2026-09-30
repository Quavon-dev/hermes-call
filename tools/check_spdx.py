# SPDX-License-Identifier: MIT
"""Checks that source files carry an SPDX license header in their first lines.

    python3 tools/check_spdx.py FILE...            check these files
    python3 tools/check_spdx.py --added-since REF  check files added since REF (CI: the PR base)
    python3 tools/check_spdx.py --report           count tracked source files without a header

Only new files are enforced; older files get their header when they are next touched.
Header, as the first or second line (after a shebang):  # SPDX-License-Identifier: MIT
(// for Swift and Metal).
"""

import argparse
import subprocess
import sys
from pathlib import Path

EXTENSIONS = {".py", ".sh", ".swift", ".metal"}
HEAD_LINES = 5
# Vendored or generated code keeps its own upstream license headers.
EXCLUDED_PREFIXES = ("third_party/",)
TAG = "SPDX-License-Identifier:"


def is_source(path: str) -> bool:
    return Path(path).suffix in EXTENSIONS and not path.startswith(EXCLUDED_PREFIXES)


def has_header(path: Path) -> bool:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            head = [handle.readline() for _ in range(HEAD_LINES)]
    except OSError as error:
        print(f"{path}: cannot read ({error})", file=sys.stderr)
        return False
    return any(TAG in line for line in head)


def git_lines(*args: str) -> list[str]:
    result = subprocess.run(["git", *args], check=True, capture_output=True, text=True)  # noqa: S607
    return [line for line in result.stdout.splitlines() if line]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--added-since", metavar="REF", help="check files added since this git ref")
    group.add_argument("--report", action="store_true", help="count tracked source files without a header")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)

    if args.report:
        tracked = [path for path in git_lines("ls-files") if is_source(path)]
        missing = [path for path in tracked if not has_header(Path(path))]
        print(f"{len(missing)} of {len(tracked)} tracked source files have no SPDX header")
        return 0
    if args.added_since:
        files = git_lines("diff", "--name-only", "--diff-filter=A", f"{args.added_since}...HEAD")
    else:
        files = args.files
    missing = [path for path in files if is_source(path) and Path(path).exists() and not has_header(Path(path))]
    for path in missing:
        comment = "//" if Path(path).suffix in {".swift", ".metal"} else "#"
        print(f"{path}: missing '{comment} {TAG} MIT' in the first {HEAD_LINES} lines", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
