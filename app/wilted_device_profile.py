"""Add a registered device to Wilted's manual iOS Development profile.

Only the manual "Wilted iOS Development" profile carries the CarPlay audio and
Siri entitlements, and App Store Connect cannot edit a profile in place, so a
device is added by replacing the profile. Profile names are unique, so the
replacement (the old profile's bundle ID, certificates and devices plus the new
device) is first created under a check name and must list that device and
carry every entitlement the old one did; the check copy is then deleted. A
check that falls short leaves the old profile untouched. Only after a passing
check is the old profile deleted and the replacement created under the real
name. The bridge imports this module only for this operation, so its other
operations stay standalone.
"""

from __future__ import annotations

import base64
import os
import plistlib
import re
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any
from urllib.parse import quote

PROFILE_NAME = "Wilted iOS Development"
PROFILE_TYPE = "IOS_APP_DEVELOPMENT"
CHECK_NAME = f"{PROFILE_NAME} check"
_UDID = re.compile(r"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$")

# request(method, path, body) returns the decoded JSON body, or {} for a 204.
Request = Callable[[str, str, Mapping[str, Any] | None], Mapping[str, Any]]


class ProfileError(ValueError):
    """A redacted profile-replacement failure category."""


def profile_plist(content: str) -> dict[str, Any]:
    """Return the property list embedded in a profile's base64 CMS payload."""

    raw = base64.b64decode(content)
    start, end = raw.find(b"<?xml"), raw.find(b"</plist>")
    if start < 0 or end < start:
        raise ProfileError("profile-content-unreadable")
    return plistlib.loads(raw[start:end + len(b"</plist>")])


def _ids(resource: Mapping[str, Any], relationship: str) -> list[str]:
    data = resource.get("relationships", {}).get(relationship, {}).get("data")
    if not isinstance(data, list):
        raise ProfileError(f"profile-{relationship}-unavailable")
    return [item["id"] for item in data]


def _lists_device(plist: Mapping[str, Any], udid: str) -> bool:
    return udid.upper() in {str(value).upper() for value in plist.get("ProvisionedDevices", [])}


def add_device(udid: str, request: Request, *, install_dir: Path | None = None) -> dict[str, Any]:
    """Replace the manual profile with one that also lists ``udid``.

    Returns credential-free evidence. With ``install_dir`` the new profile is
    written there as ``<UUID>.mobileprovision`` for Xcode to sign with.
    """

    if not _UDID.fullmatch(udid):
        raise ProfileError("device-udid-invalid")
    query = (f"/profiles?filter[name]={quote(PROFILE_NAME)}&filter[profileType]={PROFILE_TYPE}"
             "&include=bundleId,certificates,devices&limit[certificates]=50&limit[devices]=50")
    profiles = request("GET", query, None).get("data", [])
    if len(profiles) != 1:
        raise ProfileError("profile-not-unique")
    old = profiles[0]
    if old.get("attributes", {}).get("profileState") != "ACTIVE":
        raise ProfileError("profile-not-active")
    bundle = old.get("relationships", {}).get("bundleId", {}).get("data", {}).get("id")
    if not bundle:
        raise ProfileError("profile-bundleId-unavailable")
    certificates, devices = _ids(old, "certificates"), _ids(old, "devices")
    old_plist = profile_plist(old["attributes"]["profileContent"])
    found = request("GET", f"/devices?filter[udid]={quote(udid)}&filter[status]=ENABLED", None).get("data", [])
    if len(found) != 1:
        raise ProfileError("device-not-registered")
    device = found[0]["id"]
    evidence: dict[str, Any] = {"profileName": PROFILE_NAME, "oldProfileUUID": old_plist["UUID"], "deviceUDID": udid}
    if device in devices or _lists_device(old_plist, udid):
        return {**evidence, "result": "already-present", "deviceCount": len(devices)}
    relationships = {
        "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
        "certificates": {"data": [{"type": "certificates", "id": value} for value in certificates]},
        "devices": {"data": [{"type": "devices", "id": value} for value in [*devices, device]]},
    }

    def create(name: str) -> tuple[Mapping[str, Any], dict[str, Any]]:
        body = {"data": {"type": "profiles", "attributes": {"name": name, "profileType": PROFILE_TYPE}, "relationships": relationships}}
        created = request("POST", "/profiles", body)["data"]
        try:
            plist = profile_plist(created["attributes"]["profileContent"])
            missing = sorted(set(old_plist["Entitlements"]) - set(plist["Entitlements"]))
            if missing or not _lists_device(plist, udid):
                raise ProfileError("replacement-incomplete:" + (",".join(missing) or "device-missing"))
        except (KeyError, ProfileError):
            if name == CHECK_NAME:
                request("DELETE", f"/profiles/{created['id']}", None)
            raise
        return created, plist

    check, _ = create(CHECK_NAME)
    request("DELETE", f"/profiles/{check['id']}", None)
    request("DELETE", f"/profiles/{old['id']}", None)
    created, new_plist = create(PROFILE_NAME)
    installed = None
    if install_dir is not None:
        install_dir.mkdir(parents=True, exist_ok=True)
        installed = install_dir / f"{new_plist['UUID']}.mobileprovision"
        installed.write_bytes(base64.b64decode(created["attributes"]["profileContent"]))
        os.chmod(installed, 0o644)
    return {**evidence, "result": "replaced", "newProfileUUID": new_plist["UUID"],
            "deviceCount": len(devices) + 1, "entitlements": sorted(new_plist["Entitlements"]),
            "installedPath": str(installed) if installed else None}
