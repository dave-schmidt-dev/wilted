"""Cross-pass protection of positive programme evidence, without inference."""
from __future__ import annotations

import io
import math
import unittest
from contextlib import redirect_stderr
from unittest import mock

import test_break_starts as break_start_fixtures
from wilted_worker import boundary_review, break_starts, tail_recovery
from wilted_worker.ad_audit import AdAnalysisAudit, HeldAdSpan
from wilted_worker.ad_outcome import decide_ad_outcome
from wilted_worker.sponsor_evidence import explicit_sponsor_opening_pattern
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, load_ad_corpus


class ProgrammeBarrierContractTests(unittest.TestCase):
    def test_only_positive_evidence_is_a_barrier(self):
        for reason in (
            "programme-boundary", "programme-boundary-conflict",
            "boundary-review-unresolved", "credits-boundary-unresolved",
            "sponsor-prefix-programme-found", "total-share-ceiling",
        ):
            with self.subTest(reason=reason):
                self.assertEqual(
                    boundary_review.overlaps_programme_boundary(
                        [HeldAdSpan(10.0, 20.0, reason)], 15.0, 25.0
                    ), reason == "programme-boundary",
                )

    def test_overlap_retains_geometry_and_reads_new_evidence(self):
        held = []
        self.assertFalse(boundary_review.overlaps_programme_boundary(held, 10.0, 20.0))
        boundary_review.record_programme_boundary(held, FakeSegment(10.0, 20.0, "programme"))
        two_ulps = math.nextafter(math.nextafter(10.0, math.inf), math.inf)
        for start, end, expected in (
            (0.0, 10.0, False), (20.0, 30.0, False),
            (0.0, math.nextafter(10.0, math.inf), False),
            (0.0, two_ulps, True), (15.0, 15.0, True),
            (math.nan, 15.0, False), (20.0, 10.0, False),
        ):
            with self.subTest(start=start, end=end):
                self.assertEqual(
                    boundary_review.overlaps_programme_boundary(held, start, end), expected
                )
        self.assertFalse(boundary_review.overlaps_programme_boundary(None, 10.0, 20.0))

    def test_missing_ledger_and_reporting_keep_existing_behavior(self):
        cue = FakeSegment(10.0, 20.0, "programme")
        boundary_review.record_programme_boundary(None, cue)
        held = []
        stream = io.StringIO()
        with redirect_stderr(stream):
            boundary_review.record_programme_boundary(held, cue, 100.0)
        self.assertEqual(held, [HeldAdSpan(10.0, 20.0, "programme-boundary")])
        self.assertIn('ads.detect.span.held', stream.getvalue())
        self.assertIn('10%', stream.getvalue())

    def produced_barrier(self, producer):
        """Run real writers over the saved late-start regression fixture."""
        segments = break_start_fixtures.LateBreakStartTests.SEGMENTS
        llm = FakeLLM(boundary_starts_program=True, tail_carries_program=True)
        llm.load()
        ads = install_fake_ads(llm)
        held = []
        if producer == "tail":
            tail_recovery.trim_straddling_span_tails(
                ads, llm, segments, [FakeAd(30.0, 90.0)], explicit_sponsor_opening_pattern(ads), held
            )
        elif producer == "credits":
            tail_recovery.trim_credit_span_heads(
                ads, llm, segments, [FakeAd(65.0, 130.0, kinds=("credits",))], held
            )
        else:
            with mock.patch.dict(boundary_review.__dict__, {
                "_constrained_id": mock.Mock(side_effect=[2, -1]),
                "_program_starts_inside": mock.Mock(return_value=False),
            }):
                boundary_review.review_candidate_span(
                    ads, llm, segments, FakeAd(30.0, 90.0), 300.0, held_spans=held
                )
        self.assertIn(HeldAdSpan(65.0, 90.0, "programme-boundary"), held)
        return ads, segments, held

    def test_every_writer_blocks_late_start_and_final_crossing(self):
        for producer in ("tail", "credits", "review"):
            with self.subTest(producer=producer), redirect_stderr(io.StringIO()):
                ads, segments, held = self.produced_barrier(producer)
                backend = break_start_fixtures.RecordingBackend()
                candidate = break_start_fixtures.LateBreakStartTests.DETECTION
                result = break_starts.recover_late_break_starts(
                    ads, backend, segments, [candidate], 300.0, held
                )
                self.assertEqual(result, [candidate])
                self.assertEqual(backend.calls, [])
                # A later caller may propose a crossing despite the window stop.
                # The final guard must retain the whole original, not just this cut.
                crossing = [FakeAd(70.0, 130.0), FakeAd(200.0, 210.0)]
                self.assertEqual(boundary_review.reject_programme_conflicts(crossing, held), [])
                self.assertIn("programme-boundary-conflict", [span.reason for span in held])
                self.assertIsNotNone(decide_ad_outcome(
                    AdAnalysisAudit(held_spans=tuple(held)), []
                ).keep_whole_reason)

    def test_recorded_barrier_survives_a_later_commercial_confirmation(self):
        for producer in ("tail", "credits", "review"):
            with self.subTest(producer=producer), redirect_stderr(io.StringIO()):
                ads, segments, held = self.produced_barrier(producer)
                with mock.patch.dict(boundary_review.__dict__, {
                    "_constrained_id": mock.Mock(return_value=-1),
                }):
                    outcome, cut = boundary_review.review_candidate_span(
                        ads, object(), segments, FakeAd(30.0, 130.0), 300.0,
                        held_spans=held,
                    )
                self.assertEqual(outcome, "confirmed")
                self.assertEqual((cut.start_s, cut.end_s), (30.0, 60.0))
                self.assertEqual(boundary_review.reject_programme_conflicts([cut], held), [cut])

    def test_saved_corpus_programme_labels_survive_crossing_proposals(self):
        # Real saved label timings, injected positive evidence: this checks the
        # shared guard/scorer integration, not the model's ability to find them.
        corpus = load_ad_corpus()
        checked = 0
        for case in corpus.load_manifest()["cases"]:
            for label in case["expected"]:
                if label["label"] != "must-keep":
                    continue
                start, end = float(label["start"]), float(label["end"])
                with self.subTest(case=case["id"], start=start), redirect_stderr(io.StringIO()):
                    held = []
                    boundary_review.record_programme_boundary(
                        held, FakeSegment(start, end, "saved programme label")
                    )
                    proposal = FakeAd(start, end)
                    before = corpus.score_case(case, [corpus.Span(start, end)])
                    self.assertGreater(before.keep_loss_seconds, 0.0)
                    result = boundary_review.reject_programme_conflicts([proposal], held)
                    after = corpus.score_case(case, [corpus.Span(ad.start_s, ad.end_s) for ad in result])
                    self.assertEqual(after.keep_loss_seconds, 0.0)
                    self.assertIsNotNone(decide_ad_outcome(
                        AdAnalysisAudit(held_spans=tuple(held)), result
                    ).keep_whole_reason)
                    checked += 1
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()
