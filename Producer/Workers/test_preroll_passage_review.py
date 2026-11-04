"""Fail-closed unit coverage for whole-opening ad recognition."""
from __future__ import annotations

import hashlib
import io
import json
import re
import types
import unittest
from contextlib import nullcontext, redirect_stderr
from unittest import mock

from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment
from wilted_worker import cue_timing
from wilted_worker import feed_profile_runtime
from wilted_worker.ad_outcome import decide_ad_outcome
from wilted_worker.ad_removal import analyze_ad_detections
from wilted_worker.boundary_review import reject_programme_conflicts
from wilted_worker.preroll_passage_review import (
    MAX_REVIEW_CHARS,
    PREROLL_PROGRAM_START_PROMPT,
    WHOLE_PASSAGE_PROMPT,
    _response_schema,
    _validate_response,
    recover_source_checked_preroll,
)
from wilted_worker.cue_timing import serialize_ad_audit
from wilted_worker.recovery_policy import project_detections_around_blocked_house_regions


class MeasuredPromptOverflow(ValueError):
    """The synthetic backend's exact measured prompt exceeded its context."""

    def __init__(self, token_count, context_size, output_reserve):
        self.token_count = token_count
        self.context_size = context_size
        self.output_reserve = output_reserve
        super().__init__("measured prompt exceeds synthetic context")


class ReviewBackend:
    def __init__(self, boundary_id=3, passage=None):
        self.boundary_id = boundary_id
        self.boundary_response = None
        self.passage = passage
        self.lineages = []
        self.requests = []
        self.measured = []
        self.measured_preparations = []
        self.loaded = True
        self.context_size = 8192
        self.output_reserve = 1024
        self.prompt_context_sizes = {}
        self.prompt_output_reserves = {}
        self.raise_capacity_errors = False
        self.fail_measure_prompt = None

    def measure_prompt(self, system, content, *, response_format=None):
        self.measured.append((system, content, response_format))
        if self.fail_measure_prompt == system:
            raise ValueError("measured request exceeds context")
        payload = system + "\n" + content + "\n" + json.dumps(
            response_format or {}, sort_keys=True,
        )
        token_count = max(1, (len(payload) + 3) // 4)
        context_size = self.prompt_context_sizes.get(system, self.context_size)
        output_reserve = self.prompt_output_reserves.get(system, self.output_reserve)
        if (self.raise_capacity_errors
                and token_count + output_reserve > context_size):
            raise MeasuredPromptOverflow(token_count, context_size, output_reserve)
        prepared = types.SimpleNamespace(
            token_count=token_count,
            context_size=context_size,
            output_reserve=output_reserve,
            request_key=(system, content, json.dumps(response_format or {}, sort_keys=True)),
        )
        self.measured_preparations.append(prepared)
        return prepared

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

    def test_oversized_q1_fits_complete_cue_prefix_and_keeps_q2_context_full(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), programme_ids=(8,),
        ))
        backend.prompt_context_sizes[PREROLL_PROGRAM_START_PROMPT] = 315
        backend.prompt_output_reserves[PREROLL_PROGRAM_START_PROMPT] = 70
        backend.raise_capacity_errors = True

        _ads, detections = self.review(backend, segments)

        q1 = backend.requests[0]
        q1_ids = q1[2]["ids"]
        expected_q1 = "\n".join(
            _ads._segment_prefix(index, segments[index]) + segments[index].text
            for index in q1_ids
        )
        self.assertEqual(q1_ids, [0, 1, 2, 3])
        self.assertEqual(q1[1], expected_q1)
        self.assertIs(q1[3], next(
            prepared for prepared in backend.measured_preparations
            if prepared.request_key == (
                q1[0], q1[1], json.dumps(q1[2], sort_keys=True),
            )
        ))
        self.assertNotIn(segments[8].text, q1[1])
        q1_attempts = [item for item in backend.measured if item[0] == PREROLL_PROGRAM_START_PROMPT]
        self.assertGreater(len(q1_attempts), 1)
        self.assertLessEqual(len(q1_attempts), 20)
        q1_attempt_ids = [response_format["ids"] for _system, _text, response_format in q1_attempts]
        self.assertTrue(all(ids == list(range(len(ids))) for ids in q1_attempt_ids))
        self.assertEqual(len([request for request in backend.requests
                             if request[0] == PREROLL_PROGRAM_START_PROMPT]), 1)

        q2 = backend.requests[1]
        self.assertEqual(q2[0], WHOLE_PASSAGE_PROMPT)
        self.assertIn("Candidate IDs: 0,1,2", q2[1])
        self.assertIn("Comparison-only IDs: " + ",".join(map(str, range(3, 17))), q2[1])
        self.assertIn(f"[ID 8] {segments[8].text}", q2[1])
        for index in range(17):
            self.assertIn(f"[ID {index}] {segments[index].text}", q2[1])
        self.assertNotIn(f"[ID 17] {segments[17].text}", q2[1])
        self.assertEqual(len(backend.requests), 2)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in detections], [
            (0.0, 4.0), (6.0, 10.0), (12.0, 16.0),
        ])

    def test_character_pressure_drops_only_trailing_complete_q1_cues(self):
        segments = make_segments()
        for index in (17, 18, 19):
            segments[index].text = f"late source cue {index} " + "additional words " * 360
        backend = ReviewBackend(passage=whole_answer(
            segments, (0, 1, 2), programme_ids=(8,),
        ))
        backend.prompt_context_sizes[PREROLL_PROGRAM_START_PROMPT] = 100_000

        self.review(backend, segments)

        q1 = backend.requests[0]
        self.assertEqual(q1[2]["ids"], list(range(18)))
        self.assertLessEqual(len(q1[1]), MAX_REVIEW_CHARS)
        self.assertIn(segments[17].text, q1[1])
        self.assertNotIn("late source cue 18", q1[1])
        self.assertNotIn("late source cue 19", q1[1])
        self.assertEqual(len([item for item in backend.measured
                             if item[0] == PREROLL_PROGRAM_START_PROMPT]), 1)
        q2 = backend.requests[1]
        self.assertEqual(q2[0], WHOLE_PASSAGE_PROMPT)
        self.assertIn("Comparison-only IDs: " + ",".join(map(str, range(3, 17))), q2[1])
        self.assertNotIn("[ID 17]", q2[1])

    def test_two_cue_budget_overflow_keeps_first_cue_and_never_infers(self):
        segments = make_segments()
        segments[0].text = "mandatory opening cue " + "dense source words " * 180
        backend = ReviewBackend()
        backend.prompt_context_sizes[PREROLL_PROGRAM_START_PROMPT] = 350
        backend.prompt_output_reserves[PREROLL_PROGRAM_START_PROMPT] = 100
        backend.raise_capacity_errors = True

        held = []
        _ads, detections = self.review(backend, segments, held=held)

        q1_attempts = [item for item in backend.measured if item[0] == PREROLL_PROGRAM_START_PROMPT]
        self.assertEqual(q1_attempts[-1][2]["ids"], [0, 1])
        self.assertIn(segments[0].text, q1_attempts[-1][1])
        self.assertEqual(len(q1_attempts), 19)
        self.assertEqual(backend.requests, [])
        self.assertEqual(detections, [])
        self.assertEqual(
            [(span.start_s, span.end_s, span.reason) for span in held],
            [(0.0, 6.0, "boundary-review-unresolved")],
        )

    def test_unavailable_q1_measurement_fails_without_prefix_trimming(self):
        segments = make_segments()
        backend = ReviewBackend()
        backend.fail_measure_prompt = PREROLL_PROGRAM_START_PROMPT

        _ads, detections = self.review(backend, segments)

        self.assertEqual(len(backend.measured), 1)
        self.assertEqual(backend.measured[0][2]["ids"], list(range(20)))
        self.assertEqual(backend.requests, [])
        self.assertEqual(detections, [])

    def test_empty_input_and_boundary_at_first_cue_make_no_passage_request(self):
        backend = ReviewBackend(boundary_id=0)
        ads = install_fake_ads(backend)
        self.assertEqual(recover_source_checked_preroll(
            ads, backend, [], [], 300.0, False, [],
        ), [])
        self.assertEqual(backend.requests, [])
        segments = make_segments()
        held = []
        self.assertEqual(self.review(backend, segments, held=held)[1], [])
        self.assertEqual(len(backend.requests), 1)
        self.assertEqual(held, [])

    def test_malformed_nomination_and_under_minimum_candidate_stop_before_q2(self):
        segments = make_segments()
        malformed = ReviewBackend()
        malformed.boundary_response = '{"program_start_id":true}'
        held = []
        self.review(malformed, segments, held=held)
        self.assertEqual(len(malformed.requests), 1)
        self.assertEqual(
            [(span.start_s, span.end_s, span.reason) for span in held],
            [(0.0, 114.0, "boundary-review-unresolved")],
        )

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


class SourceCheckedProfileInteractionTests(unittest.TestCase):
    """The final analysis and cut map retain whole-opening source gaps."""

    SEGMENTS = [
        FakeSegment(5.0, 10.0, "Paid game advertisement"),
        FakeSegment(20.0, 30.0, "Order the game online"),
        FakeSegment(30.0, 35.0, "..."),
        FakeSegment(50.0, 60.0, "Welcome to the show"),
    ]

    def analyze(
        self,
        profile_proposals=None,
        *,
        classification="paid_product_ad",
        total_seconds=100.0,
        q1_boundary_id=3,
        q1_answer=None,
        q1_measure_error=None,
        q1_context_size=None,
        q1_output_reserve=50,
    ):
        llm = FakeLLM(
            loaded=True,
            preroll_program_start_id=q1_boundary_id,
            whole_passage_classification=classification,
            whole_passage_commercial_ids=[0, 1],
        )
        ads = install_fake_ads(llm, detections=[
            FakeAd(60.0, 80.0, "sponsor_read", 0.97, ("paid advertising",)),
        ])
        profile = {"slots": []} if profile_proposals is not None else None
        inference = mock.patch.object(
            feed_profile_runtime,
            "recover_profile_candidates",
            return_value=feed_profile_runtime.ProfileRecovery(
                tuple(profile_proposals or ()), windows=1, requests=1,
            ),
        ) if profile_proposals is not None else nullcontext()
        measurement = nullcontext()
        nomination_response = nullcontext()
        if q1_answer is not None:
            original_generate = llm.generate

            def generated(system, content, *, response_format=None, prepared_prompt=None):
                if system == PREROLL_PROGRAM_START_PROMPT:
                    return q1_answer, 1
                return original_generate(
                    system, content, response_format=response_format,
                    prepared_prompt=prepared_prompt,
                )

            nomination_response = mock.patch.object(llm, "generate", side_effect=generated)
        if q1_measure_error is not None or q1_context_size is not None:
            original_measure = llm.measure_prompt

            def measured(system, content, *, response_format=None):
                if system != PREROLL_PROGRAM_START_PROMPT:
                    return original_measure(system, content, response_format=response_format)
                if q1_measure_error is not None:
                    raise q1_measure_error
                payload = system + "\n" + content + "\n" + json.dumps(
                    response_format or {}, sort_keys=True,
                )
                token_count = max(1, (len(payload) + 3) // 4)
                if token_count + q1_output_reserve > q1_context_size:
                    raise MeasuredPromptOverflow(
                        token_count, q1_context_size, q1_output_reserve,
                    )
                return types.SimpleNamespace(
                    token_count=token_count,
                    context_size=q1_context_size,
                    output_reserve=q1_output_reserve,
                    request_key=(system, content, json.dumps(response_format or {}, sort_keys=True)),
                )

            measurement = mock.patch.object(llm, "measure_prompt", side_effect=measured)
        with inference, measurement, nomination_response, redirect_stderr(io.StringIO()):
            analysis = analyze_ad_detections(
                ads, llm, self.SEGMENTS, total_seconds,
                ad_profile=profile,
            )
        outcome = decide_ad_outcome(analysis.audit, analysis.detections)
        cuts, keeps = cue_timing.build_effective_cut_map(analysis.detections, total_seconds)
        return analysis, outcome, cuts, keeps

    def assert_source_checked_cuts_and_paid_tail(self, analysis, outcome, cuts, keeps):
        self.assertIsNone(outcome.keep_whole_reason)
        self.assertIsNotNone(analysis.audit.opening_review)
        self.assertEqual(cuts, [(5.0, 10.0), (20.0, 30.0), (60.0, 80.0)])
        self.assertIn((0.0, 5.0), [(keep.start_s, keep.end_s) for keep in keeps])
        self.assertIn((10.0, 20.0), [(keep.start_s, keep.end_s) for keep in keeps])
        self.assertIn((30.0, 60.0), [(keep.start_s, keep.end_s) for keep in keeps])
        tail = next(ad for ad in analysis.detections if ad.start_s == 60.0)
        self.assertEqual((tail.end_s, tail.label, tail.confidence), (80.0, "sponsor_read", 0.97))
        self.assertEqual(tuple(tail.kinds), ("paid advertising",))

    def test_profile_recut_cannot_restore_leading_or_intercue_gap(self):
        result = self.analyze([FakeAd(0.0, 30.0, "profile_candidate", 0.6)])
        self.assert_source_checked_cuts_and_paid_tail(*result)

    def test_profile_recut_cannot_restore_punctuation_or_opening_tail_gaps(self):
        result = self.analyze([FakeAd(0.0, 45.0, "profile_candidate", 0.6)])
        self.assert_source_checked_cuts_and_paid_tail(*result)

    def test_no_profile_path_keeps_the_same_source_checked_geometry(self):
        result = self.analyze()
        self.assert_source_checked_cuts_and_paid_tail(*result)

    def test_unanswered_q1_holds_profile_fallback_for_short_and_long_episodes(self):
        for duration in (200.0, 1000.0):
            with self.subTest(duration=duration):
                analysis, outcome, cuts, _keeps = self.analyze(
                    [FakeAd(0.0, 45.0, "profile_candidate", 0.6)],
                    total_seconds=duration,
                    q1_measure_error=ValueError("measured prompt unavailable"),
                )
                self.assertEqual(cuts, [(0.0, 45.0), (60.0, 80.0)])
                self.assertIsNotNone(outcome.keep_whole_reason)
                self.assertIsNone(analysis.audit.opening_review)
                self.assertTrue(any(
                    held.reason == "boundary-review-unresolved"
                    and (held.start_s, held.end_s) == (0.0, 50.0)
                    for held in analysis.audit.held_spans
                ))

    def test_malformed_q1_holds_profile_fallback(self):
        analysis, outcome, cuts, _keeps = self.analyze(
            [FakeAd(0.0, 45.0, "profile_candidate", 0.6)],
            total_seconds=200.0,
            q1_answer='{"program_start_id":true}',
        )
        self.assertEqual(cuts, [(0.0, 45.0), (60.0, 80.0)])
        self.assertIsNotNone(outcome.keep_whole_reason)
        self.assertTrue(any(
            held.reason == "boundary-review-unresolved"
            and (held.start_s, held.end_s) == (0.0, 50.0)
            for held in analysis.audit.held_spans
        ))

    def test_q1_minimum_budget_overflow_holds_profile_fallback(self):
        analysis, outcome, cuts, _keeps = self.analyze(
            [FakeAd(0.0, 45.0, "profile_candidate", 0.6)],
            total_seconds=200.0,
            q1_context_size=220,
            q1_output_reserve=50,
        )
        self.assertEqual(cuts, [(0.0, 45.0), (60.0, 80.0)])
        self.assertIsNotNone(outcome.keep_whole_reason)
        self.assertTrue(any(
            held.reason == "boundary-review-unresolved"
            and (held.start_s, held.end_s) == (0.0, 20.0)
            for held in analysis.audit.held_spans
        ))

    def test_successful_zero_boundary_remains_no_opening_and_no_hold(self):
        analysis, outcome, cuts, _keeps = self.analyze(
            [FakeAd(0.0, 45.0, "profile_candidate", 0.6)],
            total_seconds=200.0,
            q1_boundary_id=0,
        )
        self.assertEqual(cuts, [(0.0, 45.0), (60.0, 80.0)])
        self.assertIsNone(outcome.keep_whole_reason)
        self.assertFalse(analysis.audit.held_spans)

    def test_accepted_opening_receipt_is_bounded_digest_only_and_serialized(self):
        analysis, _outcome, _cuts, _keeps = self.analyze()
        receipt = serialize_ad_audit(analysis.audit)["openingReview"]
        self.assertEqual(receipt["schemaVersion"], 1)
        self.assertEqual(receipt["status"], "accepted")
        self.assertEqual(receipt["candidateEndSeconds"], 50.0)
        self.assertEqual(receipt["candidateCueCount"], 3)
        self.assertEqual(receipt["quoteCount"], 2)
        self.assertEqual(receipt["coveredCueIDs"], [0, 1])
        self.assertRegex(receipt["quoteEvidenceDigest"], r"^[0-9a-f]{64}$")
        canonical = json.dumps(
            receipt["validatedQuotes"], sort_keys=True, separators=(",", ":"),
        ).encode("utf-8")
        self.assertEqual(receipt["quoteEvidenceDigest"], hashlib.sha256(canonical).hexdigest())
        serialized = json.dumps(receipt)
        self.assertNotIn("Paid game advertisement", serialized)
        self.assertNotIn("Order the game online", serialized)

    def test_mixed_or_unknown_opening_has_no_accepted_receipt(self):
        for classification in ("mixed", "unknown"):
            with self.subTest(classification=classification):
                analysis, outcome, _cuts, _keeps = self.analyze(classification=classification)
                self.assertIsNotNone(outcome.keep_whole_reason)
                self.assertIsNone(analysis.audit.opening_review)
                self.assertNotIn("openingReview", serialize_ad_audit(analysis.audit))

