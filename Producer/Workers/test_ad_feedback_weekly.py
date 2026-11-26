"""Disposable end-to-end tests for weekly ad-feedback intake reports."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ad_feedback_weekly as weekly


class WeeklyAdFeedbackTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.feedback = self.root / "owner-inbox.json"
        self.history = self.root / "history"
        self.runs = self.root / "reports"
        self.prior = self.history / "ad-feedback-intake-2026-11-11" / "ledger-investigated.json"
        self.entries = [
            self.entry("old-reproduced", kind="adHere"),
            self.entry("old-unresolved", kind="goodCut"),
            self.entry("new-report", kind="notAnAd"),
        ]
        self.write_inbox()

    @staticmethod
    def entry(feedback_id: str, *, kind: str, label: str | None = None) -> dict:
        return {
            "id": feedback_id,
            "kind": kind,
            "itemID": f"item-{feedback_id}",
            "revisionID": f"revision-{feedback_id}",
            "playedSeconds": 37.0,
            "originalSeconds": 35.0,
            "mapping": "mapped",
            "nearestCut": None,
            "engineVersion": "engine-fixture",
            "pipelineFingerprint": "fingerprint-fixture",
            "createdAt": "2026-11-23T12:00:00Z",
            "deviceID": "fixture-device",
            "source": "mac",
            "showTitle": "Fixture Show",
            "episodeTitle": "Fixture Episode",
            "review": "accepted",
            "label": label,
            "reviewedAt": None,
        }

    def write_inbox(self):
        self.feedback.write_text(json.dumps({"version": 1, "entries": self.entries}), encoding="utf-8")

    def write_prior_ledger(self):
        self.prior.parent.mkdir(parents=True, exist_ok=True)
        rows = []
        for entry, disposition in zip(self.entries[:2], ("reproduced", "unresolved")):
            rows.append({
                **entry,
                "disposition": disposition,
                "evidenceStatus": "exact-input",
                "investigationStatus": "investigated",
                "findings": f"fixture {disposition}",
                "nextAction": f"fixture next action for {disposition}",
                "evidencePaths": [f"evidence/{disposition}.json"],
            })
        self.prior.write_text(json.dumps(rows), encoding="utf-8")

    def run_week(self, **overrides):
        prior_ledgers = overrides.pop(
            "prior_ledgers", [self.prior] if self.prior.is_file() else [],
        )
        return weekly.run_weekly(
            feedback=self.feedback,
            runs_root=self.runs,
            history_root=self.history,
            week_start="2026-11-23",
            prior_ledgers=prior_ledgers,
            **overrides,
        )

    @staticmethod
    def read_json(path: Path) -> dict:
        return json.loads(path.read_text(encoding="utf-8"))

    def test_prior_investigationIsCarriedOnlyForMatchingIdentity(self):
        self.write_prior_ledger()
        inbox_before = self.feedback.read_bytes()

        result = self.run_week()[0]

        summary = result["summary"]
        self.assertEqual(summary["unhandled"], 3)
        self.assertEqual(summary["new"], 1)
        self.assertEqual(summary["previouslyInvestigated"], 2)
        self.assertEqual(summary["previousDispositions"], {"reproduced": 1, "unresolved": 1})
        ledger = self.read_json(result["runDirectory"] / "ledger.json")
        by_id = {row["id"]: row for row in ledger["entries"]}
        self.assertEqual(by_id["old-reproduced"]["disposition"], "reproduced")
        self.assertEqual(by_id["old-reproduced"]["evidencePaths"], ["evidence/reproduced.json"])
        self.assertTrue(by_id["old-reproduced"]["priorRecords"][0]["identityMatched"])
        self.assertEqual(by_id["new-report"]["investigationStatus"], "new")
        report = (result["runDirectory"] / "REPORT.md").read_text(encoding="utf-8")
        self.assertIn("1 new", report)
        self.assertIn("reproduced 1, unresolved 1", report)
        self.assertEqual(self.feedback.read_bytes(), inbox_before)
        self.assertFalse((self.root / "ad-feedback-actions").exists())

    def test_capturedSnapshotOverridesTransformedLedgerNearestCut(self):
        history_dir = self.history / "ad-feedback-intake-2026-11-11"
        history_dir.mkdir(parents=True)
        original = dict(self.entries[0])
        historical = dict(original, nearestCut=["cut", 11.0, 36.0, 25.0])
        ledger = history_dir / "ledger-investigated.json"
        ledger.write_text(json.dumps([dict(
            historical, disposition="reproduced", evidenceStatus="exact-input",
        )]), encoding="utf-8")
        (history_dir / "ad-feedback.json").write_text(json.dumps({
            "version": 1, "entries": [original],
        }), encoding="utf-8")

        result = self.run_week(prior_ledgers=[ledger])[0]

        output = self.read_json(result["runDirectory"] / "ledger.json")
        row = next(item for item in output["entries"] if item["id"] == original["id"])
        prior = row["priorRecords"][0]
        self.assertEqual(row["investigationStatus"], "previously-investigated")
        self.assertTrue(prior["identityMatched"])
        self.assertEqual(prior["identitySource"], "snapshot")
        self.assertEqual(prior["ledgerIdentityDifferences"], ["nearestCut"])

    def test_capturedSnapshotStillReopensRelabelledReport(self):
        history_dir = self.history / "ad-feedback-intake-2026-11-11"
        history_dir.mkdir(parents=True)
        original = dict(self.entries[0])
        historical = dict(original, nearestCut=["cut", 11.0, 36.0, 25.0])
        ledger = history_dir / "ledger-investigated.json"
        ledger.write_text(json.dumps([dict(
            historical, disposition="reproduced", evidenceStatus="exact-input",
        )]), encoding="utf-8")
        (history_dir / "ad-feedback.json").write_text(json.dumps({
            "version": 1, "entries": [original],
        }), encoding="utf-8")
        self.entries[0] = self.entry(original["id"], kind=original["kind"], label="changed")
        self.write_inbox()

        result = self.run_week(prior_ledgers=[ledger])[0]

        output = self.read_json(result["runDirectory"] / "ledger.json")
        row = next(item for item in output["entries"] if item["id"] == original["id"])
        prior = row["priorRecords"][0]
        self.assertEqual(row["investigationStatus"], "changed-since-prior")
        self.assertFalse(prior["identityMatched"])
        self.assertEqual(prior["identitySource"], "snapshot")

    def test_correctedSnapshotRefreshesGeneratedDispositionWithoutDroppingEvidence(self):
        history_dir = self.history / "ad-feedback-intake-2026-11-11"
        history_dir.mkdir(parents=True)
        original = dict(self.entries[0])
        historical = dict(original, nearestCut=["cut", 11.0, 36.0, 25.0])
        ledger = history_dir / "ledger-investigated.json"
        ledger.write_text(json.dumps([dict(
            historical, disposition="reproduced", evidenceStatus="exact-input",
            findings="verified on the retained input", evidencePaths=["fixture/replay.json"],
        )]), encoding="utf-8")
        snapshot_path = history_dir / "ad-feedback.json"
        snapshot_path.write_text(json.dumps({
            "version": 1, "entries": [dict(original, nearestCut={"changed": True})],
        }), encoding="utf-8")

        first = self.run_week(prior_ledgers=[ledger])[0]
        first_ledger = self.read_json(first["runDirectory"] / "ledger.json")
        first_row = next(item for item in first_ledger["entries"] if item["id"] == original["id"])
        self.assertEqual(first_row["disposition"], "needs-verification")

        snapshot_path.write_text(json.dumps({"version": 1, "entries": [original]}), encoding="utf-8")
        second = self.run_week(prior_ledgers=[ledger])[0]
        second_ledger = self.read_json(second["runDirectory"] / "ledger.json")
        second_row = next(item for item in second_ledger["entries"] if item["id"] == original["id"])
        self.assertEqual(second_row["investigationStatus"], "previously-investigated")
        self.assertEqual(second_row["disposition"], "reproduced")
        self.assertEqual(second_row["evidenceStatus"], "exact-input")
        self.assertEqual(second_row["findings"], "verified on the retained input")
        self.assertEqual(second_row["evidencePaths"], ["fixture/replay.json"])

    def test_changedIdentityReopensPreviouslyInvestigatedReport(self):
        self.write_prior_ledger()
        self.entries[0] = self.entry("old-reproduced", kind="adHere", label="must-keep")
        self.write_inbox()

        result = self.run_week()[0]

        ledger = self.read_json(result["runDirectory"] / "ledger.json")
        row = next(item for item in ledger["entries"] if item["id"] == "old-reproduced")
        self.assertEqual(row["investigationStatus"], "changed-since-prior")
        self.assertEqual(row["disposition"], "needs-verification")
        self.assertFalse(row["priorRecords"][0]["identityMatched"])
        self.assertEqual(result["summary"]["changedSincePrior"], 1)

    def test_retryAfterReportWriteFailureReusesOneRunAndLedger(self):
        original_replace = weekly._atomic_replace

        def fail_report_once(path: Path, data: bytes):
            if path.name == "REPORT.md":
                raise weekly.WeeklyReportError("simulated report write interruption")
            return original_replace(path, data)

        with patch.object(weekly, "_atomic_replace", side_effect=fail_report_once):
            with self.assertRaisesRegex(weekly.WeeklyReportError, "simulated report write"):
                self.run_week()

        snapshot_sha = hashlib.sha256(self.feedback.read_bytes()).hexdigest()
        run_dir = self.runs / "2026-11-23" / snapshot_sha
        ledger_path = run_dir / "ledger.json"
        ledger = self.read_json(ledger_path)
        ledger["entries"][0]["findings"] = "operator note retained after interruption"
        ledger_path.write_text(json.dumps(ledger), encoding="utf-8")
        os.chmod(ledger_path, 0o600)
        self.assertFalse((run_dir / "REPORT.md").exists())

        retry = self.run_week()[0]
        report_path = retry["runDirectory"] / "REPORT.md"
        report_bytes = report_path.read_bytes()
        saved = self.read_json(ledger_path)
        self.assertEqual(len(saved["entries"]), 3)
        self.assertEqual(saved["entries"][0]["findings"], "operator note retained after interruption")

        repeated = self.run_week()[0]
        self.assertEqual(repeated["runDirectory"], retry["runDirectory"])
        self.assertEqual(report_path.read_bytes(), report_bytes)
        self.assertEqual(len(list((self.runs / "2026-11-23").glob("*/REPORT.md"))), 1)

    def test_incompleteOldRunWithReportAndStaleSummaryResumesAfterInboxChanges(self):
        original_replace = weekly._atomic_replace

        def fail_before_summary_write(path: Path, data: bytes):
            if path.name == "summary.json":
                raise weekly.WeeklyReportError("simulated summary write failure")
            return original_replace(path, data)

        with patch.object(weekly, "_atomic_replace", side_effect=fail_before_summary_write):
            with self.assertRaisesRegex(weekly.WeeklyReportError, "summary write failure"):
                self.run_week()

        old_sha = hashlib.sha256(self.feedback.read_bytes()).hexdigest()
        old_run = self.runs / "2026-11-23" / old_sha
        summary_path = old_run / "summary.json"
        self.assertTrue((old_run / "REPORT.md").is_file())
        self.assertFalse(summary_path.exists())
        summary_path.write_text(json.dumps({"total": 999}), encoding="utf-8")
        os.chmod(summary_path, 0o600)
        self.assertFalse(weekly._run_is_complete(old_run, "2026-11-23"))

        self.entries.append(self.entry("changed-inbox", kind="adHere"))
        self.write_inbox()
        new_sha = hashlib.sha256(self.feedback.read_bytes()).hexdigest()

        results = self.run_week()

        self.assertEqual([result["snapshotSHA256"] for result in results], [old_sha, new_sha])
        self.assertEqual(self.read_json(summary_path)["total"], 3)
        self.assertTrue(weekly._run_is_complete(old_run, "2026-11-23"))
        new_run = self.runs / "2026-11-23" / new_sha
        self.assertEqual(self.read_json(new_run / "summary.json")["total"], 4)
        self.assertEqual(len(list((self.runs / "2026-11-23").glob("*/REPORT.md"))), 2)

    def test_retryAfterReportDirectorySyncFailureDoesNotDuplicateOutput(self):
        real_sync = weekly._fsync_directory
        sync_count = 0

        def fail_after_report_replace(path: Path):
            nonlocal sync_count
            sync_count += 1
            if sync_count == 4:
                raise OSError("simulated directory sync failure")
            return real_sync(path)

        with patch.object(weekly, "_fsync_directory", side_effect=fail_after_report_replace):
            with self.assertRaisesRegex(weekly.WeeklyReportError, "atomically update weekly report"):
                self.run_week()

        snapshot_sha = hashlib.sha256(self.feedback.read_bytes()).hexdigest()
        run_dir = self.runs / "2026-11-23" / snapshot_sha
        report_path = run_dir / "REPORT.md"
        self.assertTrue(report_path.is_file(), "the atomic replace completed before directory sync failed")
        report_bytes = report_path.read_bytes()

        self.run_week()

        self.assertEqual(report_path.read_bytes(), report_bytes)
        self.assertEqual(len(list((self.runs / "2026-11-23").glob("*/REPORT.md"))), 1)

    def test_malformedPriorWeeklyLedgerIsNeverOverwritten(self):
        result = self.run_week()[0]
        ledger_path = result["runDirectory"] / "ledger.json"
        ledger_path.write_text("{malformed", encoding="utf-8")
        os.chmod(ledger_path, 0o600)
        malformed = ledger_path.read_bytes()

        with self.assertRaisesRegex(weekly.WeeklyReportError, "left untouched"):
            self.run_week()

        self.assertEqual(ledger_path.read_bytes(), malformed)

    def test_priorWeeklyLedgerIsDiscoveredAcrossWeeks(self):
        first_week_root = self.history / "ad-feedback-weekly"
        weekly.run_weekly(
            feedback=self.feedback, runs_root=first_week_root, history_root=self.history,
            week_start="2026-11-23", prior_ledgers=[],
        )
        self.entries[0] = self.entry("old-reproduced", kind="adHere", label="must-keep")
        self.write_inbox()
        second_week_root = self.history / "ad-feedback-weekly"
        result = weekly.run_weekly(
            feedback=self.feedback, runs_root=second_week_root, history_root=self.history,
            week_start="2026-11-30",
        )[0]
        self.assertEqual(result["summary"]["previouslyCaptured"], 2)
        self.assertEqual(result["summary"]["changedSincePrior"], 1)
        ledger = self.read_json(result["runDirectory"] / "ledger.json")
        by_id = {row["id"]: row for row in ledger["entries"]}
        self.assertEqual(by_id["old-reproduced"]["investigationStatus"], "changed-since-prior")
        self.assertTrue(all(by_id[key]["investigationStatus"] == "previously-captured"
                            for key in ("old-unresolved", "new-report")))

    def test_groupLedgerIsRecognizedButIncompleteIdentityCannotCarryDisposition(self):
        grouped = self.history / "ad-feedback-2026-11-01" / "feedback-ledger.json"
        grouped.parent.mkdir(parents=True)
        report = self.entries[0]
        grouped.write_text(json.dumps({
            "schemaVersion": 1,
            "groups": [{
                "episodeTitle": report["episodeTitle"],
                "reports": [{
                    "feedbackID": report["id"],
                    "reportedKind": report["kind"],
                    "itemID": report["itemID"],
                    "revisionID": report["revisionID"],
                    "playedSeconds": report["playedSeconds"],
                    "originalSeconds": report["originalSeconds"],
                    "mapping": report["mapping"],
                    "nearestCut": report["nearestCut"],
                    "engineVersion": report["engineVersion"],
                    "pipelineFingerprint": report["pipelineFingerprint"],
                    "createdAt": report["createdAt"],
                    "review": report["review"],
                    "disposition": "reproduced",
                    "evidenceStatus": "metadata-only",
                }],
            }],
        }), encoding="utf-8")

        result = self.run_week(prior_ledgers=[grouped])[0]

        ledger = self.read_json(result["runDirectory"] / "ledger.json")
        row = next(item for item in ledger["entries"] if item["id"] == report["id"])
        self.assertEqual(row["investigationStatus"], "changed-since-prior")
        self.assertEqual(row["disposition"], "needs-verification")
        self.assertFalse(row["priorRecords"][0]["identityMatched"])
        self.assertEqual(row["priorRecords"][0]["disposition"], "reproduced")

    def test_duplicateIDsFailBeforeAnyOutputDirectoryIsCreated(self):
        self.entries.append(dict(self.entries[0]))
        self.write_inbox()

        with self.assertRaisesRegex(weekly.WeeklyReportError, "repeated report ID"):
            self.run_week()

        self.assertFalse(self.runs.exists())

    def test_runArtifactsAreOwnerPrivate(self):
        result = self.run_week()[0]
        run_dir = result["runDirectory"]
        self.assertEqual(stat.S_IMODE(run_dir.stat().st_mode), 0o700)
        for name in ("ad-feedback.json", "run.json", "ledger.json", "REPORT.md", "summary.json"):
            self.assertEqual(stat.S_IMODE((run_dir / name).stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
