import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from app import release_archive_ios


class ReleaseArchiveCandidateTests(unittest.TestCase):
    def write_manifest(self, root: Path, candidate_id: str = "0.1.2-1") -> Path:
        path = root / "release-state" / "wilted-ios" / "candidates" / candidate_id / "manifest.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "formatVersion": 2,
                    "immutable": True,
                    "productIdentifier": "wilted-ios",
                    "candidateId": candidate_id,
                    "sourceSnapshot": {"sha256": "a" * 64},
                    "release": {"buildNumber": "1", "frozen": True},
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_supplied_readiness_manifest_binds_candidate_without_git_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = self.write_manifest(Path(temporary))
            with patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}):
                self.assertEqual(
                    release_archive_ios.candidate(),
                    ("0.1.2-1", "a" * 64, "1"),
                )

    def test_package_ipa_uses_payload_root_without_metadata_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "WiltediOS.app"
            app.mkdir()
            (app / "Info.plist").write_text("plist", encoding="utf-8")
            ipa = root / "WiltediOS.ipa"
            release_archive_ios.package_ipa(app, ipa)
            with zipfile.ZipFile(ipa) as archive:
                self.assertEqual(
                    archive.namelist(),
                    ["Payload/", "Payload/WiltediOS.app/", "Payload/WiltediOS.app/Info.plist"],
                )

    def test_supplied_readiness_manifest_rejects_candidate_path_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = self.write_manifest(Path(temporary))
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["candidateId"] = "0.1.2-2"
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}):
                with self.assertRaises(ValueError):
                    release_archive_ios.candidate()


if __name__ == "__main__":
    unittest.main()
