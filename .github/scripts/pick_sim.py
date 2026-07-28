#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest installed iOS runtime.
Exits 1 if none found. Used by CI to pick a real destination instead of hardcoding one."""
import json
import re
import subprocess
import sys


def runtime_version(runtime_key: str):
    m = re.search(r"iOS[-\s.](\d+)[-.](\d+)", runtime_key)
    return tuple(int(x) for x in m.groups()) if m else (0, 0)


def main() -> int:
    raw = subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "-j"]
    )
    devices = json.loads(raw)["devices"]
    ios_runtimes = [k for k in devices if "iOS" in k]
    for runtime in sorted(ios_runtimes, key=runtime_version, reverse=True):
        for dev in devices[runtime]:
            if "iPhone" in dev.get("name", "") and dev.get("isAvailable", True):
                sys.stdout.write(dev["udid"])
                return 0
    sys.stderr.write("No available iPhone simulator found\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
