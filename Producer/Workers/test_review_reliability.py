"""Measured ID reviews and content-free opening failure diagnostics."""
from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stderr
from unittest import mock

from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment
from test_preroll_passage_review import (
    MeasuredPromptOverflow, ReviewBackend, make_segments, whole_answer,
)
from wilted_worker.ad_audit import (
    AdAnalysisAudit, AuditingBackend, OpeningReviewReceipt, ValidatedQuoteEvidence,
)
from wilted_worker.ad_outcome import decide_ad_outcome
from wilted_worker.cue_timing import serialize_ad_audit
from wilted_worker.opening_review_response import (
    build_quote_repair_request, is_quote_repair_schema_refinement,
    repair_quotes_match_literals, response_schema, validate_response,
)
from wilted_worker.commercial_seeds import _constrained_id
from wilted_worker.preroll_passage_review import recover_source_checked_preroll
from wilted_worker.prompts import POSTROLL_PROGRAM_END_PROMPT, WHOLE_PASSAGE_PROMPT
from wilted_worker.reporting import WorkerError
from wilted_worker.review_diagnostics import opening_failure_reason
from wilted_worker.tail_recovery import recover_transcript_end_postroll


class MeasuredIDReviewTests(unittest.TestCase):
    def test_id_review_generates_the_exact_measured_full_cues(self):
        backend = FakeLLM(postroll_advertising_start_id=1)
        ads = install_fake_ads(backend)
        backend.load()
        segments = [FakeSegment(0, 10, "first programme cue"),
                    FakeSegment(10, 20, "complete commercial cue " * 60)]
        value = _constrained_id(ads, backend, POSTROLL_PROGRAM_END_PROMPT,
                               "advertising_start_id", [0, 1], [-1, 0, 1], segments)
        self.assertEqual(value, 1)
        self.assertEqual(len(backend.prepared_prompts), 1)
        measured = backend.measured_prompts[0]
        self.assertEqual(measured[1], backend.request_contents[0])
        self.assertIn(segments[1].text, measured[1])
        self.assertEqual(measured[2], backend.requests[0])

    def test_oversized_closing_review_keeps_tail_without_poisoning_confirmed_cuts(self):
        backend = FakeLLM()
        ads = install_fake_ads(backend)
        backend.load()
        audited = AuditingBackend(backend, ads, 20)
        segments = [FakeSegment(i * 40, (i + 1) * 40, "programme " * 60)
                    for i in range(20)]
        old = [FakeAd(100, 120)]
        # Reproduce the retained 4183-versus-4096 capacity failure in measurement.
        error = ValueError("Requested tokens (4183) exceed context window of 4096")
        with mock.patch.object(backend, "measure_prompt", side_effect=error), redirect_stderr(io.StringIO()):
            result = recover_transcript_end_postroll(ads, audited, segments, old, 810)
        self.assertEqual(result, old)
        self.assertEqual(backend.requests, [])
        self.assertIsNone(audited.context_capacity_error)
        self.assertEqual((audited.calls, audited.failures), (0, 0))
        self.assertIsNone(decide_ad_outcome(AdAnalysisAudit(), result).keep_whole_reason)

    def test_returned_overbudget_measurement_never_generates(self):
        backend = FakeLLM()
        ads = install_fake_ads(backend)
        backend.load()
        with mock.patch.object(backend, "measure_prompt", return_value={
            "token_count": 3900, "context_size": 4096, "output_reserve": 512,
        }), self.assertRaises(ValueError):
            _constrained_id(ads, backend, POSTROLL_PROGRAM_END_PROMPT,
                            "advertising_start_id", [0, 1], [-1, 0, 1],
                            [FakeSegment(0, 10, "one"), FakeSegment(10, 20, "two")])
        self.assertEqual(backend.requests, [])

    def test_invalid_measurement_never_generates(self):
        backend = FakeLLM()
        ads = install_fake_ads(backend)
        backend.load()
        with mock.patch.object(backend, "measure_prompt", return_value={
            "token_count": True, "context_size": 4096, "output_reserve": 512,
        }), self.assertRaises(ValueError):
            _constrained_id(ads, backend, POSTROLL_PROGRAM_END_PROMPT,
                            "advertising_start_id", [0, 1], [-1, 0, 1],
                            [FakeSegment(0, 10, "one"), FakeSegment(10, 20, "two")])
        self.assertEqual(backend.requests, [])

    def test_preflight_failure_never_clears_an_existing_audit_error(self):
        backend = FakeLLM()
        ads = install_fake_ads(backend)
        backend.load()
        audited = AuditingBackend(backend, ads, 2)
        prior = ValueError("Requested tokens (4183) exceed context window of 4096")
        audited.context_capacity_error = prior
        with mock.patch.object(backend, "measure_prompt", side_effect=prior), self.assertRaises(ValueError):
            _constrained_id(ads, audited, POSTROLL_PROGRAM_END_PROMPT,
                            "advertising_start_id", [0, 1], [-1, 0, 1],
                            [FakeSegment(0, 10, "one"), FakeSegment(10, 20, "two")])
        self.assertIs(audited.context_capacity_error, prior)

    def test_generation_overflow_still_reaches_the_final_audit(self):
        error = ValueError("Requested tokens (4183) exceed context window of 4096")
        backend = FakeLLM(fail_generate=error)
        ads = install_fake_ads(backend)
        backend.load()
        audited = AuditingBackend(backend, ads, 2)
        with self.assertRaises(ValueError):
            _constrained_id(ads, audited, POSTROLL_PROGRAM_END_PROMPT,
                            "advertising_start_id", [0, 1], [-1, 0, 1],
                            [FakeSegment(0, 10, "one"), FakeSegment(10, 20, "two")])
        self.assertIs(audited.context_capacity_error, error)
        self.assertEqual((audited.calls, audited.failures), (1, 1))


class OpeningFailureDiagnosticTests(unittest.TestCase):
    def test_legacy_receipt_without_quote_origin_stays_serializable(self):
        receipt = OpeningReviewReceipt(
            1, "accepted", 4.0, 1, 1, (0,), "0" * 64,
            (ValidatedQuoteEvidence(0, (0,), 3, "1" * 64),),
        )
        opening = serialize_ad_audit(AdAnalysisAudit(opening_review=receipt))["openingReview"]
        self.assertNotIn("quoteOrigin", opening)

    def test_valid_opening_has_no_repair_call(self):
        segments = make_segments()
        backend = ReviewBackend(passage=whole_answer(segments, (0, 1, 2)))
        ads = install_fake_ads(backend)
        recover_source_checked_preroll(ads, backend, segments, [], 300, held_spans=[])
        self.assertEqual(
            sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 1,
        )

    def test_quote_format_repair_preserves_the_original_decision(self):
        segments = make_segments()
        invalid = whole_answer(
            segments, (0, 1, 2),
            quotes={0: " ".join(["too"] * 13), 1: segments[1].text, 2: segments[2].text},
        )
        valid = whole_answer(segments, (0, 1, 2))
        backend = ReviewBackend(passage=invalid)
        original_generate = backend.generate
        responses = iter((invalid, valid))

        def generate(system, content, *, response_format=None, prepared_prompt=None):
            if system == WHOLE_PASSAGE_PROMPT:
                backend.passage = next(responses)
            return original_generate(
                system, content, response_format=response_format,
                prepared_prompt=prepared_prompt,
            )

        backend.generate = generate
        ads = install_fake_ads(backend)
        openings = []
        result = recover_source_checked_preroll(
            ads, backend, segments, [], 300, held_spans=[],
            source_checked_openings=openings,
        )
        self.assertEqual(len(result), 3)
        self.assertEqual(openings[0].receipt.quote_origin, "literal-repair")
        serialized = serialize_ad_audit(
            AdAnalysisAudit(opening_review=openings[0].receipt),
        )["openingReview"]
        self.assertEqual(serialized["quoteOrigin"], "literal-repair")
        self.assertEqual(
            sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 2,
        )
        self.assertIn("Repair only the quotes:", backend.requests[-1][1])
        self.assertIn("Permitted exact quote literals by source ID:", backend.requests[-1][1])
        self.assertIn("Original classification: paid_product_ad", backend.requests[-1][1])
        self.assertIn("Original commercial evidence IDs: 0,1,2", backend.requests[-1][1])
        self.assertNotIn(" ".join(["too"] * 13), backend.requests[-1][1])
        repair_quotes = backend.requests[-1][2]["schema"]["properties"]["commercial_quotes"]
        self.assertEqual((repair_quotes["minItems"], repair_quotes["maxItems"]), (3, 3))
        self.assertEqual(
            [item["properties"]["id"]["const"] for item in repair_quotes["prefixItems"]],
            [0, 1, 2],
        )

    def test_quote_repair_literals_are_source_bound_exact_and_id_locked(self):
        segments = make_segments()
        segments[0].text = "Buy now, save today!"
        segments[1].text = "Visit our new station today."
        invalid = whole_answer(segments, (0, 1), quotes={
            0: "Buy now save today", 1: "Visit our station today",
        })
        built = build_quote_repair_request("opening context", invalid, (0, 1), [0, 1, 2], segments)
        self.assertIsNotNone(built)
        prompt, repair_schema, quote_options = built
        quote_items = repair_schema["schema"]["properties"]["commercial_quotes"]["prefixItems"]
        self.assertEqual([item["properties"]["id"]["const"] for item in quote_items], [0, 1])
        self.assertTrue(any("Buy now, save" in quote for quote in quote_items[0]["properties"]["quote"]["enum"]))
        self.assertTrue(any("Visit our new" in quote for quote in quote_items[1]["properties"]["quote"]["enum"]))
        self.assertNotIn("Buy now save today", prompt)
        exact = json.dumps({
            "classification": "paid_product_ad",
            "commercial_evidence_ids": [0, 1],
            "programme_evidence_ids": [],
            "commercial_quotes": [
                {"id": 0, "quote": quote_items[0]["properties"]["quote"]["enum"][0]},
                {"id": 1, "quote": quote_items[1]["properties"]["quote"]["enum"][0]},
            ],
        })
        self.assertTrue(validate_response(exact, (0, 1), [0, 1, 2], segments)["eligiblePaidCandidate"])
        self.assertTrue(repair_quotes_match_literals(exact, (0, 1), quote_options))
        outside_offer = json.loads(exact)
        outside_offer["commercial_quotes"][0]["quote"] = "Buy now,"
        self.assertTrue(validate_response(
            json.dumps(outside_offer), (0, 1), [0, 1, 2], segments,
        )["eligiblePaidCandidate"])
        self.assertFalse(repair_quotes_match_literals(
            json.dumps(outside_offer), (0, 1), quote_options,
        ))
        reordered = json.loads(exact)
        reordered["commercial_quotes"].reverse()
        self.assertFalse(repair_quotes_match_literals(
            json.dumps(reordered), (0, 1), quote_options,
        ))
        missing = json.loads(exact)
        missing["commercial_quotes"].pop()
        self.assertFalse(repair_quotes_match_literals(
            json.dumps(missing), (0, 1), quote_options,
        ))
        self.assertTrue(is_quote_repair_schema_refinement(
            response_schema([0, 1, 2]), repair_schema, (0, 1),
            {0: tuple(quote_items[0]["properties"]["quote"]["enum"]),
             1: tuple(quote_items[1]["properties"]["quote"]["enum"])},
        ))

    def test_repeated_source_text_still_binds_each_repair_slot_to_its_id(self):
        segments = make_segments()
        segments[0].text = "Buy now, save today!"
        segments[1].text = segments[0].text
        invalid = whole_answer(segments, (0, 1), quotes={0: "paraphrase one", 1: "paraphrase two"})
        built = build_quote_repair_request("opening context", invalid, (0, 1), [0, 1, 2], segments)
        self.assertIsNotNone(built)
        _prompt, repair_schema, _quote_options = built
        items = repair_schema["schema"]["properties"]["commercial_quotes"]["prefixItems"]
        self.assertEqual([item["properties"]["id"]["const"] for item in items], [0, 1])
        self.assertEqual(
            items[0]["properties"]["quote"]["enum"],
            items[1]["properties"]["quote"]["enum"],
        )

    def test_quote_repair_rejects_schema_widening_and_non_quote_changes(self):
        segments = make_segments()
        invalid = whole_answer(segments, (0, 1, 2), quotes={
            0: "bad quote one", 1: "bad quote two", 2: "bad quote three",
        })
        built = build_quote_repair_request("opening context", invalid, (0, 1, 2), list(range(4)), segments)
        self.assertIsNotNone(built)
        _prompt, valid_schema, _quote_options = built
        quotes = valid_schema["schema"]["properties"]["commercial_quotes"]
        options = {
            item["properties"]["id"]["const"]: tuple(item["properties"]["quote"]["enum"])
            for item in quotes["prefixItems"]
        }
        base_schema = response_schema(list(range(4)))
        mutations = []
        changed_id = json.loads(json.dumps(valid_schema))
        changed_id["schema"]["properties"]["commercial_quotes"]["prefixItems"][0]["properties"]["id"]["const"] = 3
        mutations.append(changed_id)
        widened_quote = json.loads(json.dumps(valid_schema))
        widened_quote["schema"]["properties"]["commercial_quotes"]["prefixItems"][0]["properties"]["quote"]["enum"].append("invented phrase")
        mutations.append(widened_quote)
        changed_role = json.loads(json.dumps(valid_schema))
        changed_role["schema"]["properties"]["classification"]["enum"].append("forced_ad")
        mutations.append(changed_role)
        changed_evidence_ids = json.loads(json.dumps(valid_schema))
        changed_evidence_ids["schema"]["properties"]["commercial_evidence_ids"]["items"]["enum"].remove(3)
        mutations.append(changed_evidence_ids)
        added_property = json.loads(json.dumps(valid_schema))
        added_property["schema"]["properties"]["commercial_quotes"]["prefixItems"][0]["properties"]["extra"] = {"type": "string"}
        mutations.append(added_property)
        changed_required = json.loads(json.dumps(valid_schema))
        changed_required["schema"]["required"].remove("classification")
        mutations.append(changed_required)
        changed_additional_properties = json.loads(json.dumps(valid_schema))
        changed_additional_properties["schema"]["additionalProperties"] = True
        mutations.append(changed_additional_properties)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertFalse(is_quote_repair_schema_refinement(
                    base_schema, mutation, (0, 1, 2), options,
                ))
        changed_base = json.loads(json.dumps(base_schema))
        changed_base["schema"]["properties"]["classification"]["enum"].append("forced_ad")
        self.assertFalse(is_quote_repair_schema_refinement(
            changed_base, valid_schema, (0, 1, 2), options,
        ))

    def test_short_cue_can_only_reuse_an_already_validated_literal(self):
        segments = make_segments()
        segments[0].text = "Only two"
        response = json.loads(whole_answer(segments, (0, 1), quotes={
            0: "Only", 1: "paraphrased offer phrase",
        }))
        built = build_quote_repair_request(
            "opening context", json.dumps(response), (0, 1), [0, 1, 2], segments,
        )
        self.assertIsNotNone(built)
        prompt, repair_schema, _quote_options = built
        self.assertIn('"kind":"preserved","quote":"Only"', prompt)
        self.assertEqual(
            repair_schema["schema"]["properties"]["commercial_quotes"]["prefixItems"][0]
            ["properties"]["quote"]["enum"],
            ["Only"],
        )

    def test_short_cue_without_valid_literal_fails_closed_without_repair_call(self):
        segments = make_segments()
        segments[0].text = "Only"
        invalid = whole_answer(segments, (0, 1, 2), quotes={
            0: "invented phrase", 1: segments[1].text, 2: segments[2].text,
        })
        backend = ReviewBackend(passage=invalid)
        ads = install_fake_ads(backend)
        holds, stream = [], io.StringIO()
        with redirect_stderr(stream):
            result = recover_source_checked_preroll(
                ads, backend, segments, [], 300, held_spans=holds,
            )
        self.assertEqual(result, [])
        self.assertEqual(
            sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 1,
        )
        self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))
        self.assertIn("reason=quote-repair-source", stream.getvalue())

    def test_quote_repair_audit_accepts_only_the_original_context_and_one_refinement(self):
        segments = make_segments()
        ads = install_fake_ads(FakeLLM())
        audited = AuditingBackend(FakeLLM(), ads, len(segments))
        candidate_ids = (0, 1, 2)
        comparison_ids = tuple(range(3, 17))
        all_ids = (*candidate_ids, *comparison_ids)
        base_prompt = (
            "Candidate IDs: 0,1,2\nComparison-only IDs: "
            + ",".join(map(str, comparison_ids)) + "\nTranscript cues:\n"
            + "\n".join(f"[ID {index}] {segments[index].text}" for index in all_ids)
        )
        initial_schema = response_schema(list(all_ids))
        audited._validate_whole_passage_request(base_prompt, initial_schema)
        invalid = whole_answer(segments, candidate_ids, quotes={
            0: "bad quote one", 1: "bad quote two", 2: "bad quote three",
        })
        prompt, repair_schema, _quote_options = build_quote_repair_request(
            base_prompt, invalid, candidate_ids, list(all_ids), segments,
        )
        audited._validate_whole_passage_request(prompt, repair_schema)
        with self.assertRaises(WorkerError):
            audited._validate_whole_passage_request(prompt, repair_schema)

        audited._validate_whole_passage_request(base_prompt, initial_schema)
        audited._validate_whole_passage_request(prompt, repair_schema)
        with self.assertRaises(WorkerError):
            audited._validate_whole_passage_request(prompt, repair_schema)

        segments[0].text = "Fresh second analysis has a distinct source cue"
        second_base_prompt = (
            "Candidate IDs: 0,1,2\nComparison-only IDs: "
            + ",".join(map(str, comparison_ids)) + "\nTranscript cues:\n"
            + "\n".join(f"[ID {index}] {segments[index].text}" for index in all_ids)
        )
        audited._validate_whole_passage_request(second_base_prompt, initial_schema)
        second_invalid = whole_answer(segments, candidate_ids, quotes={
            0: "not the new cue", 1: "wrong source phrase", 2: "incorrect words",
        })
        second_prompt, second_schema, _options = build_quote_repair_request(
            second_base_prompt, second_invalid, candidate_ids, list(all_ids), segments,
        )
        audited._validate_whole_passage_request(second_prompt, second_schema)

    def test_failed_or_semantically_changed_quote_repairs_keep_original(self):
        segments = make_segments()
        invalid = whole_answer(segments, (0, 1, 2), quotes={
            0: " ".join(["too"] * 13), 1: segments[1].text, 2: segments[2].text,
        })
        valid = json.loads(whole_answer(segments, (0, 1, 2)))
        changed = [invalid]
        for field, value in (("classification", "house_promo"),
                             ("commercial_evidence_ids", [0]),
                             ("programme_evidence_ids", [3])):
            changed.append(json.dumps({**valid, field: value}))
        for repair in changed:
            backend = ReviewBackend(passage=invalid)
            original_generate = backend.generate
            responses = iter((invalid, repair))

            def generate(system, content, *, response_format=None, prepared_prompt=None):
                if system == WHOLE_PASSAGE_PROMPT:
                    backend.passage = next(responses)
                return original_generate(system, content, response_format=response_format,
                                         prepared_prompt=prepared_prompt)

            backend.generate = generate
            ads = install_fake_ads(backend)
            holds, stream = [], io.StringIO()
            with self.subTest(repair=repair), redirect_stderr(stream):
                result = recover_source_checked_preroll(ads, backend, segments, [], 300, held_spans=holds)
                self.assertEqual(result, [])
                self.assertEqual(sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 2)
                self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))

    def test_source_exact_but_unoffered_repair_literal_fails_closed(self):
        segments = make_segments()
        invalid = whole_answer(segments, (0, 1, 2), quotes={
            0: " ".join(["too"] * 13), 1: segments[1].text, 2: segments[2].text,
        })
        unoffered = json.loads(whole_answer(segments, (0, 1, 2)))
        unoffered["commercial_quotes"][0]["quote"] = "Consider North"
        self.assertTrue(validate_response(
            json.dumps(unoffered), (0, 1, 2), list(range(17)), segments,
        )["eligiblePaidCandidate"])
        backend = ReviewBackend(passage=invalid)
        original_generate = backend.generate
        responses = iter((invalid, json.dumps(unoffered)))

        def generate(system, content, *, response_format=None, prepared_prompt=None):
            if system == WHOLE_PASSAGE_PROMPT:
                backend.passage = next(responses)
            return original_generate(system, content, response_format=response_format,
                                     prepared_prompt=prepared_prompt)

        backend.generate = generate
        ads = install_fake_ads(backend)
        holds, stream = [], io.StringIO()
        with redirect_stderr(stream):
            result = recover_source_checked_preroll(
                ads, backend, segments, [], 300, held_spans=holds,
            )
        self.assertEqual(result, [])
        self.assertEqual(
            sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 2,
        )
        self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))
        self.assertIn("reason=quote-repair-literal", stream.getvalue())

    def test_positive_programme_or_mixed_result_cannot_be_retried_into_a_cut(self):
        segments = make_segments()
        for classification, programme_ids in (("paid_product_ad", [1]), ("mixed", []),
                                              ("programme", []), ("unknown", [])):
            response = json.loads(whole_answer(segments, (0, 1, 2)))
            response.update(classification=classification, programme_evidence_ids=programme_ids)
            response["commercial_quotes"][0]["quote"] = " ".join(["too"] * 13)
            backend = ReviewBackend(passage=json.dumps(response))
            ads = install_fake_ads(backend)
            holds = []
            with self.subTest(classification=classification), redirect_stderr(io.StringIO()):
                self.assertEqual(recover_source_checked_preroll(
                    ads, backend, segments, [], 300, held_spans=holds,
                ), [])
                self.assertEqual(sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 1)
                self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))

    def test_quote_retry_overflow_does_not_infer_an_oversized_request(self):
        segments = make_segments()
        invalid = whole_answer(segments, (0, 1, 2), quotes={
            0: " ".join(["too"] * 13), 1: segments[1].text, 2: segments[2].text,
        })
        backend = ReviewBackend(passage=invalid)
        original_measure = backend.measure_prompt

        def measure(system, content, *, response_format=None):
            if "Repair only the quotes:" in content:
                raise MeasuredPromptOverflow(3900, 4096, 512)
            return original_measure(system, content, response_format=response_format)

        backend.measure_prompt = measure
        ads = install_fake_ads(backend)
        holds = []
        with redirect_stderr(io.StringIO()):
            result = recover_source_checked_preroll(ads, backend, segments, [], 300, held_spans=holds)
        self.assertEqual(result, [])
        self.assertEqual(sum(system == WHOLE_PASSAGE_PROMPT for system, *_ in backend.requests), 1)
        self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))

    def test_reason_codes_never_include_unrecognized_exception_content(self):
        private = "PRIVATE_RESPONSE_DO_NOT_LOG"
        for error, expected in [
            (ValueError(private), "validation-unclassified"),
            (RuntimeError(private), "backend-unavailable"),
            (TypeError(private), "unexpected-error"),
            (json.JSONDecodeError(private, private, 0), "response-json"),
            (MeasuredPromptOverflow(3800, 4096, 512), "context-capacity"),
            (ValueError("backend cannot measure the loaded chat prompt budget"), "measurement-unavailable"),
            (ValueError("commercial review measured an invalid chat prompt budget"), "measurement-invalid"),
            (ValueError("commercial quote does not match exact candidate source words"), "quote-source-mismatch"),
        ]:
            with self.subTest(expected=expected):
                self.assertEqual(opening_failure_reason(error), expected)

    def test_opening_failure_reason_is_logged_and_original_decision_is_preserved(self):
        segments = make_segments()
        for mode, expected in [("capacity", "context-capacity"),
                               ("json", "response-json"),
                               ("quote", "quote-source-mismatch")]:
            response = whole_answer(segments, (0, 1, 2))
            if mode == "json":
                response = "PRIVATE_RESPONSE_DO_NOT_LOG"
            elif mode == "quote":
                body = json.loads(response)
                body["commercial_quotes"][0]["quote"] = "PRIVATE_RESPONSE_DO_NOT_LOG"
                response = json.dumps(body)
            backend = ReviewBackend(passage=response)
            ads = install_fake_ads(backend)
            if mode == "capacity":
                backend.prompt_context_sizes[WHOLE_PASSAGE_PROMPT] = 1100
                backend.raise_capacity_errors = True
            holds = []
            stream = io.StringIO()
            with redirect_stderr(stream):
                result = recover_source_checked_preroll(
                    ads, backend, segments, [], 300, held_spans=holds,
                )
            with self.subTest(mode=mode):
                self.assertEqual(result, [])
                self.assertTrue(any(span.reason == "boundary-review-unresolved" for span in holds))
                self.assertIsNotNone(decide_ad_outcome(AdAnalysisAudit(held_spans=tuple(holds)), result).keep_whole_reason)
                self.assertIn("reason=" + expected, stream.getvalue())
                self.assertNotIn("PRIVATE_RESPONSE_DO_NOT_LOG", stream.getvalue())
