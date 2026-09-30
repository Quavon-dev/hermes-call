# SPDX-License-Identifier: MIT
"""Prints SIMULATOR_ID=<udid> for CI: an available iPhone simulator on the newest iOS runtime.

    python3 tools/pick_simulator.py >>"$GITHUB_ENV"

Prefers the models the docs and screenshots use; runner images differ in which ones they ship.
"""

import json
import re
import subprocess
import sys

PREFERRED = ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16")
RUNTIME = re.compile(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)")


def pick(devices_by_runtime: dict) -> dict | None:
    runtimes = []
    for runtime, devices in devices_by_runtime.items():
        match = RUNTIME.fullmatch(runtime)
        if match:
            runtimes.append(((int(match[1]), int(match[2])), devices))
    for _, devices in sorted(runtimes, key=lambda item: item[0], reverse=True):
        phones = [device for device in devices if device.get("isAvailable") and device["name"].startswith("iPhone")]
        for name in PREFERRED:
            for device in phones:
                if device["name"] == name:
                    return device
        if phones:
            return phones[0]
    return None


def main() -> int:
    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    )
    device = pick(json.loads(listing.stdout)["devices"])
    if device is None:
        print("no available iPhone simulator", file=sys.stderr)
        return 1
    print(f"picked {device['name']} ({device['udid']})", file=sys.stderr)
    print(f"SIMULATOR_ID={device['udid']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
