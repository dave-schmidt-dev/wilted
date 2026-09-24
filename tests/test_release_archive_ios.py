import hashlib
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from app import release_archive_ios as archive


def canonical_bytes(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


class ReleaseArchiveCandidateTests(unittest.TestCase):
    def write_manifest(self, root: Path, candidate_id: str = "0.1.2-1") -> Path:
        path = root / "release-state/wilted-ios/candidates" / candidate_id / "manifest.json"
        path.parent.mkdir(parents=True)
        value = {
            "formatVersion": 2, "immutable": True, "productIdentifier": "wilted-ios",
            "candidateId": candidate_id,
            "sourceSnapshot": {"sha256": "a" * 64, "policyVersion": archive.SNAPSHOT_POLICY_VERSION},
            "adapter": {"sha256": "b" * 64},
            "artifactAttestation": {"candidateId": candidate_id, "sourceDigest": "a" * 64},
            "release": {"marketingVersion": "0.1.2", "buildNumber": "1", "frozen": True},
        }
        value["manifestSha256"] = hashlib.sha256(canonical_bytes(value)).hexdigest()
        path.write_bytes(canonical_bytes(value) + b"\n")
        return path

    def test_supplied_readiness_manifest_binds_common_dir_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.write_manifest(root)
            with patch.object(archive, "git_common_candidates_dir", return_value=manifest.parent.parent), \
                    patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}):
                self.assertEqual(archive.candidate(), ("0.1.2-1", "a" * 64, "1"))

    def test_manifest_rejects_other_common_dir_and_tampered_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.write_manifest(root)
            (root / "other").mkdir()
            with (patch.object(archive, "git_common_candidates_dir", return_value=root / "other"),
                  self.assertRaisesRegex(ValueError, "candidate-manifest-path-mismatch")):
                archive._candidate_from_manifest(manifest)
            value = json.loads(manifest.read_text())
            value["candidateId"] = "0.1.2-2"
            manifest.write_bytes(canonical_bytes(value) + b"\n")
            with (patch.object(archive, "git_common_candidates_dir", return_value=manifest.parent.parent),
                  self.assertRaises(ValueError)):
                archive._candidate_from_manifest(manifest)

    def test_manifest_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = self.write_manifest(root)
            link = root / "manifest.json"
            link.symlink_to(original)
            with self.assertRaisesRegex(ValueError, "candidate-manifest-symlink"):
                archive._candidate_from_manifest(link)


class FrozenSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "live"
        self.root.mkdir()
        (self.root / "project.yml").write_text("name: Wilted\n")
        (self.root / "app").mkdir()
        (self.root / "app/code.py").write_text("ready\n")
        (self.root / "app/tool.sh").write_text("#!/bin/sh\n")
        (self.root / "app/tool.sh").chmod(0o755)
        self.adapter = SimpleNamespace(source_paths=(), non_source_paths=())
        self.frozen = archive.Candidate(
            "0.1.2-1", archive.create_source_digest(self.root).source_digest, "0.1.2", "1",
            self.root / "manifest.json",
        )

    def test_live_drift_refuses_before_copy_or_existing_artifact_mutation(self) -> None:
        existing = self.root / ".release-state/artifacts/0.1.2-1/old.txt"
        existing.parent.mkdir(parents=True)
        existing.write_text("keep")
        (self.root / "app/code.py").write_text("changed\n")
        destination = Path(self.temporary.name) / "stage"
        with (patch.object(archive, "ROOT", self.root),
              self.assertRaisesRegex(ValueError, "candidate-source-drift")):
            archive.materialize_source(destination, self.frozen, self.adapter)
        self.assertFalse(destination.exists())
        self.assertEqual(existing.read_text(), "keep")

    def test_copy_time_mutation_is_rejected(self) -> None:
        destination = Path(self.temporary.name) / "stage"
        actual = archive.shutil.copyfile

        def changed_copy(source, target, **kwargs):
            if str(source).endswith("code.py"):
                Path(source).write_text("mutated\n")
            return actual(source, target, **kwargs)

        with (patch.object(archive, "ROOT", self.root),
              patch.object(archive.shutil, "copyfile", side_effect=changed_copy),
              self.assertRaisesRegex(ValueError, "candidate-source-drift-during-copy")):
            archive.materialize_source(destination, self.frozen, self.adapter)

    def test_stage_preserves_executable_and_internal_symlink_then_detects_tampering(self) -> None:
        (self.root / "app/alias").symlink_to("code.py")
        self.frozen = archive.Candidate(
            "0.1.2-1", archive.create_source_digest(self.root).source_digest, "0.1.2", "1",
            self.root / "manifest.json",
        )
        destination = Path(self.temporary.name) / "stage"
        with patch.object(archive, "ROOT", self.root):
            archive.materialize_source(destination, self.frozen, self.adapter)
        self.assertTrue((destination / "app/alias").is_symlink())
        self.assertTrue((destination / "app/tool.sh").stat().st_mode & stat.S_IXUSR)
        self.assertFalse((destination / "app/code.py").stat().st_mode & stat.S_IWUSR)
        (destination / "app/code.py").chmod(0o644)
        (destination / "app/code.py").write_text("tampered\n")
        self.assertNotEqual(archive.source_digest(destination, self.adapter), self.frozen.source_digest)
        (destination / "app").chmod(0o700)
        destination.chmod(0o700)

    def test_source_symlink_escape_is_rejected(self) -> None:
        (self.root / "app/escape").symlink_to(Path(self.temporary.name) / "outside")
        with (patch.object(archive, "ROOT", self.root), self.assertRaises(archive.SnapshotError)):
            archive.materialize_source(Path(self.temporary.name) / "stage", self.frozen, self.adapter)

    def test_build_uses_stage_and_fresh_outputs_outside_source(self) -> None:
        workspace = Path(self.temporary.name) / "workspace"
        workspace.mkdir()
        stage = workspace / "source"
        stage.mkdir()
        (stage / "project.yml").write_text("name: Wilted\n")
        for relative in (
            "WiltedMac/Info.plist", "WiltedMac/WiltedMac.entitlements",
            "WiltedMac/WiltedMacProduction.entitlements", "WiltediOS/Info.plist",
            "WiltediOS/WiltediOS.entitlements", "WiltediOS/WiltediOSProduction.entitlements",
        ):
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
        calls = []

        def fake_run(args, *, cwd):
            calls.append((args, cwd))
            if args[0] == "xcodegen":
                (workspace / "project/Wilted.xcodeproj").mkdir()
            else:
                (workspace / "DerivedData").mkdir()
                (workspace / "artifacts/WiltediOS.xcarchive").mkdir()

        with patch.object(archive, "run_visible", side_effect=fake_run):
            result = archive.build_archive(stage, workspace, self.frozen)
        self.assertEqual(result, workspace / "artifacts/WiltediOS.xcarchive")
        self.assertEqual(calls[0][0][-2:], ["--project-root", str(stage)])
        self.assertEqual(calls[0][1], workspace)
        self.assertEqual((workspace / "project/WiltediOS/WiltediOSProduction.entitlements").read_bytes(), b"fixture")
        self.assertEqual(calls[1][0][calls[1][0].index("-derivedDataPath") + 1], str(workspace / "DerivedData"))
        self.assertNotEqual(calls[1][1], self.root)

    def test_failed_build_preserves_existing_candidate_artifacts_and_evidence(self) -> None:
        (self.root / ".release-state/artifacts/0.1.2-1").mkdir(parents=True)
        (self.root / ".release-state/evidence/0.1.2-1").mkdir(parents=True)
        old_artifact = self.root / ".release-state/artifacts/0.1.2-1/old.txt"
        old_proof = self.root / ".release-state/evidence/0.1.2-1/old.json"
        old_artifact.write_text("old artifact")
        old_proof.write_text("old proof")
        with patch.object(archive, "ROOT", self.root), \
                patch.object(archive, "candidate_data", return_value=self.frozen), \
                patch.object(archive, "source_adapter", return_value=self.adapter), \
                patch.object(archive, "build_archive", side_effect=subprocess.CalledProcessError(1, "xcodebuild")), \
                patch.object(sys, "argv", ["release_archive_ios.py", "--prepare-only"]):
            self.assertEqual(archive.main(), 4)
        self.assertEqual(old_artifact.read_text(), "old artifact")
        self.assertEqual(old_proof.read_text(), "old proof")

    def test_stage_tampering_during_build_refuses_before_inspection_or_publication(self) -> None:
        existing = self.root / ".release-state/artifacts/0.1.2-1/old.txt"
        existing.parent.mkdir(parents=True)
        existing.write_text("keep")

        def tampering_build(staged, workspace, frozen):
            path = staged / "app/code.py"
            path.chmod(0o644)
            path.write_text("changed during build\n")
            return workspace / "artifacts/WiltediOS.xcarchive"

        with patch.object(archive, "ROOT", self.root), \
                patch.object(archive, "candidate_data", return_value=self.frozen), \
                patch.object(archive, "source_adapter", return_value=self.adapter), \
                patch.object(archive, "build_archive", side_effect=tampering_build), \
                patch.object(archive, "inspect_artifact") as inspect, \
                patch.object(sys, "argv", ["release_archive_ios.py", "--prepare-only"]):
            self.assertEqual(archive.main(), 4)
        inspect.assert_not_called()
        self.assertEqual(existing.read_text(), "keep")

    def test_incompatible_proof_contract_refuses_without_publishing(self) -> None:
        existing = self.root / ".release-state/evidence/0.1.2-1/old.json"
        existing.parent.mkdir(parents=True)
        existing.write_text("keep")
        measured = {"archiveSha256": "b" * 64, "metadataSha256": "c" * 64,
                    "embeddedProfileSha256": "d" * 64,
                    "signingCertificateSha256": "e" * 64,
                    "cloudKitEnvironment": "Production"}
        with patch.object(archive, "ROOT", self.root), \
                patch.object(archive, "candidate_data", return_value=self.frozen), \
                patch.object(archive, "source_adapter", return_value=self.adapter), \
                patch.object(archive, "build_archive", return_value=self.root / "unused.xcarchive"), \
                patch.object(archive, "inspect_artifact", return_value=measured), \
                patch.object(archive, "verify_artifact_evidence", side_effect=ValueError("proof-shape-invalid")), \
                patch.object(archive, "publish") as publish, \
                patch.object(sys, "argv", ["release_archive_ios.py", "--prepare-only"]):
            self.assertEqual(archive.main(), 4)
        publish.assert_not_called()
        self.assertEqual(existing.read_text(), "keep")


class ArtifactInspectionTests(unittest.TestCase):
    def test_package_ipa_uses_payload_root_without_metadata_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "WiltediOS.app"
            app.mkdir()
            (app / "Info.plist").write_text("plist")
            ipa = root / "WiltediOS.ipa"
            archive.package_ipa(app, ipa)
            with zipfile.ZipFile(ipa) as packaged:
                self.assertEqual(packaged.namelist(), [
                    "Payload/", "Payload/WiltediOS.app/", "Payload/WiltediOS.app/Info.plist",
                ])

    def test_inspection_measures_signed_entitlements_metadata_and_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "WiltediOS.xcarchive/Products/Applications/WiltediOS.app"
            app.mkdir(parents=True)
            (app / "embedded.mobileprovision").write_bytes(b"profile")
            (app / "WiltediOS").write_bytes(b"executable")
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": archive.BUNDLE_ID,
                "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "1",
                "CFBundleExecutable": "WiltediOS",
            }))
            entitlements = {
                "com.apple.developer.icloud-container-environment": "Production",
                "application-identifier": f"{archive.TEAM_ID}.{archive.BUNDLE_ID}",
                "com.apple.developer.team-identifier": archive.TEAM_ID,
            }
            profile = {
                "Entitlements": {**entitlements, "get-task-allow": False},
                "DeveloperCertificates": [b"leaf"],
            }
            frozen = archive.Candidate("0.1.2-1", "a" * 64, "0.1.2", "1", root / "manifest.json")
            ipa = root / "WiltediOS.ipa"

            def fake_command(*args):
                if "--entitlements" in args:
                    return plistlib.dumps(entitlements)
                if "cms" in args:
                    return plistlib.dumps(profile)
                if "--extract-certificates" in args:
                    Path(args[-2] + "0").write_bytes(b"leaf")
                    return b""
                raise AssertionError(args)

            original = subprocess.run
            with patch.object(archive, "command", side_effect=fake_command), \
                    patch.object(archive.subprocess, "run") as verify:
                # Keep the real packaging call; fake only strict signature verify.
                def fake_verify(args, **kwargs):
                    if args[0] == "codesign":
                        return SimpleNamespace(returncode=0)
                    return original(args, **kwargs)

                verify.side_effect = fake_verify
                measured = archive.inspect_artifact(root / "WiltediOS.xcarchive", ipa, frozen, root)
            self.assertEqual(measured["cloudKitEnvironment"], "Production")
            self.assertEqual(measured["archiveSha256"], archive.digest(ipa))
            self.assertEqual(measured["signingCertificateSha256"], hashlib.sha256(b"leaf").hexdigest())
            self.assertTrue(any("--strict" in call.args[0] for call in verify.call_args_list))

    def test_proofs_use_measured_inspection_without_upload_claim(self) -> None:
        frozen = archive.Candidate("0.1.2-1", "a" * 64, "0.1.2", "1", Path("manifest.json"))
        measured = {"archiveSha256": "b" * 64, "metadataSha256": "c" * 64,
                    "embeddedProfileSha256": "d" * 64,
                    "signingCertificateSha256": "e" * 64,
                    "cloudKitEnvironment": "Production"}
        proofs = archive.build_proofs(frozen, measured)
        artifact = proofs["artifact.json"]
        self.assertEqual(artifact["archiveSha256"], "b" * 64)
        self.assertEqual(artifact["cloudKitEnvironment"], "Production")
        self.assertEqual(artifact["localInspectionResult"], "passed")
        self.assertNotIn("uploadValidationResult", artifact)
        self.assertEqual(proofs["production-build.json"]["cleanBuild"], True)


if __name__ == "__main__":
    unittest.main()
