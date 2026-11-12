"""Tests for the ad labeller shadow report."""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import labeller_shadow_report as report


def _remote(episode: str, engine, breaks, **extra) -> dict:
    record = {
        "schemaVersion": 1,
        "episodeID": episode,
        "feedID": "feed-a",
        "route": "remote",
        "engineOutcome": "cut",
        "engineCutSpans": [{"start": s, "end": e} for s, e in engine],
        "proposedBreaks": [
            {
                "start": s,
                "end": e,
                "startCue": 0,
                "endCue": 1,
                "kind": "sponsor",
                "label": label,
                "advertisers": [],
            }
            for s, e, label in breaks
        ],
        "rejectedBreaks": [],
        "requestSeconds": 20.0,
        "requestCount": 1,
        "promptTokens": 1000,
        "completionTokens": 200,
        "reasoningTokens": 5000,
    }
    record.update(extra)
    return record


class ShadowReportTests(unittest.TestCase):
    def test_overlap_counts_shared_time_once(self):
        self.assertEqual(report.total_seconds([(0, 10), (5, 20)]), 20)
        self.assertEqual(report.overlap_seconds([(0, 10), (5, 20)], [(8, 30)]), 12)

    def test_compare_separates_must_cut_from_acceptable(self):
        row = report.compare(
            _remote(
                "e1",
                [(100, 160)],
                [(110, 170, "must-cut"), (300, 330, "acceptable-cut")],
            )
        )
        self.assertEqual(row["engineSeconds"], 60)
        self.assertEqual(row["mustCutSeconds"], 60)
        self.assertEqual(row["proposedSeconds"], 90)
        self.assertEqual(row["bothSeconds"], 50)
        self.assertEqual(row["labellerOnlySeconds"], 10)
        self.assertEqual(row["engineOnlySeconds"], 10)
        self.assertEqual(row["breakCount"], 2)

    def test_summary_counts_routes_reasons_failures_and_ad_free(self):
        records = [
            _remote("e1", [(0, 30)], [(0, 30, "must-cut")]),
            _remote("e2", [], []),
            _remote("e3", [], [], failureKind="rate-limited", requestCount=1),
            {
                "schemaVersion": 1,
                "episodeID": "e4",
                "route": "local",
                "routeReason": "notConfirmed",
            },
            {
                "schemaVersion": 1,
                "episodeID": "e5",
                "route": "local",
                "routeReason": "privateTitle",
            },
        ]
        summary = report.summarise(records)
        self.assertEqual(
            (summary["episodes"], summary["remote"], summary["local"]), (5, 3, 2)
        )
        self.assertEqual(
            summary["localReasons"], {"notConfirmed": 1, "privateTitle": 1}
        )
        self.assertEqual(summary["failures"], {"rate-limited": 1})
        self.assertEqual(
            (summary["labelled"], summary["adFree"], summary["requests"]), (2, 1, 3)
        )
        self.assertEqual(summary["medianReasoningTokens"], 5000)

    def test_summary_counts_backfilled_and_unknown_engine_records(self):
        records = [
            _remote("e1", [(0, 30)], [(0, 30, "must-cut")]),
            _remote("e2", [], [], source="backfill", engineOutcome="unknown"),
            _remote("e3", [], [], source="backfill", failureKind="rate-limited"),
        ]
        summary = report.summarise(records)
        # A backfill attempt that failed labelled nothing.
        self.assertEqual(summary["backfilled"], 1)
        self.assertEqual(summary["engineUnknown"], 1)

    def test_summary_counts_labelled_records_per_transport(self):
        records = [
            _remote("e1", [], [], transport="opencode-cli", reasoningTokens=3000),
            _remote("e2", [], [], transport="opencode-cli", reasoningTokens=5000),
            _remote("e3", [], [], transport="direct", reasoningTokens=6000),
            _remote("e4", [], []),
            _remote("e5", [], [], transport="opencode-cli", failureKind="rate-limited"),
        ]
        summary = report.summarise(records)
        self.assertEqual(
            summary["transports"],
            {
                "opencode-cli": {"labelled": 2, "medianReasoningTokens": 4000},
                "direct": {"labelled": 2, "medianReasoningTokens": 5500},
            },
        )
        text = report.render(summary, 0)
        self.assertIn("  labelled via direct: 2, median reasoning tokens 5500", text)
        self.assertIn("  labelled via opencode-cli: 2, median reasoning tokens 4000", text)

    def test_render_mentions_backfill_and_unknown_engine_only_when_present(self):
        backfilled = report.render(
            report.summarise(
                [_remote("e1", [], [], source="backfill", engineOutcome="unknown")]
            ),
            0,
        )
        self.assertIn("Labelled from stored transcripts: 1", backfilled)
        self.assertIn("no engine result on record", backfilled)
        self.assertIn("engine column reads 0:00", backfilled)
        fresh = report.render(report.summarise([_remote("e2", [], [])]), 0)
        self.assertNotIn("Labelled from stored transcripts", fresh)
        self.assertNotIn("engine column reads 0:00", fresh)

    def test_render_states_trial_size_and_skips_unreadable_files(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / "a.json").write_text(
                json.dumps(_remote("e1", [(0, 30)], [(0, 30, "must-cut")]))
            )
            (directory / "b.json").write_text("{not json")
            (directory / "c.json").write_text(json.dumps({"schemaVersion": 2}))
            (directory / "attempts.jsonl").write_text("{}\n")
            records, unreadable = report.load_records(directory)
            self.assertEqual((len(records), unreadable), (1, 2))
            text = report.render(report.summarise(records), unreadable)
        self.assertIn("Episodes recorded: 1", text)
        self.assertIn("not enough yet", text)
        self.assertIn("Unreadable record files skipped: 2", text)
        self.assertIn("e1", text)

    def test_main_reports_a_missing_folder_and_prints_json(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = Path(folder) / "none"
            err = io.StringIO()
            with redirect_stderr(err):
                self.assertEqual(report.main(["--directory", str(missing)]), 1)
            self.assertIn("No shadow records folder", err.getvalue())
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(report.main(["--directory", folder, "--json"]), 0)
            self.assertEqual(json.loads(out.getvalue())["episodes"], 0)


if __name__ == "__main__":
    unittest.main()
