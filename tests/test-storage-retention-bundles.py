#!/usr/bin/env python3
"""Fixture coverage for compact Apple evidence exports."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import tarfile
import unittest
import zipfile
import io
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from retention import bundles, caches, evidence
from retention.core import snapshot_tree


class BundleExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="wilted-retention-bundles-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.xcresult"
        self.source.mkdir()
        (self.source / "Data").mkdir()
        (self.source / "Data" / "raw.bin").write_bytes(b"fixture result source")
        self.output_root = self.root / "exports"
        self.output_root.mkdir()

    def run_export(self, mode: str, *, status: str = "Passed",
                   attachment_status: int = 0, mutate: bool = False):
        calls: list[tuple[str, ...]] = []

        def fake(command, deadline):
            del deadline
            command = tuple(command)
            calls.append(command)
            if command[:4] == ("xcrun", "xcresulttool", "get", "test-results"):
                selected = command[4]
                payload = ({"result": status, "passedTests": 1, "testFailures": []}
                           if selected == "summary" else
                           {"testNodes": [{"name": "Fixture.testAll", "result": status}]})
                if selected == "tests" and mutate:
                    (self.source / "Data" / "raw.bin").write_bytes(b"changed while exporting")
                return subprocess.CompletedProcess(command, 0, json.dumps(payload).encode(), b"")
            if command[:4] == ("xcrun", "xcresulttool", "export", "attachments"):
                target = Path(command[command.index("--output-path") + 1])
                nested = target / "failure" / "nested"
                nested.mkdir(parents=True)
                (nested / "trace.bin").write_bytes(b"\x00\xfftrace")
                (nested / "note.txt").write_text("full attachment")
                return subprocess.CompletedProcess(command, attachment_status, b"", b"")
            if command[:3] == ("/usr/bin/log", "show", "--archive"):
                return subprocess.CompletedProcess(command, 0, b'{"process":"Wilted"}\n', b"")
            return subprocess.CompletedProcess(command, 127, b"", b"unknown fixture command")

        destination = self.output_root / (mode + "-export")
        with patch.object(bundles, "_run", side_effect=fake):
            result = bundles.export_bundle(self.source, destination)
        return result, calls, destination

    def test_passed_xcresult_exports_summary_and_complete_tests(self) -> None:
        result, calls, destination = self.run_export("passed")
        self.assertEqual(result["status"], "compacted")
        self.assertEqual(result["result"], "Passed")
        self.assertEqual({row["path"] for row in result["outputs"]},
                         {"test-results-summary.json", "test-results-tests.json"})
        self.assertFalse(any("attachments" in call for call in calls))
        self.assertEqual(result["source_fingerprint"], snapshot_tree(self.source).digest)
        self.assertEqual(json.loads((destination / "test-results-summary.json").read_text())["result"], "Passed")

    def test_failed_xcresult_keeps_binary_and_text_failure_attachments(self) -> None:
        result, calls, destination = self.run_export("failed", status="Failed")
        self.assertEqual(result["status"], "compacted")
        self.assertEqual(result["result"], "Failed")
        self.assertTrue(any("--only-failures" in call for call in calls))
        attachment_paths = {row["path"] for row in result["outputs"]
                            if row["path"].startswith("failure-attachments/")}
        self.assertIn("failure-attachments/failure/nested/trace.bin", attachment_paths)
        self.assertIn("failure-attachments/failure/nested/note.txt", attachment_paths)
        self.assertEqual((destination / "failure-attachments/failure/nested/trace.bin").read_bytes(),
                         b"\x00\xfftrace")

    def test_unknown_result_remains_raw(self) -> None:
        result, calls, destination = self.run_export("unknown", status="Inconclusive")
        self.assertEqual(result["status"], "retained")
        self.assertEqual(result["reason"], "xcresult-status-unknown")
        self.assertFalse(destination.exists())
        self.assertTrue((self.source / "Data" / "raw.bin").exists())
        self.assertFalse(any("attachments" in call for call in calls))

    def test_failed_attachment_export_remains_raw(self) -> None:
        result, _, destination = self.run_export("attachment-error", status="Failed",
                                                  attachment_status=1)
        self.assertEqual(result["status"], "retained")
        self.assertEqual(result["reason"], "xcresult-failure-attachments-failed")
        self.assertFalse(destination.exists())
        self.assertEqual((self.source / "Data" / "raw.bin").read_bytes(), b"fixture result source")

    def test_source_change_during_export_is_rejected(self) -> None:
        result, _, destination = self.run_export("changed", mutate=True)
        self.assertEqual(result["reason"], "source-changed-during-export")
        self.assertEqual(result["status"], "retained")
        self.assertFalse(destination.exists())

    def test_logarchive_exports_only_filtered_wilted_records(self) -> None:
        source = self.root / "system.logarchive"
        source.mkdir()
        (source / "Persist").write_bytes(b"raw system log")
        destination = self.output_root / "system-export"
        command_seen: list[tuple[str, ...]] = []
        def fake(command, deadline):
            del deadline
            command_seen.append(tuple(command))
            return subprocess.CompletedProcess(command, 0, b'{"process":"Wilted"}\n', b"")
        with patch.object(bundles, "_run", side_effect=fake):
            result = bundles.export_bundle(source, destination)
        self.assertEqual(result["status"], "compacted")
        self.assertEqual({row["path"] for row in result["outputs"]}, {"wilted-filtered.ndjson"})
        self.assertIn("--archive", command_seen[0])
        self.assertIn(b"process CONTAINS[c]", command_seen[0][-1].encode())
        self.assertFalse((destination / "Persist").exists())
        self.assertTrue((source / "Persist").exists())

    def test_logarchive_failure_retains_raw_archive(self) -> None:
        source = self.root / "failed.logarchive"
        source.mkdir()
        (source / "Persist").write_bytes(b"raw system log")
        destination = self.output_root / "failed-export"
        with patch.object(bundles, "_run", return_value=subprocess.CompletedProcess(
                ("/usr/bin/log",), 1, b"", b"filter denied")):
            result = bundles.export_bundle(source, destination)
        self.assertEqual(result["reason"], "logarchive-filtered-export-failed")
        self.assertEqual((source / "Persist").read_bytes(), b"raw system log")
        self.assertFalse(destination.exists())

    def test_source_zip_members_deduplicate_and_restore_with_names(self) -> None:
        source = self.root / "source.zip"
        with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("nested/first.txt", "same bytes")
            archive.writestr("nested/second.txt", "same bytes")
            archive.writestr("empty/", b"")
        destination = self.output_root / "zip-export"
        result = bundles.export_bundle(source, destination)
        self.assertEqual(result["status"], "compacted")
        manifest = json.loads((destination / "source-snapshot.json").read_text())
        self.assertEqual(len([row for row in manifest["members"] if row["kind"] == "file"]), 2)
        content = list((destination / "content").iterdir())
        self.assertEqual(len(content), 1)
        restored = self.root / "restored"
        bundles.restore_snapshot(destination, restored)
        self.assertEqual((restored / "nested" / "first.txt").read_text(), "same bytes")
        self.assertEqual((restored / "nested" / "second.txt").read_text(), "same bytes")
        self.assertTrue((restored / "empty").is_dir())

    def test_nested_env_member_refuses_source_archive_compaction(self) -> None:
        source = self.root / "secrets.zip"
        with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("nested/.env", "fixture only; no credential")
            archive.writestr("nested/.env.example", "safe example")
        destination = self.output_root / "secrets-export"
        result = bundles.export_bundle(source, destination)
        self.assertEqual(result["status"], "retained")
        self.assertEqual(result["reason"], "archive-secret-bearing-member-name")
        self.assertFalse(destination.exists())
        self.assertEqual(zipfile.ZipFile(source).read("nested/.env"),
                         b"fixture only; no credential")

    def test_tar_regular_members_roundtrip_and_unsafe_link_refusal(self) -> None:
        source = self.root / "source.tar"
        with tarfile.open(source, "w") as archive:
            data = b"full member"
            info = tarfile.TarInfo("tree/record.bin")
            info.size = len(data)
            info.mode = 0o640
            archive.addfile(info, io.BytesIO(data))
        destination = self.output_root / "tar-export"
        result = bundles.export_bundle(source, destination)
        self.assertEqual(result["status"], "compacted")
        restored = self.root / "tar-restored"
        bundles.restore_snapshot(destination, restored)
        self.assertEqual((restored / "tree" / "record.bin").read_bytes(), b"full member")
        self.assertEqual((restored / "tree" / "record.bin").stat().st_mode & 0o777, 0o640)

        unsafe = self.root / "unsafe.tar"
        with tarfile.open(unsafe, "w") as archive:
            link = tarfile.TarInfo("tree/outside")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../outside"
            archive.addfile(link)
        unsafe_dest = self.output_root / "unsafe-export"
        refused = bundles.export_bundle(unsafe, unsafe_dest)
        self.assertEqual(refused["status"], "retained")
        self.assertEqual(refused["reason"], "archive-link-or-special-member")
        self.assertFalse(unsafe_dest.exists())
        self.assertTrue(unsafe.exists())

    def test_repeated_busy_source_does_not_accumulate_recovery_packs(self) -> None:
        repo = (self.root / "retention-repo").resolve()
        logs = repo / ".logs"
        logs.mkdir(parents=True)
        source = logs / "old-result.json"
        source.write_text('{"result":"ok"}\n')
        old = 1_700_000_000
        os.utime(source, (old, old))
        archive = logs / "retained-evidence" / "weekly"
        with patch.object(evidence, "_open_reference",
                          side_effect=[(False, ""), (True, "busy"),
                                       (False, ""), (True, "busy")]):
            first = evidence.compact(repo, archive, now=old + evidence.QUIET_SECONDS + 1,
                                     apply=True)
            second = evidence.compact(repo, archive, now=old + evidence.QUIET_SECONDS + 1,
                                      apply=True)
        self.assertEqual(first["status"], "kept")
        self.assertEqual(second["status"], "kept")
        self.assertTrue(source.exists())
        self.assertEqual(first["archives"], [])
        self.assertEqual(second["archives"], [])
        self.assertEqual([path for path in archive.rglob("*") if path.is_file()], [])

    def test_partial_shared_cache_removal_reports_actual_remaining_bytes(self) -> None:
        repo = (self.root / "cache-repo").resolve()
        build = repo / ".build"
        xcode = build / "xcode"
        first = xcode / "a-installer"
        second = xcode / "b-installer"
        (first / "payload").mkdir(parents=True)
        (second / "payload").mkdir(parents=True)
        first_file = first / "payload" / "cache.bin"
        second_file = second / "payload" / "cache.bin"
        first_file.write_bytes(b"a" * 16384)
        second_file.write_bytes(b"b" * 32768)
        first_bytes = caches._size(first)
        second_bytes = caches._size(second)
        call_count = 0
        actual_remove = caches._remove_member

        def remove_one_then_fail(repo_root, member, expected, unit_root):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return actual_remove(repo_root, member, expected, unit_root)
            raise OSError("fixture failure after first member was removed")

        def acquire(build_root):
            lock = build_root / "full-run.lock"
            lock.mkdir()
            info = lock.lstat()
            return lock, (info.st_dev, info.st_ino), "fixture"

        def release(lock, _identity, _started):
            lock.rmdir()

        with patch.object(caches, "_live_build_process", return_value=(False, "")), \
                patch.object(caches, "_cache_idle", return_value=(True, "")), \
                patch.object(caches, "_remove_member", side_effect=remove_one_then_fail), \
                patch.object(caches, "_acquire_full_run", side_effect=acquire), \
                patch.object(caches, "_release_full_run", side_effect=release):
            result = caches.evict(repo, budget=0, now=1_800_000_000,
                                  apply=True, min_age=0)

        unit = next(row for row in result["units"] if row["kind"] == "xcode-installer")
        self.assertEqual(unit["status"], "partially-removed")
        self.assertEqual(unit["removed_members"], [str(first)])
        self.assertEqual(unit["removed_bytes"], first_bytes)
        self.assertEqual(unit["remaining_bytes"], second_bytes)
        self.assertEqual(result["remaining_bytes"], second_bytes)
        self.assertFalse(first.exists())
        self.assertTrue(second_file.exists())

    def test_destination_collision_does_not_overwrite(self) -> None:
        destination = self.output_root / "existing"
        destination.mkdir()
        (destination / "sentinel").write_text("keep")
        result = bundles.export_bundle(self.source, destination)
        self.assertEqual(result["reason"], "destination-exists")
        self.assertEqual((destination / "sentinel").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
