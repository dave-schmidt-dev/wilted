"""Measured whole-cue budgets for commercial nomination and preservation."""

from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import commercial_preservation as _worker_commercial_preservation
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import nomination as _worker_nomination
from wilted_worker import prompts as _worker_prompts
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, wp


def _request_key(system_prompt, user_content, response_format):
    return (
        system_prompt,
        user_content,
        json.dumps(response_format or {}, sort_keys=True),
    )


def _ids_after(user_content, marker):
    line = user_content.partition(marker)[2].splitlines()[0].split(";")[0]
    return tuple(int(value) for value in line.split(", ") if value)


class MeasuredBackend:
    """Deterministic fake whose prompt budget counts bytes and structured overhead."""

    def __init__(
        self,
        *,
        commercial_ids=(),
        mixed_ids=(),
        context_size=4096,
        output_reserve=256,
        follow_up=False,
        nominate_ids=None,
        fail_measure=None,
        invalid_budget=False,
        fail_generate=None,
        forbid_generation=False,
    ):
        self.commercial_ids = tuple(commercial_ids)
        self.mixed_ids = set(mixed_ids)
        self.context_size = context_size
        self.output_reserve = output_reserve
        self.follow_up = follow_up
        self.nominate_ids = tuple(nominate_ids) if nominate_ids is not None else None
        self.fail_measure = fail_measure
        self.invalid_budget = invalid_budget
        self.fail_generate = fail_generate
        self.forbid_generation = forbid_generation
        self.measured = []
        self.generated = []
        self.prepared_requests = []
        self.preservation_calls = 0
        self.overbudget_generations = 0
        self.peak_prompt_tokens = 0

    def _tokens(self, system_prompt, user_content, response_format):
        payload = (
            system_prompt
            + "\n"
            + user_content
            + "\n"
            + json.dumps(response_format or {}, sort_keys=True)
        ).encode("utf-8")
        return max(1, (len(payload) + 1) // 2)

    def measure_prompt(self, system_prompt, user_content, *, response_format=None):
        if self.fail_measure is not None:
            raise self.fail_measure
        if self.invalid_budget:
            return SimpleNamespace(
                token_count=None,
                context_size=self.context_size,
                output_reserve=self.output_reserve,
            )
        tokens = self._tokens(system_prompt, user_content, response_format)
        self.measured.append(
            (_request_key(system_prompt, user_content, response_format), tokens)
        )
        self.peak_prompt_tokens = max(self.peak_prompt_tokens, tokens)
        if tokens + self.output_reserve > self.context_size:
            raise ValueError(
                f"Requested tokens ({tokens + self.output_reserve}) "
                f"exceed context window of {self.context_size}"
            )
        return SimpleNamespace(
            token_count=tokens,
            context_size=self.context_size,
            output_reserve=self.output_reserve,
            request_key=_request_key(system_prompt, user_content, response_format),
        )

    def _labels(self, ids):
        follow_up_request = self.preservation_calls > 1
        labels = {}
        for segment_id in ids:
            if segment_id in self.mixed_ids:
                label = "mixed"
            elif segment_id in self.commercial_ids:
                label = "commercial"
            elif self.follow_up and not follow_up_request:
                label = "commercial"
            else:
                label = "programme"
            labels[str(segment_id)] = label
        return labels

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        if prepared_prompt is not None:
            assert prepared_prompt.request_key == _request_key(system_prompt, user_content, response_format)
            self.prepared_requests.append(prepared_prompt)
        self.generated.append(
            _request_key(system_prompt, user_content, response_format)
        )
        tokens = self._tokens(system_prompt, user_content, response_format)
        if tokens + self.output_reserve > self.context_size:
            self.overbudget_generations += 1
            raise ValueError(
                f"Requested tokens ({tokens + self.output_reserve}) "
                f"exceed context window of {self.context_size}"
            )
        if self.forbid_generation:
            raise AssertionError("unsafe commercial request reached inference")
        if self.fail_generate is not None:
            raise self.fail_generate
        if system_prompt == _worker_prompts.COMMERCIAL_EVIDENCE_NOMINATION_PROMPT:
            supplied = self.nominate_ids or _ids_after(
                user_content, "Observed commercial evidence IDs: "
            )
            return json.dumps({"ad_ids": list(supplied)}), 1
        if system_prompt == _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT:
            self.preservation_calls += 1
            return json.dumps(
                {"labels": self._labels(_ids_after(user_content, "IDs to classify: "))}
            ), 1
        if system_prompt == _worker_prompts.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT:
            return json.dumps({"classification": "programme"}), 1
        if system_prompt == _worker_prompts.COMMERCIAL_PREFIX_ROLE_PROMPT:
            return json.dumps({"classification": "programme"}), 1
        if system_prompt == _worker_prompts.COMMERCIAL_PREFIX_CUE_PROMPT:
            return json.dumps(
                {"labels": self._labels(_ids_after(user_content, "IDs to classify: "))}
            ), 1
        return "{}", 1


def _dense_segments(candidate_ids=(18, 19), count=40):
    segments = []
    for segment_id in range(count):
        text = f"programme cue {segment_id}"
        if segment_id in candidate_ids:
            text = f"MANDATORY-{segment_id} " + "dense synthesized words " * 120
        segments.append(FakeSegment(segment_id * 10.0, segment_id * 10.0 + 10.0, text))
    return segments


class CommercialContextBudgetTests(unittest.TestCase):
    def preserve(
        self, backend, segments, candidate_ids, *, nominate=True, total_seconds=400.0
    ):
        ads = install_fake_ads(backend)
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = _worker_commercial_preservation._commercial_envelope_preserved(
                ads, backend, segments, total_seconds, candidate_ids, nominate=nominate
            )
        return result, stream.getvalue()

    def test_dense_overbudget_request_is_refit_to_fitting_whole_cues(self):
        candidate_ids = (18, 19)
        segments = _dense_segments(candidate_ids)
        backend = MeasuredBackend(commercial_ids=candidate_ids, follow_up=True)

        result, details = self.preserve(backend, segments, candidate_ids)

        self.assertEqual(result, candidate_ids)
        self.assertEqual(details, "")
        self.assertEqual(backend.overbudget_generations, 0)
        self.assertGreater(
            backend.peak_prompt_tokens + backend.output_reserve,
            backend.context_size,
        )
        measured = {key for key, _tokens in backend.measured}
        self.assertTrue(set(backend.generated).issubset(measured))
        self.assertIn(
            _worker_prompts.COMMERCIAL_EVIDENCE_NOMINATION_PROMPT,
            {key[0] for key in backend.generated},
        )
        self.assertGreaterEqual(backend.preservation_calls, 3)
        for segment_id in candidate_ids:
            self.assertTrue(
                any(
                    segments[segment_id].text in key[1]
                    for key in backend.generated
                    if key[0]
                    in {
                        _worker_prompts.COMMERCIAL_EVIDENCE_NOMINATION_PROMPT,
                        _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
                    }
                )
            )
        self.assertEqual(
            (segments[result[0]].start_s, segments[result[-1]].end_s),
            (180.0, 200.0),
        )

    def test_single_cue_that_cannot_fit_is_preserved_without_generation(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "MANDATORY " + "dense synthesized words " * 400),
            FakeSegment(20.0, 30.0, "programme after"),
        ]
        backend = MeasuredBackend(commercial_ids=(1,), forbid_generation=True)

        result, details = self.preserve(
            backend, segments, (1,), nominate=False, total_seconds=100.0
        )

        self.assertIsNone(result)
        self.assertEqual(backend.generated, [])
        self.assertTrue(backend.measured)
        self.assertIn("measured prompt budget", details)
        self.assertIn("4096", details)

    def test_mixed_proposed_cue_is_preserved_after_budgeted_review(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "commercial opening"),
            FakeSegment(20.0, 30.0, "commercial then editorial"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        backend = MeasuredBackend(commercial_ids=(1, 2), mixed_ids={2})

        result, details = self.preserve(
            backend, segments, (1, 2), nominate=False, total_seconds=200.0
        )

        self.assertIsNone(result)
        self.assertIn("intersects the proposed cut at IDs 2", details)
        self.assertEqual(backend.preservation_calls, 1)
        self.assertTrue(
            set(backend.generated).issubset({key for key, _tokens in backend.measured})
        )

    def test_missing_or_invalid_budget_fails_closed_before_generation(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit example dot com and get started"),
            FakeSegment(20.0, 30.0, "programme after"),
        ]
        cases = (
            MeasuredBackend(
                commercial_ids=(1,),
                forbid_generation=True,
                fail_measure=RuntimeError("no budget"),
            ),
            MeasuredBackend(
                commercial_ids=(1,), forbid_generation=True, invalid_budget=True
            ),
        )
        for backend in cases:
            with self.subTest(backend=backend):
                result, details = self.preserve(
                    backend, segments, (1,), nominate=False, total_seconds=100.0
                )
                self.assertIsNone(result)
                self.assertEqual(backend.generated, [])
                self.assertIn("preserved source audio", details)

    def test_wrappers_measure_without_counting_or_spending_model_calls(self):
        inner = MeasuredBackend(context_size=8192, output_reserve=512)
        counting = _worker_ad_audit.CountingBackend(inner)
        counting.measure_prompt("system", "content")
        self.assertEqual((counting.calls, counting.failures), (0, 0))
        self.assertEqual(len(inner.measured), 1)

        exhausted = _worker_nomination._CallBudgetBackend(counting, 0)
        exhausted.measure_prompt("system", "content")
        self.assertEqual((exhausted.calls, counting.calls), (0, 0))
        with self.assertRaises(wp.WorkerError) as raised:
            exhausted.generate("system", "content")
        self.assertEqual(raised.exception.code, "ads-experimental-budget-exhausted")
        self.assertEqual(inner.generated, [])

        budgeted = _worker_nomination._CallBudgetBackend(counting, 1)
        prepared = budgeted.measure_prompt("system", "content")
        self.assertEqual(budgeted.calls, 0)
        budgeted.generate("system", "content", prepared_prompt=prepared)
        self.assertEqual((budgeted.calls, counting.calls), (1, 1))
        self.assertIs(inner.prepared_requests[-1], prepared)

    def test_audit_wrapper_measures_the_forwarded_prompt_without_a_model_call(self):
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        backend = _worker_ad_audit.AuditingBackend(
            llm, ads, 5, prompt_overrides={"original prompt": "forwarded prompt"}
        )

        budget = backend.measure_prompt("original prompt", "synthetic content")

        self.assertGreater(budget.token_count, 0)
        self.assertEqual(backend.calls, 0)
        self.assertEqual(llm.requests, [])
        self.assertEqual(llm.measured_prompts[-1][0], "forwarded prompt")
        backend.generate("original prompt", "synthetic content", prepared_prompt=budget)
        self.assertEqual(backend.calls, 1)
        self.assertIs(llm.prepared_prompts[-1], budget)

    def test_nonmaximum_conflict_budget_is_checked_before_any_inference(self):
        class NonmaximumBudget(MeasuredBackend):
            def _tokens(self, prompt, content, response_format):
                extra = 8000 if (prompt == _worker_prompts.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT
                                 and content.startswith("Candidate ID to resolve: 1\n")) else 0
                return super()._tokens(prompt, content, response_format) + extra
            def _labels(self, ids):
                result = super()._labels(ids)
                if 1 in ids:
                    result["1"] = "programme"
                return result
        segments = [FakeSegment(0, 10, "programme before"),
                    FakeSegment(10, 20, "visit example dot com and get started"),
                    FakeSegment(20, 30, "commercial ending"),
                    FakeSegment(30, 40, "programme after")]
        backend = NonmaximumBudget(commercial_ids=(1, 2))
        result, detail = self.preserve(backend, segments, (1, 2), nominate=False, total_seconds=200)
        self.assertIsNone(result)
        self.assertIn("measured prompt budget", detail)
        self.assertEqual(backend.generated, [])

    def test_shorter_prefix_budget_is_checked_before_any_inference(self):
        class ShortPrefixBudget(MeasuredBackend):
            def _tokens(self, prompt, content, response_format):
                extra = 8000 if (prompt == _worker_prompts.COMMERCIAL_PREFIX_ROLE_PROMPT
                                 and content.startswith("Prefix IDs: 1;")) else 0
                return super()._tokens(prompt, content, response_format) + extra
            def _labels(self, ids):
                result = super()._labels(ids)
                if 1 in ids:
                    result["1"] = "programme"
                return result
        segments = [FakeSegment(0, 10, "programme before"),
                    FakeSegment(10, 20, "commercial setup"),
                    FakeSegment(20, 30, "commercial continuation"),
                    FakeSegment(30, 40, "visit example dot com and get started"),
                    FakeSegment(40, 50, "programme after")]
        backend = ShortPrefixBudget(commercial_ids=(1, 2, 3))
        ads = install_fake_ads(backend)
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = _worker_commercial_preservation._commercial_envelope_preserved(
                ads, backend, segments, 200, (1, 2, 3), nominate=False, prefix_evidence_id=3)
        self.assertIsNone(result)
        self.assertIn("measured prompt budget", stream.getvalue())
        self.assertEqual(backend.generated, [])

    def test_real_generation_failure_returns_original_detections_unchanged(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit example dot com and get started"),
            FakeSegment(20.0, 30.0, "programme after"),
        ]
        original = [FakeAd(0.0, 10.0, label="sponsor_read")]
        backend = MeasuredBackend(
            commercial_ids=(1,),
            fail_generate=ValueError(
                "Requested tokens (5000) exceed context window of 4096"
            ),
        )
        ads = install_fake_ads(backend)
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = _worker_commercial_seeds.recover_commercial_evidence_reads(
                ads, backend, segments, original, 100.0
            )

        self.assertEqual(result, original)
        self.assertIn("commercial envelope preserved source audio", stream.getvalue())
        self.assertEqual(backend.overbudget_generations, 0)


if __name__ == "__main__":
    unittest.main()
