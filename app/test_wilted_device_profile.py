"""Hermetic tests for replacing the manual iOS Development profile."""

from __future__ import annotations

import base64
import plistlib
import tempfile
import unittest
from pathlib import Path

from app import wilted_device_profile as profiles

PHONE = "00008140-0012005621E1801C"
IPAD = "00008122-000944560C46801C"
FULL = ["application-identifier", "com.apple.developer.carplay-audio", "com.apple.developer.siri"]


def content(uuid: str, udids: list[str], entitlements: list[str]) -> str:
    plist = plistlib.dumps({"UUID": uuid, "ProvisionedDevices": udids, "Entitlements": {key: True for key in entitlements}})
    return base64.b64encode(b"cms-header" + plist + b"cms-signature").decode()


class FakeAppStoreConnect:
    def __init__(self, *, new_entitlements: list[str] = FULL, registered: bool = True) -> None:
        self.calls: list[tuple[str, str]] = []
        self.new_entitlements = new_entitlements
        self.registered = registered

    def __call__(self, method: str, path: str, body):
        self.calls.append((method, path.split("?")[0]))
        if method == "GET" and path.startswith("/profiles"):
            return {"data": [{"id": "old", "attributes": {"profileState": "ACTIVE", "profileContent": content("old-uuid", [PHONE], FULL)},
                              "relationships": {"bundleId": {"data": {"id": "bundle"}}, "certificates": {"data": [{"id": "cert"}]},
                                                "devices": {"data": [{"id": "phone"}]}}}]}
        if method == "GET" and path.startswith("/devices"):
            return {"data": [{"id": "ipad"}]} if self.registered else {"data": []}
        if method == "POST":
            self.body = body
            name = body["data"]["attributes"]["name"]
            self.calls[-1] = ("POST", name)
            created = "check" if name == profiles.CHECK_NAME else "new"
            return {"data": {"id": created, "attributes": {"profileContent": content(f"{created}-uuid", [PHONE, IPAD], self.new_entitlements)}}}
        return {}


class DeviceProfileTests(unittest.TestCase):
    def test_checks_the_replacement_before_deleting_the_old_profile(self) -> None:
        api = FakeAppStoreConnect()
        with tempfile.TemporaryDirectory() as directory:
            proof = profiles.add_device(IPAD, api, install_dir=Path(directory))
            installed = Path(directory) / "new-uuid.mobileprovision"
            self.assertTrue(installed.is_file())
        self.assertEqual(proof["result"], "replaced")
        self.assertEqual(api.calls[-4:], [("POST", profiles.CHECK_NAME), ("DELETE", "/profiles/check"),
                                          ("DELETE", "/profiles/old"), ("POST", profiles.PROFILE_NAME)])
        devices = [item["id"] for item in api.body["data"]["relationships"]["devices"]["data"]]
        self.assertEqual(devices, ["phone", "ipad"])
        self.assertEqual(proof["entitlements"], FULL)

    def test_replacement_without_carplay_is_deleted_and_the_old_profile_kept(self) -> None:
        api = FakeAppStoreConnect(new_entitlements=["application-identifier", "com.apple.developer.siri"])
        with self.assertRaisesRegex(profiles.ProfileError, "carplay-audio"):
            profiles.add_device(IPAD, api)
        self.assertIn(("DELETE", "/profiles/check"), api.calls)
        self.assertNotIn(("DELETE", "/profiles/old"), api.calls)
        self.assertNotIn(("POST", profiles.PROFILE_NAME), api.calls)

    def test_a_device_already_listed_changes_nothing(self) -> None:
        api = FakeAppStoreConnect()
        proof = profiles.add_device(PHONE, api)
        self.assertEqual(proof["result"], "already-present")
        self.assertFalse([call for call in api.calls if call[0] in {"POST", "DELETE"}])

    def test_an_unregistered_device_or_malformed_udid_is_refused_before_any_change(self) -> None:
        for udid, api in ((IPAD, FakeAppStoreConnect(registered=False)), ("../profiles", FakeAppStoreConnect())):
            with self.assertRaises(profiles.ProfileError):
                profiles.add_device(udid, api)
            self.assertFalse([call for call in api.calls if call[0] in {"POST", "DELETE"}])


if __name__ == "__main__":
    unittest.main()
