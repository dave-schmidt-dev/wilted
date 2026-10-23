"""Tests for `ad_feedback_export`: accepted feedback becomes draft corpus labels."""
from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import ad_corpus
import ad_feedback_export as export

NOW = datetime(2026, 10, 24, 12, 0, tzinfo=timezone.utc)
ITEM = "item-0123456789abcdef"


def entry(entry_id="fb-1", **overrides):
    base = {
        "id": entry_id,
        "kind": "adHere",
        "itemID": ITEM,
        "revisionID": "rev-1",
        "playedSeconds": 100.0,
        "originalSeconds": 100.0,
        "mapping": "mapped",
        "nearestCut": None,
        "engineVersion": "podcast-preparation-v12",
        "pipelineFingerprint": "fp-1",
        "createdAt": "2026-10-23T20:01:02Z",
        "deviceID": "mac-1",
        "source": "mac",
        "showTitle": "Waveform",
        "review": "accepted",
        "label": None,
        "reviewedAt": "2026-10-24T08:00:00Z",
    }
    base.update(overrides)
    return base


def status(revision="rev-1", *, outcome="succeeded", removed=(), kept=(), source_hash=None):
    payload = {
        "terminalResult": {"outcome": outcome, "revisionID": revision},
        "timeline": {"removed": list(removed), "kept": list(kept)},
    }
    if source_hash is not None:
        payload["evidence"] = {
            "kind": "podcast-pipeline-provenance",
            "fields": {"sourceHash": source_hash},
        }
    return payload


class FeedbackExportTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(self._tmp.name)
        self.feedback = self.base / "ad-feedback.json"
        self.library = self.base / "library.sqlite"
        self.manifest_path = self.base / "manifest.json"
        self.manifest_path.write_text(json.dumps({"cases": []}), encoding="utf-8")
        self.manifest = {"cases": []}

    def write_feedback(self, entries, version=1):
        self.feedback.write_text(
            json.dumps({"version": version, "entries": entries}), encoding="utf-8"
        )

    def write_library(self, rows):
        connection = sqlite3.connect(self.library)
        try:
            connection.execute(
                "CREATE TABLE ZPREPARATIONRECORD"
                " (ZITEMID TEXT, ZEMITTEDAT REAL, ZSTATUSDATA BLOB)"
            )
            connection.executemany(
                "INSERT INTO ZPREPARATIONRECORD VALUES (?, ?, ?)",
                [(item, emitted, json.dumps(payload)) for item, emitted, payload in rows],
            )
            connection.commit()
        finally:
            connection.close()

    def run_main(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = export.main([str(arg) for arg in args])
        return code, stdout.getvalue(), stderr.getvalue()

    def drafts(self, entries, manifest=None):
        return export.build_drafts(
            entries,
            self.manifest if manifest is None else manifest,
            library=self.base / "missing.sqlite",
            now=NOW,
        )

    def test_only_accepted_entries_are_exported(self):
        entries = [
            entry("accepted"),
            entry("pending", review="pending", itemID="item-pending", originalSeconds=500.0),
            entry("dismissed", review="dismissed", itemID="item-dismissed", originalSeconds=900.0),
        ]
        drafts = self.drafts(entries)
        exported = [
            feedback_id
            for case in drafts["newCases"]
            for item in case["expected"]
            for feedback_id in item["feedbackIDs"]
        ]
        self.assertEqual(exported, ["accepted"])
        self.assertEqual(len(drafts["newCases"]), 1)
        self.assertEqual(drafts["skipped"], [])

    def test_default_labels_and_explicit_override(self):
        entries = [
            entry("ad", kind="adHere", originalSeconds=100.0),
            entry("good", kind="goodCut", nearestCut={
                "originalStartSeconds": 200.0, "originalEndSeconds": 210.0,
                "preparedSeconds": 190.0, "label": "ad_break", "distanceSeconds": 1.0,
            }),
            entry("keep", kind="notAnAd", nearestCut={
                "originalStartSeconds": 300.0, "originalEndSeconds": 320.0,
                "preparedSeconds": 290.0, "label": "programme", "distanceSeconds": 2.0,
            }),
            entry("override", kind="adHere", label="acceptable-cut", originalSeconds=400.0),
        ]
        expected = self.drafts(entries)["newCases"][0]["expected"]
        self.assertEqual(
            {(item["start"], item["end"], item["label"]) for item in expected},
            {
                (85.0, 115.0, "must-cut"),
                (200.0, 210.0, "must-cut"),
                (300.0, 320.0, "must-keep"),
                (385.0, 415.0, "acceptable-cut"),
            },
        )

    def test_nearest_cut_span_and_point_window(self):
        entries = [
            entry("cut", kind="goodCut", playedSeconds=470.0, originalSeconds=500.0, nearestCut={
                "originalStartSeconds": 480.0, "originalEndSeconds": 540.0,
                "preparedSeconds": 450.0, "label": "ad_break", "distanceSeconds": 4.5,
            }),
            entry("point", kind="adHere", playedSeconds=1200.25, originalSeconds=1200.25),
        ]
        expected = self.drafts(entries)["newCases"][0]["expected"]
        self.assertEqual(expected[0]["start"], 480.0)
        self.assertEqual(expected[0]["end"], 540.0)
        self.assertFalse(expected[0]["needsTiming"])
        self.assertIn("ad_break cut 8:00-9:00", expected[0]["why"])
        self.assertIn("(original 8:20), next to the ad_break cut 8:00-9:00", expected[0]["why"])
        self.assertEqual(expected[1]["start"], 1185.25)
        self.assertEqual(expected[1]["end"], 1215.25)
        self.assertTrue(expected[1]["needsTiming"])
        self.assertIn("Retime to cue boundaries before adopting.", expected[1]["why"])

    def test_identical_spans_merge_with_combined_feedback_ids(self):
        entries = [
            entry("z-later", originalSeconds=100.0, createdAt="2026-10-24T09:00:00Z",
                  engineVersion="podcast-preparation-v13"),
            entry("a-earlier", originalSeconds=100.0, createdAt="2026-10-23T20:01:02Z",
                  engineVersion="podcast-preparation-v12"),
        ]
        expected = self.drafts(entries)["newCases"][0]["expected"]
        self.assertEqual(len(expected), 1)
        self.assertEqual(expected[0]["feedbackIDs"], ["a-earlier", "z-later"])
        self.assertEqual(expected[0]["start"], 85.0)
        self.assertEqual(expected[0]["end"], 115.0)
        self.assertIn("(2 presses)", expected[0]["why"])
        self.assertIn("engine podcast-preparation-v12", expected[0]["why"])

    def test_unmapped_entry_is_skipped(self):
        drafts = self.drafts([entry("lost", originalSeconds=None, nearestCut=None)])
        self.assertEqual(drafts["skipped"], [{"id": "lost", "reason": "unmapped"}])
        self.assertEqual(drafts["newCases"], [])
        self.assertEqual(drafts["additions"], [])

    def test_known_item_becomes_addition_and_unknown_item_new_case(self):
        manifest = {"cases": [{"id": "known-case", "itemID": "item-known"}]}
        entries = [
            entry("known", itemID="item-known"),
            entry("fresh", itemID=ITEM, showTitle="The Show!"),
        ]
        drafts = self.drafts(entries, manifest)
        self.assertEqual(len(drafts["additions"]), 1)
        self.assertEqual(drafts["additions"][0]["caseID"], "known-case")
        self.assertEqual(drafts["additions"][0]["itemID"], "item-known")
        self.assertEqual(len(drafts["newCases"]), 1)
        self.assertEqual(drafts["newCases"][0]["id"], "the-show-feedback-01234567")
        self.assertEqual(drafts["newCases"][0]["show"], "The Show!")
        self.assertEqual(drafts["newCases"][0]["provenance"]["labelledOn"], "2026-10-24")

    def test_library_facts_use_only_the_matching_revision(self):
        self.write_library([
            (ITEM, 400.0, status("rev-1", outcome="failed")),
            (ITEM, 300.0, status(
                "rev-2",
                removed=[{
                    "originalStartSeconds": 500.0, "originalEndSeconds": 600.0,
                    "label": "ad_break", "confidence": 1.0,
                }],
                kept=[{
                    "originalStartSeconds": 600.0, "originalEndSeconds": 900.0,
                    "outputStartSeconds": 600.0,
                }],
                source_hash="sha256:wrong",
            )),
            (ITEM, 200.0, status(
                "rev-1",
                removed=[{
                    "originalStartSeconds": 100.0, "originalEndSeconds": 130.0,
                    "label": "ad_break", "confidence": 0.9,
                }],
                kept=[{
                    "originalStartSeconds": 130.0, "originalEndSeconds": 243.5,
                    "outputStartSeconds": 130.0,
                }],
                source_hash="sha256:right",
            )),
            (ITEM, 100.0, status("rev-1", removed=[{
                "originalStartSeconds": 700.0, "originalEndSeconds": 800.0,
                "label": "ad_break", "confidence": 1.0,
            }])),
        ])
        facts = export.library_facts(ITEM, "rev-1", library=self.library)
        self.assertEqual(facts["recorded"], [
            {"start": 100.0, "end": 130.0, "confidence": 0.9, "label": "ad_break"},
        ])
        self.assertEqual(facts["audioDurationSeconds"], 243.5)
        self.assertEqual(facts["sourceHash"], "sha256:right")
        self.assertIsNone(facts["note"])

    def test_why_contains_only_generated_numbers_and_enums(self):
        entries = [entry(
            "clean",
            transcript="SECRET PROSE",
            cueText="SECRET PROSE",
            note="SECRET PROSE",
        )]
        why = self.drafts(entries)["newCases"][0]["expected"][0]["why"]
        self.assertNotIn("SECRET PROSE", why)
        self.assertEqual(
            why,
            "Listener marked Ad here from the Mac on 2026-10-23 at 1:40 on the"
            " prepared audio (original 1:40); engine podcast-preparation-v12."
            " Retime to cue boundaries before adopting.",
        )

    def test_version_mismatch_and_missing_file_exit_2(self):
        self.write_feedback([], version=2)
        code, stdout, stderr = self.run_main("--feedback", self.feedback)
        self.assertEqual(code, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(len(stderr.splitlines()), 1)
        self.assertIn("version", stderr)

        missing = self.base / "never-written.json"
        code, stdout, stderr = self.run_main("--feedback", missing)
        self.assertEqual(code, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr.strip(), f"no ad feedback at {missing}")

    def test_out_inside_the_repository_is_refused(self):
        self.write_feedback([entry()])
        target = export.REPO_ROOT / "draft-should-not-exist.json"
        self.addCleanup(lambda: target.unlink(missing_ok=True))
        code, stdout, stderr = self.run_main(
            "--feedback", self.feedback,
            "--library", self.base / "missing.sqlite",
            "--manifest", self.manifest_path,
            "--out", target,
        )
        self.assertEqual(code, 2)
        self.assertEqual(stdout, "")
        self.assertIn("inside the repository", stderr)
        self.assertFalse(target.exists())

    def test_out_in_temp_dir_writes_valid_json(self):
        self.write_feedback([entry()])
        target = self.base / "drafts" / "ad-feedback-drafts.json"
        code, stdout, stderr = self.run_main(
            "--feedback", self.feedback,
            "--library", self.base / "missing.sqlite",
            "--manifest", self.manifest_path,
            "--out", target,
        )
        self.assertEqual(code, 0)
        self.assertEqual(stdout, "")
        text = target.read_text(encoding="utf-8")
        self.assertTrue(text.endswith("\n"))
        payload = json.loads(text)
        self.assertEqual(
            list(payload), ["generatedAt", "feedback", "newCases", "additions", "skipped"]
        )
        self.assertEqual(payload["feedback"], str(self.feedback))
        self.assertEqual(len(payload["newCases"]), 1)
        self.assertEqual(
            stderr.strip(),
            "ad-feedback.drafts new_cases=1 additions=0 needs_timing=1 skipped=0 accepted=1",
        )

    def test_missing_library_adds_a_todo_note(self):
        case = self.drafts([entry()])["newCases"][0]
        self.assertEqual(case["recorded"], [])
        self.assertIsNone(case["sourceHash"])
        self.assertIsNone(case["audioDurationSeconds"])
        self.assertTrue(any("library facts unavailable" in todo for todo in case["todo"]))

    def test_real_manifest_loads_and_empty_feedback_is_empty(self):
        manifest = ad_corpus.load_manifest()
        drafts = export.build_drafts(
            [], manifest, library=self.base / "missing.sqlite", now=NOW
        )
        self.assertEqual(drafts["generatedAt"], "2026-10-24T12:00:00Z")
        self.assertEqual(drafts["newCases"], [])
        self.assertEqual(drafts["additions"], [])
        self.assertEqual(drafts["skipped"], [])


if __name__ == "__main__":
    unittest.main()
