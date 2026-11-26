"""External handled actions must bind a clean replay to exact feedback evidence."""
from __future__ import annotations

import base64
import hashlib
import json
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ad_feedback_handle as handle
from phase2_replay_score import score_fixture

ITEM = "item-0123456789abcdef"
REVISION = "revision-verified"
SOURCE_HASH = "sha256:" + "a" * 64


class HandledActionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Wilted Fixture"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "fixture@example.invalid"], check=True)
        (self.repo / "fixture.txt").write_text("accepted candidate\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", "fixture.txt"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "--quiet", "-m", "candidate"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "branch", "-M", "ad-tuning/fixture"], check=True)
        self.commit = subprocess.run(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], check=True,
            capture_output=True, text=True,
        ).stdout.strip()

        self.snapshot = self.root / "intake.json"
        self.feedback = self.root / "live-feedback.json"
        self.manifest = self.root / "manifest.json"
        self.library = self.root / "library.sqlite"
        self.fixture = self.root / "replay-fixture"
        self.case_id = "verified-case"
        self.case_dir = self.fixture / "cases" / self.case_id
        self.case_dir.mkdir(parents=True)
        self.report = self.root / "replay-report.json"
        self.proof = self.root / "handled-proof.json"
        self.spool = self.root / "Wilted" / "ad-feedback-actions" / "pending"
        self.configure_case("adHere")

    def configure_case(self, kind: str, *, point: float | None = None, clear_point: bool = False):
        if kind == "adHere":
            point = 25.0 if point is None else point
            nearest = None
            expected = [
                {"label": "must-keep", "start": 0.0, "end": 20.0},
                {"label": "must-cut", "start": 20.0, "end": 40.0},
                {"label": "must-keep", "start": 40.0, "end": 100.0},
            ]
            labelled = [{"start": 20.0, "end": 40.0, "kind": "sponsor", "label": "must-cut",
                         "advertisers": ["Example"]}]
        elif kind == "goodCut":
            point = 41.0 if point is None else point
            nearest = {"originalStartSeconds": 20.0, "originalEndSeconds": 40.0,
                       "preparedSeconds": 20.0, "label": "ad_break", "distanceSeconds": 1.0}
            expected = [
                {"label": "must-keep", "start": 0.0, "end": 20.0},
                {"label": "must-cut", "start": 20.0, "end": 40.0},
                {"label": "must-keep", "start": 40.0, "end": 100.0},
            ]
            labelled = [{"start": 20.0, "end": 40.0, "kind": "sponsor", "label": "must-cut",
                         "advertisers": ["Example"]}]
        else:
            kind = "notAnAd"
            point = 41.0 if point is None else point
            nearest = {"originalStartSeconds": 20.0, "originalEndSeconds": 40.0,
                       "preparedSeconds": 20.0, "label": "programme", "distanceSeconds": 1.0}
            expected = [{"label": "must-keep", "start": 0.0, "end": 100.0}]
            labelled = []

        source_entry = {
            "id": "feedback-1", "kind": kind, "itemID": ITEM, "revisionID": REVISION,
            "playedSeconds": point, "originalSeconds": point, "mapping": "mapped",
            "nearestCut": nearest, "engineVersion": "engine-1", "pipelineFingerprint": "fingerprint-1",
            "createdAt": "2026-11-01T12:00:00Z", "deviceID": "mac-test", "source": "mac",
            "showTitle": "Synthetic", "episodeTitle": "Fixture", "review": "accepted",
            "label": None, "reviewedAt": None,
        }
        if clear_point:
            source_entry["originalSeconds"] = None
            source_entry["mapping"] = "unmapped"
        stored = {"version": 1, "entries": [source_entry]}
        self.snapshot.write_text(json.dumps(stored, sort_keys=True), encoding="utf-8")
        self.feedback.write_bytes(self.snapshot.read_bytes())
        self.case_dir.joinpath("case.json").write_text(json.dumps({
            "id": self.case_id, "show": "Synthetic", "sourceHash": SOURCE_HASH,
            "itemID": ITEM, "revisionID": REVISION, "feedbackIDs": ["feedback-1"],
            "durationSeconds": 100.0, "expected": expected,
        }), encoding="utf-8")
        self.case_dir.joinpath("breaks.json").write_text(json.dumps({"labelledBreaks": labelled}), encoding="utf-8")
        self.manifest.write_text(json.dumps({"cases": [{
            "id": self.case_id, "itemID": ITEM, "revisionID": REVISION, "sourceHash": SOURCE_HASH,
        }]}), encoding="utf-8")
        with sqlite3.connect(self.library) as connection:
            connection.execute(
                "CREATE TABLE IF NOT EXISTS ZPREPARATIONRECORD"
                " (ZITEMID TEXT, ZEMITTEDAT REAL, ZSTATUSDATA BLOB)"
            )
            connection.execute("DELETE FROM ZPREPARATIONRECORD")
            status = {
                "terminalResult": {"outcome": "succeeded", "revisionID": REVISION},
                "evidence": {"kind": "podcast-pipeline-provenance", "fields": {"sourceHash": SOURCE_HASH}},
                "timeline": {"removed": []},
            }
            connection.execute("INSERT INTO ZPREPARATIONRECORD VALUES (?, ?, ?)",
                               (ITEM, 1.0, json.dumps(status)))

        score_fixture(self.fixture, output=self.report, repo=self.repo)
        report_digest = hashlib.sha256(self.report.read_bytes()).hexdigest()
        proof = {
            "schemaVersion": 1,
            "candidateCommit": self.commit,
            "intakeSnapshotSHA256": hashlib.sha256(self.snapshot.read_bytes()).hexdigest(),
            "replayReportSHA256": report_digest,
            "readyFeedback": [{"feedbackID": "feedback-1", "caseID": self.case_id}],
        }
        self.proof.write_text(json.dumps(proof), encoding="utf-8")

    def build(self):
        return handle.build_action_payload(
            proof_path=self.proof, snapshot_path=self.snapshot, replay_path=self.report,
            feedback_path=self.feedback, manifest_path=self.manifest,
            library_path=self.library, repo=self.repo,
        )

    def configure_batch(self, count: int):
        self.configure_case("adHere")
        snapshot = json.loads(self.snapshot.read_text(encoding="utf-8"))
        template = snapshot["entries"][0]
        entries = [dict(template, id=f"feedback-{index:03}") for index in range(count)]
        snapshot["entries"] = entries
        snapshot_bytes = json.dumps(snapshot, sort_keys=True).encode("utf-8")
        self.snapshot.write_bytes(snapshot_bytes)
        self.feedback.write_bytes(snapshot_bytes)

        case_path = self.case_dir / "case.json"
        case = json.loads(case_path.read_text(encoding="utf-8"))
        case["feedbackIDs"] = [entry["id"] for entry in entries]
        case_path.write_text(json.dumps(case, sort_keys=True), encoding="utf-8")
        score_fixture(self.fixture, output=self.report, repo=self.repo)

        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        proof["intakeSnapshotSHA256"] = hashlib.sha256(snapshot_bytes).hexdigest()
        proof["replayReportSHA256"] = hashlib.sha256(self.report.read_bytes()).hexdigest()
        proof["readyFeedback"] = [
            {"feedbackID": entry["id"], "caseID": self.case_id} for entry in entries
        ]
        self.proof.write_text(json.dumps(proof), encoding="utf-8")

    def test_ad_here_action_binds_the_exact_point_and_queues_idempotently(self):
        before = self.feedback.read_bytes()
        payload = self.build()
        self.assertEqual(payload["candidateCommit"], self.commit)
        self.assertEqual(payload["entries"][0]["identity"]["revisionID"], REVISION)
        self.assertEqual(payload["entries"][0]["replay"]["localEvidence"]["reportedPositionSeconds"], 25.0)
        self.assertTrue(payload["entries"][0]["replay"]["localEvidence"]["reportedPositionWasCut"])

        first = handle.enqueue_action(payload, self.spool)
        second = handle.enqueue_action(payload, self.spool)
        self.assertEqual(first[0], second[0])
        self.assertTrue(first[2])
        self.assertFalse(second[2])
        self.assertEqual(self.feedback.read_bytes(), before, "submission never edits the app-owned inbox")
        self.assertEqual(self.spool.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.spool.stat().st_mode & 0o777, 0o700)
        self.assertEqual(first[1].stat().st_mode & 0o777, 0o600)
        envelope = json.loads(first[1].read_text(encoding="utf-8"))
        self.assertEqual(envelope["actionID"], envelope["payloadSHA256"])
        raw_payload = base64.b64decode(envelope["payload"])
        self.assertEqual(hashlib.sha256(raw_payload).hexdigest(), envelope["actionID"])
        self.assertEqual(handle.WAKE_URL, "wilted://ad-feedback/process")

    def test_good_cut_and_not_an_ad_require_the_exact_local_interval(self):
        for kind in ("goodCut", "notAnAd"):
            with self.subTest(kind=kind):
                self.configure_case(kind)
                payload = self.build()
                local = payload["entries"][0]["replay"]["localEvidence"]
                self.assertEqual(local["label"], "must-cut" if kind == "goodCut" else "must-keep")
                self.assertEqual(local["nearestCutFullyCut"], kind == "goodCut")
                self.assertEqual(local["nearestCutAnyCut"], kind == "goodCut")

    def test_case_pass_does_not_clear_an_ad_here_point_that_remains(self):
        report = json.loads(self.report.read_text(encoding="utf-8"))
        report["rows"][0]["producedCuts"] = [[20.0, 24.0]]
        self.report.write_text(json.dumps(report), encoding="utf-8")
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        proof["replayReportSHA256"] = hashlib.sha256(self.report.read_bytes()).hexdigest()
        self.proof.write_text(json.dumps(proof), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "exact reported position"):
            self.build()

    def test_source_must_match_the_authoritative_exact_revision_record(self):
        with sqlite3.connect(self.library) as connection:
            status = {
                "terminalResult": {"outcome": "succeeded", "revisionID": REVISION},
                "evidence": {"kind": "podcast-pipeline-provenance", "fields": {"sourceHash": "sha256:" + "b" * 64}},
                "timeline": {"removed": []},
            }
            connection.execute("UPDATE ZPREPARATIONRECORD SET ZSTATUSDATA = ?", (json.dumps(status),))
        with self.assertRaisesRegex(handle.ActionError, "authoritative source match"):
            self.build()

    def test_relabel_after_intake_and_dirty_or_wrong_candidates_are_rejected(self):
        current = json.loads(self.feedback.read_text(encoding="utf-8"))
        current["entries"][0]["label"] = "must-keep"
        current["entries"][0]["reviewedAt"] = "2026-11-02T12:00:00Z"
        self.feedback.write_text(json.dumps(current), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "changed after the intake"):
            self.build()

        self.feedback.write_bytes(self.snapshot.read_bytes())
        current = json.loads(self.feedback.read_text(encoding="utf-8"))
        current["entries"][0]["review"] = "pending"
        self.feedback.write_text(json.dumps(current), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "changed after the intake"):
            self.build()

        self.feedback.write_bytes(self.snapshot.read_bytes())
        (self.repo / "fixture.txt").write_text("dirty\n", encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "clean tuning branch"):
            self.build()

    def test_a_clean_accepted_main_candidate_is_allowed(self):
        subprocess.run(["git", "-C", str(self.repo), "branch", "-M", "main"], check=True)
        payload = self.build()
        self.assertEqual(payload["candidateBranch"], "main")

    def test_handled_batch_limit_accepts_two_hundred_and_rejects_two_hundred_one(self):
        self.configure_batch(200)
        payload = self.build()
        self.assertEqual(len(payload["entries"]), 200)

        self.configure_batch(201)
        with self.assertRaisesRegex(handle.ActionError, "at most 200 reports"):
            self.build()

    def test_cli_queues_then_wakes_only_with_the_fixed_app_url(self):
        arguments = [
            "--proof", str(self.proof), "--snapshot", str(self.snapshot),
            "--replay-report", str(self.report), "--feedback", str(self.feedback),
            "--manifest", str(self.manifest), "--library", str(self.library),
            "--repo", str(self.repo), "--spool", str(self.spool),
        ]
        with patch.object(handle, "wake_app") as wake:
            self.assertEqual(handle.main(arguments), 0)
            wake.assert_called_once_with()

        with patch.object(handle.subprocess, "run") as run:
            handle.wake_app()
        run.assert_called_once_with(
            ["open", "-b", handle.APPLICATION_ID, "wilted://ad-feedback/process"],
            check=True, timeout=10,
        )

    def test_dismissed_or_missing_feedback_is_rejected(self):
        current = json.loads(self.feedback.read_text(encoding="utf-8"))
        current["entries"][0]["review"] = "dismissed"
        self.feedback.write_text(json.dumps(current), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "missing, dismissed"):
            self.build()

    def test_legacy_pending_review_cannot_be_marked_handled(self):
        legacy = json.loads(self.snapshot.read_text(encoding="utf-8"))
        legacy["entries"][0]["review"] = "pending"
        raw = json.dumps(legacy).encode("utf-8")
        self.snapshot.write_bytes(raw)
        self.feedback.write_bytes(raw)
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        proof["intakeSnapshotSHA256"] = hashlib.sha256(raw).hexdigest()
        self.proof.write_text(json.dumps(proof), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "must be accepted"):
            self.build()

        self.feedback.write_bytes(self.snapshot.read_bytes())
        self.feedback.write_text(json.dumps({"version": 1, "entries": []}), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "missing, dismissed"):
            self.build()

    def test_unpinned_report_id_or_unclean_replay_cannot_queue(self):
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        proof["readyFeedback"][0]["caseID"] = "another-case"
        self.proof.write_text(json.dumps(proof), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "corpus case"):
            self.build()

        self.configure_case("adHere")
        report = json.loads(self.report.read_text(encoding="utf-8"))
        report["rows"][0]["clean"] = False
        self.report.write_text(json.dumps(report), encoding="utf-8")
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        proof["replayReportSHA256"] = hashlib.sha256(self.report.read_bytes()).hexdigest()
        self.proof.write_text(json.dumps(proof), encoding="utf-8")
        with self.assertRaisesRegex(handle.ActionError, "clean exact-revision"):
            self.build()


if __name__ == "__main__":
    unittest.main()
