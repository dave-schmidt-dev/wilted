"""Cross-pass protection of positive programme evidence, without inference."""
from __future__ import annotations

import io
import math
import unittest
from contextlib import ExitStack, redirect_stderr
from unittest import mock

import test_break_starts as break_start_fixtures
from wilted_worker import (
    ad_removal,
    boundary_review,
    break_edges,
    break_starts,
    commercial_recovery,
    commercial_seeds,
    preroll_passage_review,
    tail_recovery,
)
from wilted_worker.ad_audit import AdAnalysisAudit, HeldAdSpan
from wilted_worker.ad_outcome import decide_ad_outcome
from wilted_worker.reporting import WorkerError
from wilted_worker.sponsor_evidence import explicit_sponsor_opening_pattern
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, load_ad_corpus


class ProgrammeBarrierContractTests(unittest.TestCase):
    @staticmethod
    def _sponsor_cut_fixture():
        anchors = (
            "This episode is brought to you by Acme. Visit acme.com.",
            "This episode is brought to you by Brio. Visit brio.com.",
            "This episode is brought to you by Coda. Visit coda.com.",
        )
        segments = [
            FakeSegment(0, 10, "programme opening"),
            FakeSegment(10, 20, anchors[0]),
            FakeSegment(20, 30, "sponsor product details"),
            FakeSegment(30, 40, "programme continues"),
            FakeSegment(40, 50, anchors[1]),
            FakeSegment(50, 60, "sponsor product details"),
            FakeSegment(60, 70, "programme continues"),
            FakeSegment(70, 80, anchors[2]),
            FakeSegment(80, 90, "sponsor product details"),
            FakeSegment(90, 100, "programme ending"),
            *(FakeSegment(start, start + 10, "programme continues")
              for start in range(100, 200, 10)),
        ]
        detections = [
            FakeAd(10, 29, label="ad_break"),
            FakeAd(40, 59, label="ad_break"),
            FakeAd(70, 89, label="ad_break"),
        ]
        return segments, detections

    def _analyze_sponsor_cut_fixture(
        self, *, conflict=False, drop_anchor=False, dropped_hold=None,
        extra_share_cut=False,
    ):
        segments, detections = self._sponsor_cut_fixture()
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm, detections=detections)

        def identity_at(index):
            return lambda *args, **_kwargs: args[index]

        def late_break_review(
            _ads, _backend, _segments, current, total, held, _protected, _released,
        ):
            if drop_anchor:
                current = current[:-1]
            if dropped_hold is not None:
                held.append(dropped_hold)
            if conflict:
                boundary_review.record_programme_boundary(
                    held, FakeSegment(20, 25, "positive programme passage"), total,
                )
            if extra_share_cut:
                # The two surviving cores plus this cut still exceed 60% after
                # the third explicit anchor has independently been dropped.
                current = [*current, FakeAd(100, 190, label="ad_break")]
            return current

        with ExitStack() as stack:
            for module, name, index in (
                (commercial_recovery, "recover_unclaimed_explicit_sponsor_reads", 3),
                (commercial_seeds, "recover_commercial_evidence_reads", 3),
                (commercial_seeds, "recover_sparse_commercial_reads", 3),
                (tail_recovery, "recover_transcript_end_postroll", 3),
                (tail_recovery, "trim_credit_span_heads", 3),
                (break_edges, "trim_edge_cues_across_gaps", 2),
                (preroll_passage_review, "recover_source_checked_preroll", 3),
            ):
                stack.enter_context(mock.patch.object(module, name, side_effect=identity_at(index)))
            stack.enter_context(mock.patch.object(
                break_starts, "recover_late_break_starts", side_effect=late_break_review,
            ))
            analysis = ad_removal.analyze_ad_detections(ads, llm, segments, 200.0)
        return analysis, segments

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

    def test_conflict_retirement_ledger_records_all_cleared_cuts_only_on_conflict(self):
        held = []
        boundary_review.record_programme_boundary(held, FakeSegment(10.0, 11.0, "programme"))
        supplied = [FakeAd(10.0, 20.0), FakeAd(30.0, 40.0)]
        retired = []

        self.assertEqual(
            boundary_review.reject_programme_conflicts(
                supplied, held, retired_detections=retired,
            ),
            [],
        )
        self.assertEqual(retired, supplied)

        unchanged = [FakeAd(30.0, 40.0)]
        retired.clear()
        self.assertIs(
            boundary_review.reject_programme_conflicts(
                unchanged, held, retired_detections=retired,
            ),
            unchanged,
        )
        self.assertEqual(retired, [])

    def test_analysis_keeps_real_conflict_holds_after_other_anchors_are_dropped(self):
        analysis, segments = self._analyze_sponsor_cut_fixture(conflict=True)

        self.assertEqual(analysis.detections, ())
        self.assertEqual(set(analysis.audit.observed_ids), set(range(len(segments))))
        self.assertGreater(analysis.audit.classifier_requests, 0)
        self.assertEqual(
            analysis.audit.classifier_valid_requests,
            analysis.audit.classifier_requests,
        )
        self.assertEqual(analysis.audit.classifier_invalid_requests, 0)
        self.assertEqual(analysis.audit.model_requests, analysis.audit.classifier_requests)
        self.assertEqual(
            {held.reason for held in analysis.audit.held_spans},
            {"programme-boundary", "programme-boundary-conflict"},
        )
        self.assertEqual(len(analysis.audit.declined_commercial_evidence_seeds), 3)
        self.assertTrue(all(
            seed.reason == "dropped-after-proposal"
            for seed in analysis.audit.declined_commercial_evidence_seeds
        ))
        self.assertIsNotNone(decide_ad_outcome(analysis.audit, analysis.detections).keep_whole_reason)

    def test_analysis_keeps_holds_when_share_guard_retires_all_safe_proposals(self):
        analysis, segments = self._analyze_sponsor_cut_fixture(extra_share_cut=True)

        self.assertEqual(analysis.detections, ())
        self.assertEqual(set(analysis.audit.observed_ids), set(range(len(segments))))
        self.assertEqual(analysis.audit.classifier_invalid_requests, 0)
        self.assertEqual(analysis.audit.model_requests, analysis.audit.classifier_requests)
        self.assertTrue(analysis.audit.held_spans)
        self.assertEqual(
            {held.reason for held in analysis.audit.held_spans},
            {"total-share-ceiling"},
        )
        self.assertEqual(len(analysis.audit.declined_commercial_evidence_seeds), 3)
        self.assertTrue(all(
            seed.reason == "dropped-after-proposal"
            for seed in analysis.audit.declined_commercial_evidence_seeds
        ))
        self.assertIsNotNone(decide_ad_outcome(analysis.audit, analysis.detections).keep_whole_reason)

    def test_non_whole_original_holds_do_not_waive_dropped_anchor_audit(self):
        for held in (
            None,
            HeldAdSpan(90.0, 100.0, "programme-boundary"),
            HeldAdSpan(90.0, 100.0, "house-promotion-disabled"),
        ):
            with self.subTest(held=held), redirect_stderr(io.StringIO()):
                with self.assertRaises(WorkerError) as raised:
                    self._analyze_sponsor_cut_fixture(drop_anchor=True, dropped_hold=held)
                self.assertEqual(raised.exception.code, "ads-recovery-audit-failed")

    def test_anchor_dropped_before_later_conflict_still_fails(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(WorkerError) as raised:
            self._analyze_sponsor_cut_fixture(conflict=True, drop_anchor=True)

        self.assertEqual(raised.exception.code, "ads-recovery-audit-failed")
        self.assertIn("raw anchor ID 7", str(raised.exception))

    def test_anchor_dropped_before_later_share_refusal_still_fails(self):
        progress = io.StringIO()
        with redirect_stderr(progress), self.assertRaises(WorkerError) as raised:
            self._analyze_sponsor_cut_fixture(drop_anchor=True, extra_share_cut=True)

        self.assertIn("total-share ceiling", progress.getvalue())
        self.assertEqual(raised.exception.code, "ads-recovery-audit-failed")
        self.assertIn("raw anchor ID 7", str(raised.exception))

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
