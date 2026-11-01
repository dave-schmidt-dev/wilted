"""Recorded scoring must not borrow cuts from another source or revision."""

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import ad_corpus


class RecordedIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.library = self.root / "library.sqlite"
        with sqlite3.connect(self.library) as connection:
            connection.execute(
                "CREATE TABLE ZPREPARATIONRECORD"
                " (ZITEMID TEXT, ZEMITTEDAT REAL, ZSTATUSDATA BLOB)"
            )
        self.case = {
            "id": "source-pinned", "itemID": "item-one", "show": "Synthetic",
            "sourceHash": "sha256:original", "audioDurationSeconds": 100,
            "expected": [{"start": 10, "end": 20, "label": "must-cut", "why": "fixture"}],
        }

    def status(self, source="sha256:original", revision="rev-one", start=10, end=20):
        return {
            "terminalResult": {"outcome": "succeeded", "revisionID": revision},
            "evidence": {
                "kind": "podcast-pipeline-provenance", "fields": {"sourceHash": source},
            },
            "timeline": {"removed": [{"originalStartSeconds": start, "originalEndSeconds": end}]},
        }

    def insert(self, status, at, item="item-one"):
        with sqlite3.connect(self.library) as connection:
            connection.execute(
                "INSERT INTO ZPREPARATIONRECORD VALUES (?, ?, ?)",
                (item, at, json.dumps(status)),
            )

    def cuts(self, **fields):
        return ad_corpus.recorded_spans(dict(self.case, **fields), library=self.library)

    def test_changed_download_cannot_supply_a_passing_timeline(self):
        self.insert(self.status(source="sha256:different-ad-insertion"), 2)
        self.assertIsNone(self.cuts())
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"cases": [self.case]}))
        verdict, = ad_corpus.run(
            "recorded", library=self.library, cache=self.root,
            manifest=manifest, strict=True,
        )
        self.assertFalse(verdict.passed)
        self.assertFalse(verdict.skipped)
        self.assertEqual(verdict.spans, [])

    def test_finds_matching_source_behind_newer_foreign_timeline(self):
        self.insert(self.status(), 1)
        self.insert(self.status(source="sha256:other", start=40, end=60), 2)
        self.assertEqual(self.cuts(), [ad_corpus.Span(10, 20)])

    def test_optional_revision_pins_the_reported_preparation(self):
        self.insert(self.status(), 1)
        self.insert(self.status(revision="rev-two", start=30, end=40), 2)
        self.assertEqual(self.cuts(revisionID="rev-one"), [ad_corpus.Span(10, 20)])
        self.assertEqual(self.cuts(), [ad_corpus.Span(30, 40)])
        self.assertIsNone(self.cuts(revisionID="rev-missing"))

    def test_failed_attempt_does_not_replace_successful_cuts(self):
        self.insert(self.status(), 1)
        failure = self.status(start=30, end=40)
        failure["terminalResult"]["outcome"] = "failed"
        self.insert(failure, 2)
        self.assertEqual(self.cuts(), [ad_corpus.Span(10, 20)])

    def test_requires_success_and_pipeline_provenance(self):
        variants = [[], {"timeline": self.status()["timeline"]}]
        for missing in ("terminalResult", "evidence"):
            status = self.status()
            del status[missing]
            variants.append(status)
        wrong_kind = self.status()
        wrong_kind["evidence"]["kind"] = "unrelated"
        variants.append(wrong_kind)
        for index, status in enumerate(variants):
            self.insert(status, index)
        self.assertIsNone(self.cuts())

    def test_empty_removed_list_is_a_real_no_cuts_result(self):
        status = self.status()
        status["timeline"]["removed"] = []
        self.insert(status, 1)
        self.assertEqual(self.cuts(), [])

    def test_malformed_matching_success_does_not_fall_back_to_older_success(self):
        self.insert(self.status(), 1)
        for index, removed in enumerate((None, {}, [None], [{"originalStartSeconds": True,
                                                          "originalEndSeconds": 20}],
                                          [{"originalStartSeconds": 20,
                                            "originalEndSeconds": 10}]), 2):
            status = self.status()
            status["timeline"]["removed"] = removed
            self.insert(status, index)
            with self.subTest(removed=removed):
                self.assertIsNone(self.cuts())

    def test_unidentified_case_or_missing_library_is_unavailable(self):
        self.insert(self.status(), 1)
        for source in (None, ""):
            self.assertIsNone(self.cuts(sourceHash=source))
        self.assertIsNone(self.cuts(revisionID=""))
        self.assertIsNone(ad_corpus.recorded_spans(self.case, library=self.root / "absent.sqlite"))
        self.assertFalse((self.root / "absent.sqlite").exists())


if __name__ == "__main__":
    unittest.main()
