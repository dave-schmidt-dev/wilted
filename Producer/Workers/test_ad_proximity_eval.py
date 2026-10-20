"""Tests for the ad-proximity review-priority evaluation harness.

The corpus pins are frozen output from the committed manifest, so a change to
the geometry or the labels has to be explained rather than absorbed. The
synthetic fixtures run the real detection entry point with the shared model
doubles: they prove review windows follow what the engine actually cut, and
that looking at those windows never changes the cut or the keeps.
"""

from __future__ import annotations

import copy
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

import ad_proximity_eval as proximity
from ad_corpus import Span, load_manifest
from wilted_worker import ad_removal, cue_timing, transcript_sources
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, synthetic_render, wp

TOTAL_KEYS = (
    "config", "windows", "windowsWithMissedAd", "missedAds", "missedAdsReached",
    "programmeIntervalsFlagged", "flagged", "missedAdFlagged", "programmeFlagged",
    "acceptableFlagged", "unlabelledFlagged", "missedAdUncut", "labelledUncut",
    "windowPrecision", "labelledPrecision", "labelledBaseRate", "lift",
)

# Re-pinned 2026-10-20 when the four AI Daily Brief cases joined the corpus.
# The six earlier cases still reproduce the previous rows exactly; the new
# cases add 16 labelled advertising spans (each show's own promotion, which
# those cases score as must-cut, and four mid-roll pods) and 518.7s of
# labelled advertising, and two of their recorded runs cut nothing at all.
RECORDED_ROWS = (
    ("after-sponsor-read-continuation-reach", 4, 0, 24, 0, 0, 270.2, 0.0, 0.0, 0.0,
     270.2, 911.7, 15168.4, 0.0, 0.0, 0.06, 0.0),
    ("after-90", 10, 1, 24, 1, 4, 810.2, 1.7, 347.7, 0.0, 460.8, 911.7, 15168.4, 0.1,
     0.005, 0.06, 0.083),
    ("before-90", 12, 3, 24, 4, 6, 913.4, 130.2, 404.6, 10.3, 368.3, 911.7, 15168.4,
     0.25, 0.239, 0.06, 3.983),
    ("both-30", 22, 4, 24, 4, 9, 583.6, 71.9, 208.4, 10.3, 293.0, 911.7, 15168.4, 0.182,
     0.247, 0.06, 4.117),
    ("both-60", 22, 4, 24, 5, 9, 1153.6, 101.9, 482.2, 10.3, 559.2, 911.7, 15168.4,
     0.182, 0.171, 0.06, 2.85),
    ("both-90", 22, 4, 24, 5, 9, 1723.6, 131.9, 752.2, 10.3, 829.2, 911.7, 15168.4,
     0.182, 0.147, 0.06, 2.45),
    ("both-120", 22, 4, 24, 5, 9, 2293.6, 138.5, 1022.2, 10.3, 1122.6, 911.7, 15168.4,
     0.182, 0.118, 0.06, 1.967),
)

CONFIRMED_ROWS = (
    ("after-sponsor-read-continuation-reach", 3, 0, 24, 0, 0, 180.2, 0.0, 0.0, 0.0,
     180.2, 911.7, 15168.4, 0.0, 0.0, 0.06, 0.0),
    ("after-90", 6, 1, 24, 1, 1, 450.2, 1.7, 83.4, 0.0, 365.1, 911.7, 15168.4, 0.167,
     0.02, 0.06, 0.333),
    ("before-90", 7, 3, 24, 4, 3, 630.0, 130.2, 163.4, 0.0, 336.4, 911.7, 15168.4,
     0.429, 0.443, 0.06, 7.383),
    ("both-30", 13, 4, 24, 4, 4, 360.2, 71.9, 62.9, 0.0, 225.4, 911.7, 15168.4, 0.308,
     0.533, 0.06, 8.883),
    ("both-60", 13, 4, 24, 5, 4, 720.2, 101.9, 156.7, 0.0, 461.6, 911.7, 15168.4, 0.308,
     0.394, 0.06, 6.567),
    ("both-90", 13, 4, 24, 5, 4, 1080.2, 131.9, 246.7, 0.0, 701.6, 911.7, 15168.4,
     0.308, 0.348, 0.06, 5.8),
    ("both-120", 13, 4, 24, 5, 4, 1440.2, 138.5, 336.7, 0.0, 965.0, 911.7, 15168.4,
     0.308, 0.291, 0.06, 4.85),
)


def config_named(name):
    """Return the fixed config with this name."""
    return next(config for config in proximity.CONFIGS if config.name == name)


class PinnedCorpusTests(unittest.TestCase):
    def test_the_recorded_anchor_totals_are_pinned(self):
        expected = [dict(zip(TOTAL_KEYS, row)) for row in RECORDED_ROWS]
        self.assertEqual(proximity.evaluate(load_manifest(), "recorded"), expected)

    def test_the_label_confirmed_anchor_totals_are_pinned(self):
        expected = [dict(zip(TOTAL_KEYS, row)) for row in CONFIRMED_ROWS]
        self.assertEqual(
            proximity.evaluate(load_manifest(), "label-confirmed"), expected
        )


class ReviewWindowTests(unittest.TestCase):
    def test_cut_spans_are_removed_and_can_split_a_window(self):
        config = proximity.ProximityConfig("both", 10.0, True, True, None)
        windows = proximity.review_windows(
            [{"start": 20.0, "end": 30.0, "label": "sponsor_read"}],
            [Span(15.0, 17.0), Span(24.0, 26.0)],
            60.0,
            config,
        )
        self.assertEqual(
            [(span.start, span.end) for span in windows],
            [(10.0, 15.0), (17.0, 20.0), (30.0, 40.0)],
        )

    def test_windows_clip_at_the_start_and_the_end_of_the_episode(self):
        config = proximity.ProximityConfig("both", 30.0, True, True, None)
        windows = proximity.review_windows(
            [{"start": 5.0, "end": 35.0, "label": "ad_break"}], [], 40.0, config
        )
        self.assertEqual(
            [(span.start, span.end) for span in windows], [(0.0, 5.0), (35.0, 40.0)]
        )

    def test_overlapping_windows_merge(self):
        config = proximity.ProximityConfig("both", 10.0, True, True, None)
        windows = proximity.review_windows(
            [
                {"start": 20.0, "end": 25.0, "label": "ad_break"},
                {"start": 25.0, "end": 30.0, "label": "sponsor_read"},
            ],
            [],
            60.0,
            config,
        )
        self.assertEqual([(span.start, span.end) for span in windows], [(10.0, 40.0)])

    def test_the_label_filter_ignores_other_anchor_kinds(self):
        config = proximity.ProximityConfig(
            "sponsor-only", 10.0, False, True, frozenset({"sponsor_read"})
        )
        windows = proximity.review_windows(
            [
                {"start": 10.0, "end": 20.0, "label": "ad_break"},
                {"start": 30.0, "end": 40.0, "label": "sponsor_read"},
            ],
            [],
            60.0,
            config,
        )
        self.assertEqual([(span.start, span.end) for span in windows], [(40.0, 50.0)])

    def test_no_window_ever_overlaps_a_cut(self):
        config = proximity.ProximityConfig("both", 20.0, True, True, None)
        cuts = [Span(0.0, 7.0), Span(18.0, 22.0), Span(39.0, 50.0)]
        windows = proximity.review_windows(
            [{"start": 20.0, "end": 40.0, "label": "ad_break"}],
            cuts,
            55.0,
            config,
        )
        for window in windows:
            for cut in cuts:
                self.assertEqual(window.overlap(cut), 0.0)


class EngineFixtureTests(unittest.TestCase):
    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory(prefix="wilted-proximity-")
        self.addCleanup(self._scratch.cleanup)
        # Other suites install their own `wilted` doubles. Put back whatever
        # was loaded before this class's engine runs so the rest of the gate
        # sees the module tree it expects.
        self._wilted_modules = {
            name: module
            for name, module in sys.modules.items()
            if name == "wilted" or name.startswith("wilted.")
        }
        self.addCleanup(self._restore_wilted_modules)
        self.root = Path(self._scratch.name)
        self.audio = self.root / "source.mp3"
        self.audio.write_bytes(b"synthetic source")
        self.output = self.root / "prepared.mp3"

    def _restore_wilted_modules(self):
        for name in [name for name in sys.modules if name == "wilted" or name.startswith("wilted.")]:
            if name not in self._wilted_modules:
                del sys.modules[name]
        sys.modules.update(self._wilted_modules)

    @staticmethod
    def segments(count=20):
        return [
            FakeSegment(float(index * 10), float(index * 10 + 10),
                        f"invented passage {index}")
            for index in range(count)
        ]

    @staticmethod
    def expected(label, start, end):
        return {"label": label, "start": start, "end": end, "why": "fixture"}

    def run_engine(self, segments, detections, llm, duration):
        install_fake_ads(llm, detections=detections)
        request = {"audioPath": str(self.audio), "outputPath": str(self.output)}
        with redirect_stderr(io.StringIO()), synthetic_render(duration):
            return wp.detect_and_cut(request, self.audio, [], segments)

    @staticmethod
    def cut_spans(ad_spans):
        return [
            Span(float(span["startSeconds"]), float(span["endSeconds"]))
            for span in ad_spans
        ]

    def case(self, case_id, ad_spans, expected, duration):
        return {
            "id": case_id,
            "show": "Synthetic",
            "audioDurationSeconds": duration,
            "expected": expected,
            "recorded": [
                {
                    "start": float(span["startSeconds"]),
                    "end": float(span["endSeconds"]),
                    "label": span["label"],
                }
                for span in ad_spans
            ],
        }

    def assert_covers(self, spans, start, end):
        covered = sum(
            max(0.0, min(end, span.end_s) - max(start, span.start_s)) for span in spans
        )
        self.assertGreaterEqual(covered, end - start - 1e-9)

    def assert_cut_covers(self, spans, start, end):
        covered = sum(
            max(0.0, min(end, span.end) - max(start, span.start)) for span in spans
        )
        self.assertGreaterEqual(covered, end - start - 1e-9)

    def assert_windows_avoid(self, windows, cuts):
        for window in windows:
            for cut in cuts:
                self.assertEqual(window.overlap(cut), 0.0)

    def assert_review_is_read_only(self, case, ad_spans, keeps, duration):
        cuts = self.cut_spans(ad_spans)
        anchors = [
            {"start": float(span["startSeconds"]),
             "end": float(span["endSeconds"]), "label": span["label"]}
            for span in ad_spans
        ]
        # Deep copies, so an in-place edit of a span or keep would also fail.
        before_spans = copy.deepcopy(ad_spans)
        before_keeps = copy.deepcopy(keeps)
        for config in proximity.CONFIGS:
            windows = proximity.review_windows(anchors, cuts, duration, config)
            self.assert_windows_avoid(windows, cuts)
            proximity.score(case, config, "recorded")
        self.assertEqual(ad_spans, before_spans)
        self.assertEqual(keeps, before_keeps)

    def test_an_adjacent_produced_spot_after_the_read_is_cut_and_not_flagged(self):
        segments = self.segments()
        result = self.run_engine(
            segments,
            [FakeAd(50.0, 60.0, label="sponsor_read")],
            FakeLLM(adjacent_program_start_id=7),
            200.0,
        )
        _path, ad_spans, keeps, _raw, audit = result
        cuts = self.cut_spans(ad_spans)
        self.assertIsNone(audit["warning"])
        self.assertEqual([(span.start, span.end) for span in cuts], [(50.0, 70.0)])
        self.assert_cut_covers(cuts, 60.0, 70.0)
        self.assert_covers(keeps, 0.0, 50.0)
        self.assert_covers(keeps, 70.0, 200.0)
        case = self.case("adjacent-after", ad_spans, [
            self.expected("must-cut", 50.0, 60.0),
            self.expected("must-cut", 60.0, 70.0),
            self.expected("must-keep", 0.0, 50.0),
            self.expected("must-keep", 70.0, 200.0),
        ], 200.0)
        for name in ("after-90", "after-sponsor-read-continuation-reach"):
            result = proximity.score(case, config_named(name), "recorded")
            self.assertEqual(result["missedAds"], 0)
            self.assertEqual(result["missedAdFlagged"], 0.0)
        self.assert_review_is_read_only(case, ad_spans, keeps, 200.0)

    def test_an_adjacent_spot_before_the_read_survives_but_is_reached(self):
        segments = self.segments()
        _path, ad_spans, keeps, _raw, _audit = self.run_engine(
            segments, [FakeAd(50.0, 60.0, label="sponsor_read")], FakeLLM(), 200.0
        )
        cuts = self.cut_spans(ad_spans)
        # The engine is not told about the preceding spot, and it does not guess.
        self.assertEqual([(span.start, span.end) for span in cuts], [(50.0, 60.0)])
        self.assertEqual(sum(span.overlap(Span(40.0, 50.0)) for span in cuts), 0.0)
        self.assert_covers(keeps, 60.0, 200.0)
        case = self.case("adjacent-before", ad_spans, [
            self.expected("must-cut", 40.0, 50.0),
            self.expected("must-cut", 50.0, 60.0),
            self.expected("must-keep", 0.0, 40.0),
            self.expected("must-keep", 60.0, 200.0),
        ], 200.0)
        windows = proximity.review_windows(
            case["recorded"], cuts, 200.0, config_named("before-90")
        )
        self.assertTrue(any(window.overlap(Span(40.0, 50.0)) > 1.0 for window in windows))
        result = proximity.score(case, config_named("before-90"), "recorded")
        self.assertEqual(result["missedAdsReached"], 1)
        self.assertEqual(result["missedAdFlagged"], 10.0)
        self.assert_review_is_read_only(case, ad_spans, keeps, 200.0)

    def test_programme_between_two_spots_is_never_bridged(self):
        segments = self.segments()
        _path, ad_spans, keeps, _raw, _audit = self.run_engine(
            segments, [FakeAd(50.0, 60.0, label="sponsor_read")], FakeLLM(), 200.0
        )
        self.assert_covers(keeps, 60.0, 120.0)
        cuts = self.cut_spans(ad_spans)
        case = self.case("ad-programme-ad", ad_spans, [
            self.expected("must-cut", 50.0, 60.0),
            self.expected("must-keep", 60.0, 120.0),
            self.expected("must-cut", 120.0, 130.0),
            self.expected("must-keep", 0.0, 50.0),
            self.expected("must-keep", 130.0, 200.0),
        ], 200.0)
        for name in ("after-90", "after-sponsor-read-continuation-reach"):
            config = config_named(name)
            windows = proximity.review_windows(
                case["recorded"], cuts, 200.0, config
            )
            immediate_programme = sum(
                window.overlap(Span(60.0, 120.0)) for window in windows
            )
            self.assertEqual(immediate_programme, 60.0)
            result = proximity.score(case, config, "recorded")
            self.assertEqual(result["missedAdsReached"], 1)
            self.assertEqual(result["missedAdFlagged"], 10.0)
            self.assertEqual(result["programmeFlagged"], 80.0)
        self.assert_review_is_read_only(case, ad_spans, keeps, 200.0)

    def test_programme_on_both_sides_survives_and_is_the_only_thing_flagged(self):
        segments = self.segments()
        _path, ad_spans, keeps, _raw, _audit = self.run_engine(
            segments, [FakeAd(50.0, 60.0, label="sponsor_read")], FakeLLM(), 200.0
        )
        self.assert_covers(keeps, 0.0, 50.0)
        self.assert_covers(keeps, 60.0, 200.0)
        case = self.case("nearby-programme", ad_spans, [
            self.expected("must-cut", 50.0, 60.0),
            self.expected("must-keep", 0.0, 50.0),
            self.expected("must-keep", 60.0, 200.0),
        ], 200.0)
        for name in (
            "before-90", "after-90", "after-sponsor-read-continuation-reach",
        ):
            result = proximity.score(case, config_named(name), "recorded")
            self.assertEqual(result["missedAds"], 0)
            self.assertEqual(result["missedAdFlagged"], 0.0)
            self.assertEqual(result["unlabelledFlagged"], 0.0)
            self.assertEqual(result["acceptableFlagged"], 0.0)
            self.assertEqual(result["flagged"], result["programmeFlagged"])
            self.assertGreater(result["flagged"], 0.0)
        self.assert_review_is_read_only(case, ad_spans, keeps, 200.0)


class OldPreparedProvenanceTests(unittest.TestCase):
    def test_a_stored_older_preparation_is_scored_without_reprocessing(self):
        preparation = {
            "adSegments": [
                {"startSeconds": 60.0, "endSeconds": 70.0, "label": "sponsor_read"},
            ],
            "durationSeconds": 240.0,
            "pipelineFingerprint": "2026-08-01-legacy-engine",
        }
        self.assertNotIn("report", preparation)
        anchors = [
            {
                "start": float(segment["startSeconds"]),
                "end": float(segment["endSeconds"]),
                "label": segment["label"],
            }
            for segment in preparation["adSegments"]
        ]
        case = {
            "id": "old-prepared",
            "show": "Synthetic",
            "audioDurationSeconds": preparation["durationSeconds"],
            "expected": [
                {"label": "must-keep", "start": 0.0, "end": 60.0},
                {"label": "must-cut", "start": 60.0, "end": 70.0},
                {"label": "must-cut", "start": 70.0, "end": 80.0},
                {"label": "must-keep", "start": 80.0, "end": 240.0},
            ],
            "recorded": anchors,
        }
        cut = [
            Span(float(segment["startSeconds"]), float(segment["endSeconds"]))
            for segment in preparation["adSegments"]
        ]
        failure = AssertionError("evaluation must not reprocess stored audio")
        with mock.patch.object(ad_removal, "detect_and_cut", side_effect=failure), \
                mock.patch.object(
                    transcript_sources, "transcribe_with_daemon", side_effect=failure
                ), \
                mock.patch.object(
                    cue_timing, "_run_render_with_progress", side_effect=failure
                ):
            windows = proximity.review_windows(
                anchors, cut, 240.0, config_named("after-90")
            )
            result = proximity.score(
                case, config_named("after-90"), "recorded"
            )
        self.assertTrue(any(window.overlap(Span(70.0, 80.0)) > 1.0 for window in windows))
        self.assertEqual(result["missedAdsReached"], 1)
        self.assertEqual(result["missedAdFlagged"], 10.0)


class MainOutputTests(unittest.TestCase):
    def test_main_prints_both_anchor_tables_and_the_window_table(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = proximity.main()
        text = output.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("## Anchor set: recorded", text)
        self.assertIn("## Anchor set: label-confirmed", text)
        self.assertIn("## Per-window review: before-90 (recorded anchors)", text)
        self.assertIn("| case | window | must-cut | must-keep |", text)


if __name__ == "__main__":
    unittest.main()
