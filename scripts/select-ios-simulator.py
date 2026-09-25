#!/usr/bin/env python3
"""Select Wilted's iPhone 17 Pro type on the newest available iOS 26 runtime."""

from __future__ import annotations

import json
import re
import sys
from typing import Any


DEVICE_NAME = "iPhone 17 Pro"
RUNTIME_RE = re.compile(r"iOS-(\d+(?:[-.]\d+)*)$", re.IGNORECASE)


def runtime_version(identifier: str) -> tuple[int, ...] | None:
    """Return the numeric iOS runtime version from a simctl runtime key."""
    match = RUNTIME_RE.search(identifier)
    if not match:
        return None
    version = tuple(int(part) for part in re.split(r"[-.]", match.group(1)))
    return version if version and version[0] == 26 else None


def select(payload: dict[str, Any]) -> tuple[str, str]:
    """Return the newest supported runtime and matching iPhone device type."""
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("simctl JSON has no devices object")
    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for runtime, runtime_devices in devices.items():
        version = runtime_version(runtime)
        if version is None or not isinstance(runtime_devices, list):
            continue
        for device in runtime_devices:
            if not isinstance(device, dict) or device.get("name") != DEVICE_NAME:
                continue
            if device.get("isAvailable") is False or device.get("state") == "Unavailable":
                continue
            device_type = device.get("deviceTypeIdentifier")
            if isinstance(device_type, str) and device_type:
                candidates.append((version, runtime, device_type))
    if not candidates:
        raise ValueError(f"no available {DEVICE_NAME} on an iOS 26.x runtime")
    version, runtime, device_type = max(candidates, key=lambda item: item[0])
    del version
    return runtime, device_type


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        runtime, device_type = select(payload)
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"ios-simulator-selector: {error}", file=sys.stderr)
        return 1
    print(f"{runtime}\t{device_type}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
