#!/usr/bin/env python3
"""Select Wilted's iPhone 17 Pro on iOS 26 or a type supported by an exact runtime."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


DEVICE_NAME = "iPhone 17 Pro"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
PREFERRED_EXACT_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
DEVICE_TYPE_PREFIX = "com.apple.CoreSimulator.SimDeviceType.iPhone-"
RUNTIME_RE = re.compile(r"iOS-(\d+(?:[-.]\d+)*)$", re.IGNORECASE)


def runtime_version(identifier: str) -> tuple[int, ...] | None:
    """Return the numeric iOS runtime version from a simctl runtime key."""
    match = RUNTIME_RE.search(identifier)
    if not match:
        return None
    version = tuple(int(part) for part in re.split(r"[-.]", match.group(1)))
    return version if version else None


def select(
    payload: dict[str, Any], *, exact_version: tuple[int, ...] | None = None,
) -> tuple[str, str]:
    """Return the newest iOS 26 simulator or a supported exact iOS runtime."""
    if exact_version is not None and isinstance(payload.get("runtimes"), list):
        candidates: list[tuple[tuple[int, int, int, str, str], str, str]] = []
        for runtime in payload["runtimes"]:
            if not isinstance(runtime, dict) or runtime.get("isAvailable") is False:
                continue
            identifier = runtime.get("identifier")
            version = runtime.get("version")
            if not isinstance(identifier, str) or not identifier.startswith(
                "com.apple.CoreSimulator.SimRuntime.iOS-"
            ):
                continue
            if isinstance(version, str) and re.fullmatch(r"\d+(?:\.\d+)*", version):
                parsed_version = tuple(int(part) for part in version.split("."))
            else:
                parsed_version = runtime_version(identifier)
            if parsed_version != exact_version:
                continue

            supported_types = runtime.get("supportedDeviceTypes")
            if not isinstance(supported_types, list):
                continue
            for device in supported_types:
                if not isinstance(device, dict):
                    continue
                device_type = device.get("identifier")
                if not isinstance(device_type, str) or not device_type.startswith(DEVICE_TYPE_PREFIX):
                    continue
                family = device.get("productFamily")
                if family is not None and family != "iPhone":
                    continue
                name = device.get("name")
                if not isinstance(name, str):
                    name = device_type.rsplit(".", 1)[-1].replace("-", " ")
                match = re.search(r"iPhone[- ](\d+)(?:[- ](.*))?", device_type + " " + name)
                generation = int(match.group(1)) if match else 0
                pro_rank = int("pro" not in name.lower())
                preference = (
                    int(device_type != PREFERRED_EXACT_DEVICE_TYPE),
                    -generation,
                    pro_rank,
                    name,
                    identifier,
                )
                candidates.append((preference, identifier, device_type))
        if candidates:
            _, runtime_identifier, device_type = min(candidates, key=lambda item: item[0])
            return runtime_identifier, device_type
        requested = ".".join(str(part) for part in exact_version)
        raise ValueError(f"no available iOS {requested} runtime supports an iPhone simulator")

    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("simctl JSON has no devices object")
    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for runtime, runtime_devices in devices.items():
        version = runtime_version(runtime)
        if version is None or not isinstance(runtime_devices, list):
            continue
        if exact_version is None and version[0] != 26:
            continue
        if exact_version is not None and version != exact_version:
            continue
        for device in runtime_devices:
            if not isinstance(device, dict):
                continue
            if device.get("isAvailable") is False or device.get("state") == "Unavailable":
                continue
            device_type = device.get("deviceTypeIdentifier")
            persistent_name = "wilted-persistent-" + runtime.removeprefix(
                "com.apple.CoreSimulator.SimRuntime."
            )
            if device_type == DEVICE_TYPE and device.get("name") in {DEVICE_NAME, persistent_name}:
                candidates.append((version, runtime, DEVICE_TYPE))
    if not candidates:
        requested = (
            "an iOS 26.x runtime" if exact_version is None
            else "iOS " + ".".join(str(part) for part in exact_version)
        )
        raise ValueError(f"no available {DEVICE_NAME} on {requested}")
    version, runtime, device_type = max(candidates, key=lambda item: item[0])
    del version
    return runtime, device_type


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-version", help="require this exact dotted iOS runtime version")
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        exact_version = None
        if args.runtime_version:
            if not re.fullmatch(r"\d+(?:\.\d+)*", args.runtime_version):
                raise ValueError("runtime version must be a dotted numeric version")
            exact_version = tuple(int(part) for part in args.runtime_version.split("."))
        runtime, device_type = select(payload, exact_version=exact_version)
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"ios-simulator-selector: {error}", file=sys.stderr)
        return 1
    print(f"{runtime}\t{device_type}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
