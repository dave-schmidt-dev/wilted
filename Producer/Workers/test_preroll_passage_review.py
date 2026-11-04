"""Fail-closed unit coverage for whole-opening ad recognition."""
from __future__ import annotations

import json
import types
import unittest

from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_support import FakeSegment
from wilted_worker import cue_timing
from wilted_worker.boundary_review import reject_programme_conflicts
from wilted_worker.preroll_passage_review import (
    WHOLE_PASSAGE_PROMPT,
    _response_schema,
    _validate_response,
    recover_source_checked_preroll,
)
from wilted_worker.recovery_policy import project_detections_around_blocked_house_regions


class ReviewBackend:
    def __init__(self, boundary_id=3, passage=None):
        self.boundary_id = boundary_id
        self.boundary_response = None
        self.passage = passage
        self.lineages = []
        self.requests = []
        self.measured = []
        self.loaded = True
        self.context_size = 8192
        self.output_reserve = 1024
        self.fail_measure_prompt = None

    def measure_prompt(self, system, content, *, response_format=None):
        self.measured.append((system, content, response_format))
        if self.fail_measure_prompt == system:
            raise ValueError("measured request exceeds context")
        return types.SimpleNamespace(
            token_count=max(1, (len(system) + len(content)) // 4),
            context_size=self.context_size,
            output_reserve=self.output_reserve,
        )

    def generate(self, system, content, *, response_format=None, prepared_prompt=None):
        self.requests.append((system, content, response_format, prepared_prompt))
        if system == WHOLE_PASSAGE_PROMPT:
            return self.passage or "{}", 1
        return self.boundary_response or json.dumps({"program_start_id": self.boundary_id}), 1


def make_segments(count=20):
    phrases = [
        "Consider North Star blend coffee",
        "Roasted slowly for a balanced cup",
        "Order this morning at the station",
    ]
    return [
        FakeSegment(index * 6.0, index * 6.0 + 4.0,
                    phrases[index] if index < len(phrases) else f"Welcome to episode section {index}")
        for index in range(count)
    ]


def whole_answer(segments, candidate_ids, *, classification="paid_product_ad",
                 commercial_ids=None, programme_ids=(), quotes=None):
    commercial_ids = list(candidate_ids if commercial_ids is None else commercial_ids)
    if quotes is None:
        quotes = {index: segments[index].text for index in commercial_ids}
    return json.dumps({
        "classification": classification,
        "commercial_evidence_ids": commercial_ids,
        "programme_evidence_ids": list(programme_ids),
        "commercial_quotes": [{"id": index, "quote": quote}
                               for index, quote in quotes.items()],
    })


class WholePassageValidationTests(unittest.TestCase):
    def test_schema_and_prompt_match_measured_whole_candidate_contract(self):
        self.assertIn("Use comparison-only cues solely as context", WHOLE_PASSAGE_PROMPT)
        self.assertIn("Quotes must be exact substrings of the cited cue", WHOLE_PASSAGE_PROMPT)
        schema = _response_schema(list(range(4)))
        self.assertEqual(set(schema["schema"]["properties"]), {
            "classification", "commercial_evidence_ids", "programme_evidence_ids",
            "commercial_quotes",
        })
        self.assertFalse(schema["schema"]["additionalProperties"])

    def test_exact_quote_can_cross_two_partial_asr_fragments(self):
        segments = make_segments()
        response = whole_answer(
            segments, (0, 1, 2),
            quotes={0: "blend coffee Roasted slowly", 1: "Roasted slowly for a balanced cup",
                    2: "Order this morning at the station"},
        )
        checked = _validate_response(response, (0, 1, 2), list(range(17)), segments)
        self.assertTrue(checked["eligiblePaidCandidate"])
        self.assertEqual(checked["validatedQuoteMetadata"][0]["coveredIDs"], [0, 1])

    def test_quote_from_comparison_context_cannot_authorize_candidate(self):
        segments = make_segments()
        response = whole_answer(
            segments, (0, 1, 2),
            quotes={0: segments[0].text, 1: segments[1].text,
                    2: "Welcome to episode section 3"},
        )
        with self.assertRaisesRegex(ValueError, "exact candidate source"):
            _validate_response(response, (0, 1, 2), list(range(17)), segments)

    def test_quote_text_is_case_and_punctuation_exact(self):
        segments = make_segments()
        for quote in ("blend coffee roasted slowly", "blend coffee, Roasted slowly"):
            response = whole_answer(
                segments, (0, 1, 2),
                quotes={0: quote, 1: segments[1].text, 2: segments[2].text},
            )
            with self.subTest(quote=quote), self.assertRaises(ValueError):
                _validate_response(response, (0, 1, 2), list(range(17)), segments)

    def test_exact_source_domain_is_valid_but_an_invented_domain_is_not(self):
        segments = make_segments()
        segments[2].text = "Find more at brightkitchen.com"
        exact = whole_answer(segments, (0, 1, 2))
        checked = _validate_response(exact, (0, 1, 2), list(range(17)), segments)
        self.assertTrue(checked["eligiblePaidCandidate"])
        invented = whole_answer(
            segments, (0, 1, 2),
            quotes={0: segments[0].text, 1: segments[1].text,
                    2: "Find more at brighterkitchen.com"},
        )
        with self.assertRaisesRegex(ValueError, "exact candidate source"):
            _validate_response(invented, (0, 1, 2), list(range(17)), segments)

    def test_quote_cannot_cross_more_than_three_cues(self):
        segments = [
            FakeSegment(0, 4, "A star"), FakeSegment(6, 10, "blend Roasted"),
            FakeSegment(12, 16, "slowly Make"), FakeSegment(18, 22, "good choices"),
        ]
        raw = whole_answer(
            segments, (0, 1, 2, 3),
            quotes={0: "star blend Roasted slowly Make good choices",
                    1: "blend Roasted", 2: "slowly Make", 3: "good choices"},
        )
        with self.assertRaisesRegex(ValueError, "exact candidate source"):
            _validate_response(raw, (0, 1, 2, 3), [0, 1, 2, 3], segments)

    def test_malformed_duplicate_and_boolean_ids_are_rejected(self):
        segments = make_segments()
        valid = json.loads(whole_answer(segments, (0, 1, 2)))
        invalids = []
        for field in ("commercial_evidence_ids", "programme_evidence_ids"):
            duplicate = json.loads(json.dumps(valid))
            duplicate[field] = [0, 0]
            invalids.append(duplicate)
        boolean = json.loads(json.dumps(valid))
        boolean["commercial_evidence_ids"][0] = True
        invalids.append(boolean)
        invalids.append({"classification": "paid_product_ad"})
        for response in invalids:
            with self.subTest(response=response), self.assertRaises(ValueError):
                _validate_response(json.dumps(response), (0, 1, 2), list(range(17)), segments)


class WholePassageRecoveryTests(unittest.TestCase):
    def review(self, backend, segments, detections=(), *, remove_self_promotion=False, held=()):
        ads = install_fake_ads(backend)
        return ads, recover_source_checked_preroll(
            ads, backend, segments, list(detections), total_seconds=300.0,
            remove_self_promotion=remove_self_promotion, held_spans=held,
        )

    def test_paid_opening_replaces_broad_cut_with_source_cues_and_preserves_gaps(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2), programme_ids=(3, 4)))
        old = [FakeAd(0.0, 18.0, "sponsor_read", 0.73, ("paid advertising",))]
        held = []
        _ads, detections = self.review(backend, segments, old, held=held)
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in detections], [
            (0.0, 4.0, "ad_break"), (6.0, 10.0, "ad_break"), (12.0, 16.0, "ad_break"),
        ])
        cuts, keeps = cue_timing.build_effective_cut_map(detections, 300.0)
        self.assertEqual(cuts, [(0.0, 4.0), (6.0, 10.0), (12.0, 16.0)])
        self.assertIn((4.0, 6.0), [(item.start_s, item.end_s) for item in keeps])
        self.assertIn((10.0, 12.0), [(item.start_s, item.end_s) for item in keeps])
        self.assertTrue(any(item.start_s <= 16.0 and item.end_s >= 18.0 for item in keeps))
        self.assertTrue(any(span.reason == "programme-boundary" and span.start_s == 18.0
                            for span in held))
        self.assertEqual(len(backend.requests), 2)
        self.assertEqual(backend.requests[1][0], WHOLE_PASSAGE_PROMPT)
        self.assertIn("Comparison-only IDs: 3,4,5", backend.requests[1][1])
        self.assertNotIn("0.000s", backend.requests[1][1])

    def test_outside_tail_and_metadata_survive_opening_refinement(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2)))
        old = [FakeAd(0.0, 30.0, "sponsor_read", 0.73, ("paid advertising",))]
        _ads, detections = self.review(backend, segments, old)
        self.assertEqual((detections[-1].start_s, detections[-1].end_s), (18.0, 30.0))
        self.assertEqual(detections[-1].confidence, 0.73)
        self.assertEqual(detections[-1].kinds, ("paid advertising",))

    def test_programme_evidence_in_candidate_vetoes_and_records_a_hold(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), classification="mixed", programme_ids=(1, 3),
        ))
        held = []
        old = [FakeAd(0.0, 18.0, "sponsor_read")]
        _ads, detections = self.review(backend, segments, old, held=held)
        self.assertEqual(detections, old)
        self.assertTrue(any(span.reason == "programme-boundary" and span.start_s == 6.0
                            for span in held))

    def test_whole_programme_verdict_with_empty_ids_blocks_old_opening_cuts(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), classification="programme",
            commercial_ids=(), quotes={},
        ))
        held = []
        old = [FakeAd(0.0, 18.0, "sponsor_read")]
        _ads, detections = self.review(backend, segments, old, held=held)
        self.assertEqual(detections, old)
        self.assertEqual(reject_programme_conflicts(detections, held), [])
        self.assertTrue(any(span.reason == "programme-boundary"
                            and span.start_s == 0.0 and span.end_s == 18.0 for span in held))

    def test_house_promotion_never_qualifies_as_a_paid_passage(self):
        segments = make_segments()
        for remove in (False, True):
            backend = ReviewBackend(passage=whole_answer(
                segments, (0, 1, 2), classification="house_promo",
            ))
            with self.subTest(remove_self_promotion=remove):
                _ads, detections = self.review(backend, segments, remove_self_promotion=remove)
                self.assertEqual(detections, [])

    def test_disabled_house_verdict_with_empty_ids_clears_old_opening_cut(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), classification="house_promo",
            commercial_ids=(), quotes={},
        ))
        held = []
        old = [FakeAd(0.0, 18.0, "sponsor_read")]
        ads, detections = self.review(backend, segments, old, held=held)
        projected = project_detections_around_blocked_house_regions(detections, ads, held)
        self.assertEqual(projected, [])
        self.assertTrue(any(span.reason == "house-promotion-disabled"
                            and span.start_s == 0.0 and span.end_s == 18.0 for span in held))

    def test_known_house_cue_blocks_paid_review_when_house_removal_is_disabled(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2)))
        backend.lineages = [types.SimpleNamespace(
            classifications={1: {"ad:self_promo"}},
        )]
        _ads, detections = self.review(backend, segments, remove_self_promotion=False)
        self.assertEqual(detections, [])
        self.assertEqual(len(backend.requests), 1)

    def test_any_existing_hold_in_candidate_including_point_hold_blocks_review(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2)))
        point_hold = types.SimpleNamespace(start_s=9.0, end_s=9.0, reason="review-hold")
        _ads, detections = self.review(backend, segments, held=[point_hold])
        self.assertEqual(detections, [])
        self.assertEqual(len(backend.requests), 1)

    def test_punctuation_only_cue_is_not_cut(self):
        segments = make_segments()
        segments[1].text = "!!!"
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), commercial_ids=(0, 2),
            quotes={0: segments[0].text, 2: segments[2].text},
        ))
        _ads, detections = self.review(backend, segments)
        self.assertEqual([ad.start_s for ad in detections], [0.0, 12.0])

    def test_short_right_context_is_used_without_truncating_candidate(self):
        segments = make_segments(count=7)
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2)))
        _ads, detections = self.review(backend, segments)
        self.assertEqual(len(detections), 3)
        self.assertIn("Comparison-only IDs: 3,4,5,6", backend.requests[1][1])

    def test_overflow_and_unreadable_review_fail_closed(self):
        segments = make_segments()
        for mode in ("overflow", "invalid"):
            backend = ReviewBackend(passage="not json")
            if mode == "overflow":
                backend.fail_measure_prompt = WHOLE_PASSAGE_PROMPT
            with self.subTest(mode=mode):
                _ads, detections = self.review(backend, segments)
                self.assertEqual(detections, [])
                self.assertEqual(len(backend.requests), 1 if mode == "overflow" else 2)

    def test_empty_input_and_boundary_at_first_cue_make_no_passage_request(self):
        backend = ReviewBackend(boundary_id=0)
        ads = install_fake_ads(backend)
        self.assertEqual(recover_source_checked_preroll(
            ads, backend, [], [], 300.0, False, [],
        ), [])
        self.assertEqual(backend.requests, [])
        segments = make_segments()
        self.assertEqual(self.review(backend, segments)[1], [])
        self.assertEqual(len(backend.requests), 1)

    def test_malformed_nomination_and_under_minimum_candidate_stop_before_q2(self):
        segments = make_segments()
        malformed = ReviewBackend()
        malformed.boundary_response = '{"program_start_id":true}'
        self.review(malformed, segments)
        self.assertEqual(len(malformed.requests), 1)

        short_segments = make_segments()
        short_segments[2].start_s = 9.0
        short_segments[2].end_s = 13.0
        short = ReviewBackend(boundary_id=2)
        self.review(short, short_segments)
        self.assertEqual(len(short.requests), 1)

    def test_nomination_stays_within_the_existing_96_cue_and_300_second_bounds(self):
        many = [FakeSegment(index * 2.0, index * 2.0 + 1.0, f"cue {index}")
                for index in range(110)]
        by_count = ReviewBackend(boundary_id=0)
        self.review(by_count, many)
        self.assertEqual(len(by_count.requests[0][2]["ids"]), 96)
        self.assertEqual(by_count.requests[0][2]["ids"][-1], 95)

        by_time = [FakeSegment(index * 4.0, index * 4.0 + 1.0, f"cue {index}")
                   for index in range(100)]
        bounded = ReviewBackend(boundary_id=0)
        self.review(bounded, by_time)
        self.assertEqual(by_time[75].start_s, 300.0)
        self.assertEqual(by_time[76].start_s, 304.0)
        self.assertEqual(bounded.requests[0][2]["ids"][-1], 75)

    def test_mixed_or_unknown_holds_the_candidate_from_profile_fallback(self):
        segments = make_segments()
        for classification in ("mixed", "unknown"):
            backend = ReviewBackend(passage=whole_answer(
                segments, (0, 1, 2), classification=classification,
                commercial_ids=(), quotes={},
            ))
            held = []
            with self.subTest(classification=classification):
                self.review(backend, segments, held=held)
                self.assertTrue(any(span.reason == "boundary-review-unresolved"
                                    and span.start_s == 0.0 and span.end_s == 18.0
                                    for span in held))

    def test_candidate_programme_evidence_rejects_any_overlapping_final_cut(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), programme_ids=(2, 3),
        ))
        old = [FakeAd(0.0, 18.0, "sponsor_read")]
        held = []
        _ads, detections = self.review(backend, segments, old, held=held)
        checked = reject_programme_conflicts(detections, held)
        self.assertEqual(checked, [])
        self.assertEqual(len(cue_timing.build_effective_cut_map(checked, 300.0)[0]), 0)

