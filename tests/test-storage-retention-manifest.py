#!/usr/bin/env python3
"""Fixture tests for one-time retention cleanup and historical recovery."""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from retention import apply_manifest as executor
from retention import manifest_recovery as recovery
from retention.core import snapshot_tree


def _git_blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


class ManifestFixtures(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wilted-retention-manifest-")
        self.root = Path(self.temporary.name).resolve()
        self.logs = self.root / ".logs"
        self.logs.mkdir()
        (self.root / "scripts").mkdir()
        self.target_dir = self.logs / "old"
        self.target_dir.mkdir()
        self.manifest_path = self.logs / "retention-implementation" / "cleanup-inputs.json"
        self.manifest_path.parent.mkdir()
        self.audit_dir = self.logs / "retention-audit-2026-11-04"
        self.other_dir = self.logs / "retention-other-2026-11-04"
        self.audit_dir.mkdir()
        self.other_dir.mkdir()
        self.pack_path = self.logs / "retention-other" / "evidence.zip"
        self.pack_path.parent.mkdir()
        executor._ZIP_CACHE.clear()
        self.original_batch = executor._batch_open_files
        self.original_direct_probe = executor._open_reference
        executor._batch_open_files = lambda _root: (set(), time.monotonic())
        executor._open_reference = lambda _path: (False, "")

    def tearDown(self) -> None:
        executor._batch_open_files = self.original_batch
        executor._open_reference = self.original_direct_probe
        executor._ZIP_CACHE.clear()
        self.temporary.cleanup()

    def _pack(self, data: bytes) -> tuple[str, str]:
        digest = hashlib.sha256(data).hexdigest()
        with zipfile.ZipFile(self.pack_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(digest, data)
        return digest, digest

    def _row(self, target: Path, data: bytes, *, decision: str = "replace",
             retained: dict[str, object] | None = None) -> dict[str, object]:
        target.write_bytes(data)
        relative = target.relative_to(self.root).as_posix()
        current = snapshot_tree(target, root=self.logs)
        return {
            "scope": "repo-logs", "path": relative, "decision": decision,
            "status": "ready", "source_sha256": hashlib.sha256(data).hexdigest(),
            "source_bytes": len(data),
            "fingerprint": {"digest": current.digest, "bytes": current.bytes,
                            "entries": len(current.entries), "device": current.device,
                            "inode": current.inode, "mode": current.mode,
                            "mtime_ns": current.mtime_ns, "ctime_ns": current.ctime_ns},
            "replacement": retained or {"kind": "zip-member",
                "pack": self.pack_path.relative_to(self.root).as_posix(),
                "member": hashlib.sha256(data).hexdigest(),
                "sha256": hashlib.sha256(data).hexdigest()},
        }

    def _manifest(self, *rows: dict[str, object], audit_action: str | None = None,
                  audit_sha: str | None = None, audit_path: str | None = None,
                  audit_reason: str = "fixture", audit_retained_at: str | None = None,
                  audit_git_blob: str | None = None, audit_in_git: bool | None = None) -> None:
        items = [dict(row) for row in rows]
        audit_rows: list[dict[str, object]] = []
        other_rows: list[dict[str, object]] = []
        for item in items:
            if item.get("scope") != "repo-logs":
                continue
            original_action = audit_action or str(item["decision"])
            original_sha = audit_sha or item.get("source_sha256")
            original = {"path": audit_path or item["path"], "action": original_action,
                        "sha256": original_sha, "size": item.get("source_bytes"),
                        "reason": audit_reason}
            if audit_retained_at is not None:
                original["retained_at"] = audit_retained_at
            if audit_git_blob is not None:
                original["git_blob"] = audit_git_blob
            if audit_in_git is not None:
                original["in_git"] = audit_in_git
            item["origin"] = ".logs/retention-audit-2026-11-04/file-decisions.json"
            item["row"] = len(audit_rows)
            audit_rows.append(original)
        files = {
            ".logs/retention-audit-2026-11-04/file-decisions.json": audit_rows,
            ".logs/retention-other-2026-11-04/decisions.json": other_rows,
            ".logs/retention-audit-2026-11-04/archive-reconstruction-map.json": [],
            ".logs/retention-other-2026-11-04/archive-reconstruction-map.json": [],
            ".logs/retention-other-2026-11-04/test-results.json": [],
            ".logs/retention-other-2026-11-04/system-results.json": [],
        }
        bindings = {}
        for relative, value in files.items():
            target = self.root / relative
            target.write_text(json.dumps(value), encoding="utf-8")
            bindings[relative] = hashlib.sha256(target.read_bytes()).hexdigest()
        self.manifest_path.write_text(json.dumps({
            "schema_version": 2, "workspace": str(self.root),
            "source_manifests": bindings, "items": items
        }), encoding="utf-8")

    def test_manifest_hashes_the_same_bytes_it_parses(self) -> None:
        source = b"bound source\n"
        self._pack(source)
        target = self.target_dir / "bound.log"
        row = self._row(target, source)
        self._manifest(row)
        with mock.patch.object(executor, "_file_sha256", side_effect=AssertionError("second read")):
            loaded = executor.load_manifest(self.manifest_path, self.root)
        self.assertEqual(len(loaded["items"]), 1)

    def test_apply_hashes_the_single_manifest_read(self) -> None:
        source = b"single manifest read\n"
        self._pack(source)
        target = self.target_dir / "single-read.log"
        row = self._row(target, source)
        self._manifest(row)
        original_read = Path.read_bytes
        manifest_reads = 0

        def counted_read(path: Path) -> bytes:
            nonlocal manifest_reads
            if path == self.manifest_path:
                manifest_reads += 1
            return original_read(path)

        with mock.patch.object(Path, "read_bytes", new=counted_read):
            result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(result["items"][0]["status"], "would-remove")
        self.assertEqual(manifest_reads, 1)

    def test_default_is_dry_run_and_apply_removes_exact_replaced_file(self) -> None:
        source = b"old evidence\n"
        self._pack(source)
        target = self.target_dir / "item.log"
        row = self._row(target, source)
        self._manifest(row)

        planned = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(planned["mode"], "dry-run")
        self.assertEqual(planned["items"][0]["status"], "would-remove")
        self.assertTrue(target.exists())

        applied = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(applied["items"][0]["status"], "removed")
        self.assertFalse(target.exists())

    def test_non_git_replacement_does_not_read_git_recovery_pack(self) -> None:
        source = b"ordinary non-Git evidence\n"
        self._pack(source)
        target = self.target_dir / "non-git.log"
        row = self._row(target, source)
        git_pack = self.logs / "retention-implementation-2026-11-04" / "recovery-git-blobs.zip"
        git_pack.parent.mkdir(parents=True, exist_ok=True)
        git_pack.write_bytes(b"not a Git pack")
        self._manifest(row)
        result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(result["items"][0]["status"], "would-remove")
        self.assertTrue(target.exists())

    def test_global_lsof_filters_logs_and_accepts_only_classified_warning(self) -> None:
        executor._batch_open_files = self.original_batch
        target = self.target_dir / "open.log"
        target.write_bytes(b"open evidence")
        outside = b"/private/etc/hosts"
        warning = b"exact external mount warning"
        output = b"p123\0\nfcwd\0n" + os.fsencode(target) + b"\0n" + outside + b"\0\n\0"
        completed = executor.subprocess.CompletedProcess(
            args=("lsof",), returncode=1, stdout=output, stderr=warning)
        with mock.patch.object(executor.shutil, "which", return_value="/usr/sbin/lsof"), \
             mock.patch.object(executor.subprocess, "run", return_value=completed), \
             mock.patch.object(executor, "lsof_only_external_smbfs_warning", return_value=True) as classify:
            opened, _ = executor._batch_open_files(self.logs)
        self.assertEqual(opened, {target})
        classify.assert_called_once_with(warning, self.logs)

    def test_global_lsof_unknown_warning_and_malformed_output_fail_closed(self) -> None:
        executor._batch_open_files = self.original_batch
        target = self.target_dir / "maybe-open.log"
        target.write_bytes(b"evidence")
        output = b"p123\0n" + os.fsencode(target) + b"\0"
        unknown = executor.subprocess.CompletedProcess(
            args=("lsof",), returncode=1, stdout=output, stderr=b"other warning")
        with mock.patch.object(executor.shutil, "which", return_value="/usr/sbin/lsof"), \
             mock.patch.object(executor.subprocess, "run", return_value=unknown), \
             mock.patch.object(executor, "lsof_only_external_smbfs_warning", return_value=False):
            with self.assertRaisesRegex(executor.ManifestError, "lsof-probe-error"):
                executor._batch_open_files(self.logs)

        malformed = executor.subprocess.CompletedProcess(
            args=("lsof",), returncode=1, stdout=b"p123\0bad\0", stderr=b"exact external mount warning")
        with mock.patch.object(executor.shutil, "which", return_value="/usr/sbin/lsof"), \
             mock.patch.object(executor.subprocess, "run", return_value=malformed), \
             mock.patch.object(executor, "lsof_only_external_smbfs_warning", return_value=True):
            with self.assertRaisesRegex(executor.ManifestError, "lsof-path-output-invalid"):
                executor._batch_open_files(self.logs)

    def test_changed_source_hash_is_skipped(self) -> None:
        source = b"old evidence\n"
        self._pack(source)
        target = self.target_dir / "changed.log"
        row = self._row(target, source)
        target.write_bytes(b"changed after preparation")
        self._manifest(row)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "target-changed-since-preparation")
        self.assertEqual(target.read_bytes(), b"changed after preparation")

    def test_bad_pack_and_missing_member_keep_source(self) -> None:
        source = b"evidence\n"
        self._pack(source)
        target = self.target_dir / "bad-pack.log"
        row = self._row(target, source)
        self.pack_path.write_bytes(b"not a zip")
        self._manifest(row)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "replacement-pack-invalid")
        self.assertTrue(target.exists())

    def test_valid_but_unrelated_replacement_cannot_authorize_source_removal(self) -> None:
        source = b"audited source A"
        unrelated = b"different but valid replacement B"
        target = self.target_dir / "unrelated-replacement.log"
        row = self._row(target, source)
        digest = hashlib.sha256(unrelated).hexdigest()
        with zipfile.ZipFile(self.pack_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(digest, unrelated)
        row["replacement"] = {"kind": "zip-member",
            "pack": self.pack_path.relative_to(self.root).as_posix(),
            "member": digest, "sha256": digest}
        self._manifest(row)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "replacement-does-not-match-source-bytes")
        self.assertEqual(target.read_bytes(), source)

    def test_valid_alternate_git_pack_is_rejected(self) -> None:
        source = b"audited Git source"
        target = self.target_dir / "canonical-pack.log"
        row = self._row(target, source, decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        oid = _git_blob_id(source)
        digest = hashlib.sha256(source).hexdigest()
        alternate = self.logs / "retention-other" / "alternate-git-pack.zip"
        with zipfile.ZipFile(alternate, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("blobs/" + digest, source)
            archive.writestr("index.json", json.dumps([{
                "git_blob": oid, "sha256": digest, "size": len(source), "sources": ["fixture"]
            }]))
        self.assertEqual(len(recovery.verify_git_pack(alternate)), 1)
        row["replacement"] = {"kind": "git-blob",
            "pack": alternate.relative_to(self.root).as_posix(),
            "git_blob": oid, "sha256": digest}
        self._manifest(row)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "git-recovery-pack-must-be-canonical-audit-pack")
        self.assertTrue(target.exists())

    def test_old_batch_liveness_snapshot_is_refreshed_before_delete(self) -> None:
        source = b"two ordinary files\n"
        self._pack(source)
        first = self._row(self.target_dir / "first.log", source)
        second = self._row(self.target_dir / "second.log", source)
        self._manifest(first, second)
        calls = 0

        def batch(_root: Path):
            nonlocal calls
            calls += 1
            observed = time.monotonic() - 10 if calls == 1 else time.monotonic()
            return set(), observed

        executor._batch_open_files = batch
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(calls, 2)
        self.assertEqual([row["status"] for row in result["items"]], ["removed", "removed"])

    def test_failed_global_liveness_probe_stops_without_per_item_retries(self) -> None:
        first = self._row(self.target_dir / "first.log", b"first")
        second = self._row(self.target_dir / "second.log", b"second")
        self._manifest(first, second)
        calls = 0

        def failed_probe(_root: Path):
            nonlocal calls
            calls += 1
            raise executor.ManifestError("lsof-probe-error")

        executor._batch_open_files = failed_probe
        result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertTrue(result["partial"])
        self.assertEqual(result["reason"], "lsof-probe-error")
        self.assertEqual(calls, 1)
        self.assertEqual(len(result["items"]), 1)
        self.assertTrue((self.target_dir / "first.log").exists())
        self.assertTrue((self.target_dir / "second.log").exists())

    def test_irreversible_removal_gets_final_open_file_probe(self) -> None:
        target = self.target_dir / "no-replacement.log"
        row = self._row(target, b"owner-approved remove\n", decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(row)
        calls = []
        executor._open_reference = lambda path: (calls.append(path) or (True, "open-file-reference"))
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "open-file-reference")
        self.assertEqual(calls, [target])
        self.assertTrue(target.exists())

    def test_symlink_and_escaping_paths_are_rejected(self) -> None:
        source = b"evidence\n"
        self._pack(source)
        target = self.target_dir / "linked.log"
        outside = self.root / "outside.log"
        outside.write_bytes(source)
        target.symlink_to(outside)
        candidate = {
            "scope": "repo-logs", "path": target.relative_to(self.root).as_posix(),
            "decision": "remove", "status": "ready", "source_sha256": hashlib.sha256(source).hexdigest(),
            "source_bytes": len(source), "fingerprint": {"digest": "x", "bytes": len(source)},
            "replacement": {"kind": "approved-removal", "owner_decision": "remove"},
        }
        self._manifest(candidate)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertNotEqual(result["items"][0]["status"], "removed")
        self.assertTrue(target.is_symlink())

        candidate["path"] = "../outside.log"
        self._manifest(candidate)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "manifest-path-outside-logs")
        self.assertEqual(outside.read_bytes(), source)

    def test_original_keep_decision_cannot_be_changed_to_remove(self) -> None:
        source = b"keep this\n"
        target = self.target_dir / "approved-keep.log"
        row = self._row(target, source, decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(row, audit_action="keep")
        with self.assertRaisesRegex(executor.ManifestError, "audit-decision-does-not-authorize-item"):
            executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertTrue(target.exists())

    def test_item_hash_must_match_original_audit_hash(self) -> None:
        source = b"audited bytes\n"
        target = self.target_dir / "wrong-hash.log"
        row = self._row(target, source)
        self._manifest(row, audit_sha="0" * 64)
        with self.assertRaisesRegex(executor.ManifestError, "source-hash-does-not-match-audit"):
            executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertTrue(target.exists())

    def test_item_path_must_match_an_original_manifest_path(self) -> None:
        source = b"audited bytes\n"
        target = self.target_dir / "unknown-path.log"
        row = self._row(target, source)
        row["path"] = ".logs/old/not-the-audited-file.log"
        self._manifest(row, audit_path=".logs/old/another-file.log")
        with self.assertRaisesRegex(executor.ManifestError, "audit-decision-does-not-authorize-item"):
            executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertTrue(target.exists())

    def test_original_audio_is_preserved_but_audited_test_video_is_allowed(self) -> None:
        audio = self.target_dir / "owner-feedback.m4a"
        audio_row = self._row(audio, b"original audio", decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(audio_row)
        with self.assertRaisesRegex(executor.ManifestError, "original-media-preserved"):
            executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertTrue(audio.exists())

        video = self.target_dir / "old-test-capture.mp4"
        video_row = self._row(video, b"old UI capture", decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(video_row, audit_reason=(
            "historical automated UI-test recording; no current issue reference identified; "
            "not original ad-feedback media"))
        result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(result["items"][0]["status"], "would-remove")
        self.assertTrue(video.exists())

    def test_only_audit_approved_png_copies_are_removable(self) -> None:
        duplicate_bytes = b"audited duplicate screenshot"
        duplicate = self.target_dir / "duplicate.png"
        canonical = self.target_dir / "canonical.png"
        canonical.write_bytes(duplicate_bytes)
        duplicate_row = self._row(duplicate, duplicate_bytes, decision="remove", retained={
            "kind": "file", "retained_path": canonical.relative_to(self.root).as_posix(),
            "sha256": hashlib.sha256(duplicate_bytes).hexdigest(),
        })
        self._manifest(duplicate_row,
            audit_reason="SHA-256 identical duplicate; retained canonical path recorded",
            audit_retained_at=canonical.relative_to(self.root).as_posix())
        result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(result["items"][0]["status"], "would-remove")
        self.assertTrue(duplicate.exists())

        duplicate_row["replacement"] = {"kind": "approved-removal", "owner_decision": "remove"}
        self._manifest(duplicate_row,
            audit_reason="SHA-256 identical duplicate; retained canonical path recorded",
            audit_retained_at=canonical.relative_to(self.root).as_posix())
        with self.assertRaisesRegex(executor.ManifestError, "original-media-preserved"):
            executor.load_manifest(self.manifest_path, self.root)

        tracked_bytes = b"audited Git-backed screenshot"
        tracked = self.target_dir / "tracked-copy.png"
        tracked_row = self._row(tracked, tracked_bytes, decision="remove")
        oid = _git_blob_id(tracked_bytes)
        digest = hashlib.sha256(tracked_bytes).hexdigest()
        git_pack = self.logs / "retention-implementation-2026-11-04" / "recovery-git-blobs.zip"
        git_pack.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(git_pack, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("blobs/" + digest, tracked_bytes)
            archive.writestr("index.json", json.dumps([{
                "git_blob": oid, "sha256": digest, "size": len(tracked_bytes), "sources": ["fixture"]
            }]))
        tracked_row["replacement"] = {
            "kind": "git-blob", "pack": git_pack.relative_to(self.root).as_posix(),
            "git_blob": oid, "sha256": digest,
        }
        self._manifest(tracked_row,
            audit_reason="exact file bytes verified in reachable Git objects",
            audit_retained_at=f"git blob {oid}", audit_git_blob=oid, audit_in_git=True)
        result = executor.apply_manifest(self.root, self.manifest_path)
        self.assertEqual(result["items"][0]["status"], "would-remove")
        self.assertTrue(tracked.exists())

    def test_unverified_or_unique_png_is_preserved(self) -> None:
        source = b"image source"
        target = self.target_dir / "unique.png"
        row = self._row(target, source, decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(row, audit_reason="unique image retained")
        with self.assertRaisesRegex(executor.ManifestError, "original-media-preserved"):
            executor.load_manifest(self.manifest_path, self.root)
        self.assertTrue(target.exists())

    def test_pinned_document_evidence_and_preserved_unknown_item_stay(self) -> None:
        source = b"evidence\n"
        self._pack(source)
        target = self.target_dir / "cited.log"
        row = self._row(target, source)
        (self.root / "README.md").write_text("Keep .logs/old/cited.log\n", encoding="utf-8")
        unknown = {"scope": "preserve", "path": ".logs/old/unknown.xcresult",
                   "decision": "keep", "status": "preserved",
                   "skip_reason": "unreadable-or-unknown-test-result"}
        self._manifest(row, unknown)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "pinned-or-reserved")
        self.assertEqual(result["items"][1]["status"], "skipped")
        self.assertTrue(target.exists())

    def test_retained_copy_cannot_also_be_scheduled_for_removal(self) -> None:
        first = self.target_dir / "duplicate-a.log"
        second = self.target_dir / "duplicate-b.log"
        content = b"identical copy\n"
        digest, member = self._pack(content)
        first_row = self._row(first, content, retained={
            "kind": "file", "retained_path": second.relative_to(self.root).as_posix(),
            "sha256": digest,
        })
        second_row = self._row(second, content, decision="remove", retained={
            "kind": "approved-removal", "owner_decision": "remove"})
        self._manifest(first_row, second_row)
        result = executor.apply_manifest(self.root, self.manifest_path, apply=True)
        self.assertEqual(result["items"][0]["reason"], "replacement-is-also-scheduled-for-removal")
        self.assertEqual(result["items"][1]["reason"], "referenced-by-another-cleanup-item")
        self.assertTrue(first.exists() and second.exists())

    def test_git_pack_extracts_one_original_file_without_overwrite(self) -> None:
        data = b"recovered git-backed source\n"
        oid = _git_blob_id(data)
        digest = hashlib.sha256(data).hexdigest()
        pack = self.root / "recovery-git-blobs.zip"
        with zipfile.ZipFile(pack, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("blobs/" + digest, data)
            archive.writestr("index.json", json.dumps([{
                "git_blob": oid, "sha256": digest, "size": len(data), "sources": ["old/path"]
            }]))
        self.assertEqual(len(recovery.verify_git_pack(pack)), 1)
        destination = self.root / "restored.txt"
        recovery.restore_git_blob(oid, destination, pack)
        self.assertEqual(destination.read_bytes(), data)
        with self.assertRaises(recovery.RecoveryError):
            recovery.restore_git_blob(oid, destination, pack)

    def test_archive_reconstruction_preserves_directories_and_member_modes(self) -> None:
        content = b"source file\n"
        digest = hashlib.sha256(content).hexdigest()
        audit = self.root / "audit"
        other = self.root / "other"
        implementation = self.root / "implementation"
        audit.mkdir(); other.mkdir(); implementation.mkdir()
        content_pack = audit / "unique-archive-content.zip"
        with zipfile.ZipFile(content_pack, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(digest, content)
        (implementation / "recovery-git-blobs.zip").write_bytes(b"unused invalid Git pack")
        (audit / "archive-reconstruction-map.json").write_text(json.dumps([{
            "archive": "old-source.zip", "archive_sha256": "a" * 64,
            "members": [
                {"name": "nested", "type": "b'5'", "mode": 0o755, "mtime": None},
                {"name": "nested/source.txt", "sha256": digest, "size": len(content),
                 "retained_in": "unique-archive-content.zip/" + digest,
                 "mode": 0o640, "mtime": None},
            ],
        }]), encoding="utf-8")
        (other / "archive-reconstruction-map.json").write_text("[]", encoding="utf-8")
        original = (recovery.AUDIT, recovery.OTHER, recovery.GIT_PACK)
        recovery.AUDIT, recovery.OTHER, recovery.GIT_PACK = (
            audit, other, implementation / "recovery-git-blobs.zip")
        try:
            destination = self.root / "reconstructed"
            result = recovery.restore_source_archive("old-source.zip", destination)
            self.assertEqual(result["directories"], 1)
            self.assertEqual((destination / "nested/source.txt").read_bytes(), content)
            self.assertEqual((destination / "nested/source.txt").stat().st_mode & 0o777, 0o640)
            self.assertEqual((destination / "nested").stat().st_mode & 0o777, 0o755)
        finally:
            recovery.AUDIT, recovery.OTHER, recovery.GIT_PACK = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
