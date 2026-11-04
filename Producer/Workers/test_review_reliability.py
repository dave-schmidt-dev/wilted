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
from wilted_worker.ad_audit import AdAnalysisAudit, AuditingBackend
from wilted_worker.ad_outcome import decide_ad_outcome
from wilted_worker.commercial_seeds import _constrained_id
from wilted_worker.preroll_passage_review import recover_source_checked_preroll
from wilted_worker.prompts import POSTROLL_PROGRAM_END_PROMPT, WHOLE_PASSAGE_PROMPT
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
