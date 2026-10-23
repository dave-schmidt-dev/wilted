"""Regression coverage for float boundaries and programme-safe ad recovery."""
from __future__ import annotations

import math
import unittest
from unittest import mock

from wilted_worker import boundary_review
from wilted_worker import commercial_preservation
from wilted_worker import commercial_seeds
from wilted_worker import constants
from wilted_worker import interval_geometry
from wilted_worker import tail_recovery
from wilted_worker.prompts import (
    OVERSIZED_SPAN_CONFIRM_PROMPT,
    OVERSIZED_SPAN_PROGRAM_START_PROMPT,
)
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment


class IntervalGeometryTests(unittest.TestCase):
    def test_one_ulp_boundary_rounding_counts_as_containment(self):
        edge = 167.32
        cue_end = math.nextafter(edge, math.inf)
        self.assertTrue(interval_geometry.interval_contains(0.0, edge, 10.0, cue_end))
        self.assertTrue(
            commercial_preservation._evidence_is_covered(
                0, [FakeSegment(10.0, cue_end, "get started today at acme dot com")],
                [FakeAd(0.0, edge)],
            )
        )

    def test_two_ulp_extension_and_real_gap_are_not_covered(self):
        edge = 167.32
        cue_end = math.nextafter(math.nextafter(edge, math.inf), math.inf)
        self.assertFalse(interval_geometry.interval_contains(0.0, edge, 10.0, cue_end))
        self.assertFalse(
            interval_geometry.interval_contains(0.0, edge, 10.0, edge + 1e-6)
        )

    def test_one_ulp_boundary_does_not_create_a_duplicate_commercial_seed(self):
        edge = 167.32
        cue_end = math.nextafter(edge, math.inf)
        segments = [
            FakeSegment(float(index * 20), float((index + 1) * 20), "editorial discussion")
            for index in range(8)
        ]
        segments.append(FakeSegment(160.0, cue_end, "get started today at acme dot com"))
        self.assertEqual(commercial_seeds.commercial_evidence_seed_ids(segments, [FakeAd(0.0, edge)]), ())

    def test_invalid_intervals_never_contain_or_overlap(self):
        valid = (0.0, 10.0)
        invalid = ((2.0, 1.0), (0.0, math.inf), (math.nan, 1.0))
        for start, end in invalid:
            with self.subTest(start=start, end=end):
                self.assertFalse(interval_geometry.is_valid_interval(start, end))
                self.assertFalse(interval_geometry.interval_contains(*valid, start, end))
                self.assertFalse(interval_geometry.intervals_overlap(*valid, start, end))

    def test_finite_point_evidence_is_contained_but_not_an_outer_interval(self):
        self.assertTrue(interval_geometry.interval_contains(0.0, 10.0, 4.0, 4.0))
        self.assertFalse(interval_geometry.interval_contains(0.0, 10.0, 4.0, 3.0))
        self.assertFalse(interval_geometry.interval_contains(0.0, 10.0, 4.0, math.inf))
        self.assertFalse(interval_geometry.interval_contains(4.0, 4.0, 4.0, 4.0))


class BoundaryReviewTests(unittest.TestCase):
    def setUp(self):
        self.ads = install_fake_ads(FakeLLM())
        self.segments = [
            FakeSegment(0.0, 10.0, "advertising cue one"),
            FakeSegment(10.0, 20.0, "advertising cue two"),
            FakeSegment(20.0, 30.0, "programme cue"),
        ]

    def review(self, ad, answer_by_prompt, *, mixed=False, held=None):
        def answer(_ads, _backend, prompt, _field, ids, _permitted, _segments):
            value = answer_by_prompt[prompt].pop(0)
            if value not in [-1, *ids]:
                raise AssertionError(f"fixture returned unsupplied ID {value}")
            return value

        with mock.patch.dict(
            boundary_review.__dict__,
            {
                "_constrained_id": mock.Mock(side_effect=answer),
                "_program_starts_inside": mock.Mock(return_value=mixed),
            },
        ):
            return boundary_review.review_candidate_span(
                self.ads, object(), self.segments, ad, 100.0, held_spans=held
            )

    def test_partial_first_and_last_cues_cannot_expand_original_proposal(self):
        ad = FakeAd(5.0, 25.0)
        result, reviewed = self.review(
            ad,
            {
                OVERSIZED_SPAN_PROGRAM_START_PROMPT: [-1],
                OVERSIZED_SPAN_CONFIRM_PROMPT: [-1],
            },
        )
        self.assertEqual(result, "confirmed")
        self.assertEqual((reviewed.start_s, reviewed.end_s), (5.0, 25.0))
        self.assertGreaterEqual(reviewed.start_s, ad.start_s)
        self.assertLessEqual(reviewed.end_s, ad.end_s)

    def test_programme_cue_is_emitted_as_a_barrier_and_crossing_cuts_fail_closed(self):
        held = []
        result, reviewed = self.review(
            FakeAd(5.0, 25.0),
            {
                OVERSIZED_SPAN_PROGRAM_START_PROMPT: [2],
                OVERSIZED_SPAN_CONFIRM_PROMPT: [-1],
            },
            held=held,
        )
        self.assertEqual(result, "confirmed")
        self.assertEqual((reviewed.start_s, reviewed.end_s), (5.0, 20.0))
        barriers = [span for span in held if span.reason == "programme-boundary"]
        self.assertEqual([(span.start_s, span.end_s) for span in barriers], [(20.0, 30.0)])

        reject = getattr(boundary_review, "reject_programme_conflicts")
        self.assertEqual(reject([FakeAd(15.0, 22.0), FakeAd(40.0, 45.0)], held), [])
        self.assertIn("programme-boundary-conflict", [span.reason for span in held])
        self.assertEqual(reject([reviewed], held), [reviewed])

    def test_mixed_programme_cue_is_kept_whole_as_a_boundary(self):
        held = []
        result, reviewed = self.review(
            FakeAd(5.0, 25.0),
            {
                OVERSIZED_SPAN_PROGRAM_START_PROMPT: [2],
                OVERSIZED_SPAN_CONFIRM_PROMPT: [-1],
            },
            mixed=True,
            held=held,
        )
        self.assertEqual(result, "confirmed")
        self.assertEqual((reviewed.start_s, reviewed.end_s), (5.0, 10.0))
        barriers = [(span.start_s, span.end_s, span.reason) for span in held]
        self.assertIn((10.0, 20.0, "programme-boundary"), barriers)
        self.assertIn((20.0, 30.0, "programme-boundary"), barriers)

    def test_truncated_confirmation_context_cannot_authorize_a_cut(self):
        for renderer in (
            lambda _ids, _segments: "truncated",
            mock.Mock(side_effect=RuntimeError("renderer unavailable")),
        ):
            with self.subTest(renderer=renderer):
                ask = mock.Mock(return_value=-1)
                held = []
                with (
                    mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}),
                    mock.patch.dict(self.ads.__dict__, {"_render_segments_bounded": renderer}),
                ):
                    outcome, reviewed = boundary_review.review_candidate_span(
                        self.ads, object(), self.segments, FakeAd(5.0, 25.0), 100.0,
                        held_spans=held,
                    )
                self.assertEqual(outcome, "unanswered")
                self.assertIsNone(reviewed)
                self.assertEqual([span.reason for span in held], ["boundary-review-unresolved"])
                # The answer says no programme is present, but an incomplete
                # view cannot earn the programme-found exemption.
                ask.assert_called_once()

    def test_positive_programme_at_prefix_keeps_the_specific_refusal_reason(self):
        ask = mock.Mock(return_value=0)
        held = []
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), self.segments, FakeAd(5.0, 25.0), 100.0,
                held_spans=held,
            )
        self.assertEqual(outcome, "program_found")
        self.assertIsNone(reviewed)
        self.assertIn("sponsor-prefix-programme-found", [span.reason for span in held])

    def test_explicit_anchor_two_rebases_inside_original_candidate(self):
        segments = [
            FakeSegment(index * 10.0, (index + 1) * 10.0, f"cue {index}")
            for index in range(5)
        ]
        ad = FakeAd(5.0, 45.0)
        held = []
        ask = mock.Mock(side_effect=[0, -1])
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), segments, ad, 100.0,
                rebase_anchor_ids=frozenset({2}), held_spans=held,
            )
        self.assertEqual(outcome, "confirmed")
        self.assertEqual((reviewed.start_s, reviewed.end_s), (20.0, 45.0))
        self.assertGreaterEqual(reviewed.start_s, ad.start_s)
        self.assertLessEqual(reviewed.end_s, ad.end_s)
        self.assertIn((0.0, 10.0, "programme-boundary"), [
            (span.start_s, span.end_s, span.reason) for span in held
        ])

    def test_positive_programme_in_rebased_tail_stops_the_cut_at_its_edge(self):
        segments = [
            FakeSegment(index * 10.0, (index + 1) * 10.0, f"cue {index}")
            for index in range(5)
        ]
        ad = FakeAd(5.0, 45.0)
        held = []
        ask = mock.Mock(side_effect=[0, 3, -1])
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), segments, ad, 100.0,
                rebase_anchor_ids=frozenset({2}), held_spans=held,
            )
        self.assertEqual(outcome, "confirmed")
        self.assertLessEqual(reviewed.end_s, segments[3].start_s)
        self.assertEqual((reviewed.start_s, reviewed.end_s), (20.0, 30.0))
        self.assertIn((30.0, 40.0, "programme-boundary"), [
            (span.start_s, span.end_s, span.reason) for span in held
        ])

    def test_interior_zero_duration_cue_is_included_in_the_full_review_window(self):
        segments = [
            FakeSegment(0.0, 10.0, "commercial prefix"),
            FakeSegment(15.0, 15.0, "zero duration evidence cue"),
            FakeSegment(20.0, 30.0, "commercial suffix"),
        ]
        ask = mock.Mock(side_effect=[-1, -1])
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), segments, FakeAd(0.0, 30.0), 100.0
            )
        self.assertEqual(outcome, "confirmed")
        self.assertEqual((reviewed.start_s, reviewed.end_s), (0.0, 30.0))
        self.assertEqual(ask.call_count, 2)
        self.assertEqual(ask.call_args_list[0].args[4], [0, 1, 2])
        self.assertEqual(ask.call_args_list[1].args[4], [0, 1, 2])

    def test_failed_programme_start_question_holds_the_span(self):
        held = []
        ask = mock.Mock(side_effect=RuntimeError("backend down"))
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), self.segments, FakeAd(0.0, 20.0), 100.0, held_spans=held
            )
        self.assertEqual((outcome, reviewed), ("unanswered", None))
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held],
                         [(0.0, 20.0, "boundary-review-unresolved")])

    def test_span_over_review_budget_cannot_be_partially_confirmed(self):
        count = constants.OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS + 1
        segments = [
            FakeSegment(index * 10.0, (index + 1) * 10.0, f"cue {index}")
            for index in range(count)
        ]
        ask = mock.Mock(return_value=-1)
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}):
            outcome, reviewed = boundary_review.review_candidate_span(
                self.ads, object(), segments, FakeAd(0.0, count * 10.0),
                count * 10.0,
            )
        self.assertEqual(outcome, "unanswered")
        self.assertIsNone(reviewed)
        ask.assert_not_called()


class CreditsBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.segments = [
            FakeSegment(0.0, 10.0, "programme mixed with credits"),
            FakeSegment(10.0, 20.0, "closing credits continue"),
            FakeSegment(20.0, 30.0, "closing credits end"),
        ]

    def run_trim(self, llm, *, kinds=("credits",)):
        llm.load()
        ads = install_fake_ads(llm)
        candidate = FakeAd(5.0, 25.0, kinds=kinds)
        held = []
        result = tail_recovery.trim_credit_span_heads(
            ads, llm, self.segments, [candidate], held_spans=held
        )
        return ads, candidate, result, held, llm

    def test_programme_in_mixed_credits_cue_moves_cut_to_cue_end(self):
        _ads, _candidate, result, held, _llm = self.run_trim(
            FakeLLM(tail_carries_program=True)
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(10.0, 25.0)])
        self.assertIn((0.0, 10.0, "programme-boundary"), [
            (span.start_s, span.end_s, span.reason) for span in held
        ])

    def test_credits_cue_without_programme_keeps_original_span(self):
        _ads, candidate, result, held, _llm = self.run_trim(
            FakeLLM(tail_carries_program=False)
        )
        self.assertEqual(result, [candidate])
        self.assertEqual(held, [])

    def test_malformed_optional_credits_review_holds_the_entire_span(self):
        _ads, candidate, result, held, _llm = self.run_trim(
            FakeLLM(answer="not json")
        )
        self.assertEqual(result, [])
        self.assertIn((candidate.start_s, candidate.end_s, "credits-boundary-unresolved"), [
            (span.start_s, span.end_s, span.reason) for span in held
        ])

    def test_one_ulp_drift_probes_the_credits_spans_own_first_cue(self):
        edge = math.nextafter(10.0, math.inf)
        segments = [
            FakeSegment(0.0, edge, "programme before the credits"),
            FakeSegment(edge, 20.0, "programme mixed with credits"),
            FakeSegment(20.0, 30.0, "closing credits end"),
        ]
        llm = FakeLLM(tail_carries_program=True)
        llm.load()
        held = []
        result = tail_recovery.trim_credit_span_heads(
            install_fake_ads(llm), llm, segments, [FakeAd(10.0, 25.0, kinds=("credits",))],
            held_spans=held,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(20.0, 25.0)])
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held],
                         [(edge, 20.0, "programme-boundary")])

    def test_paid_candidate_is_not_probed_or_changed(self):
        _ads, candidate, result, held, llm = self.run_trim(
            FakeLLM(tail_carries_program=True), kinds=()
        )
        self.assertEqual(result, [candidate])
        self.assertEqual(held, [])
        self.assertEqual(llm.requests, [])


if __name__ == "__main__":
    unittest.main()
