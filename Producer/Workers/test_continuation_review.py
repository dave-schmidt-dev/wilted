"""Independent regression coverage for adjacent commercial extensions."""
from __future__ import annotations

import json
import unittest
from types import SimpleNamespace

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_outcome as _worker_ad_outcome
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import continuation_review as _worker_continuation_review
from wilted_worker import prompts as _worker_prompts
from wilted_worker.boundary_review import reject_programme_conflicts
from wilted_worker.continuation_review import verify_adjacent_commercial_extension
from wilted_worker.constants import COMMERCIAL_PRESERVATION_FLANK_IDS
from wilted_worker.span_bounds import recover_adjacent_ad_pod_continuations
from worker_test_support import load_runtime_ads


class _Ads:
    @staticmethod
    def _segment_prefix(segment_id, _segment):
        return f"[ID {segment_id}] "

    @staticmethod
    def _id_response_format(field, ids):
        return {"field": field, "ids": list(ids)}

    @staticmethod
    def _generate_constrained_response(backend, prompt, content, response_format):
        return backend.generate(prompt, content, response_format=response_format)

    @staticmethod
    def AdSegment(start_s, end_s, confidence, label, *, kinds=()):
        return SimpleNamespace(
            start_s=start_s, end_s=end_s, confidence=confidence,
            label=label, kinds=tuple(kinds),
        )


class _Backend:
    """Measured synthetic backend for the focused proof and orchestration paths."""

    def __init__(self, labels=None, *, nomination=3, reply=None, overflow=False):
        self.labels = dict(labels or {})
        self.nomination = nomination
        self.reply = reply
        self.overflow = overflow
        self.measurements = []
        self.generations = []

    def measure_prompt(self, prompt, content, *, response_format):
        request = (prompt, content, response_format)
        self.measurements.append(request)
        if self.overflow:
            return (200, 100, 32)
        return (max(1, len(content) // 4), 100_000, 32)

    def generate(self, prompt, content, *, response_format, prepared_prompt=None):
        self.generations.append((prompt, content, response_format, prepared_prompt))
        if prompt == _worker_prompts.AD_POD_CONTINUATION_PROMPT:
            return json.dumps({"program_start_id": self.nomination}), 1
        if self.reply is not None:
            return self.reply, 1
        ids = response_format["schema"]["properties"]["labels"]["properties"]
        labels = {
            segment_id: self.labels.get(int(segment_id), "commercial")
            for segment_id in ids
        }
        return json.dumps({"labels": labels}), 1


def _segments(*, middle_text=None):
    texts = [
        "programme before the sponsor break",
        "Sponsor message introduces the product.",
        middle_text or "Use the offer at the sponsor's destination.",
        "The programme resumes with the interview.",
        "The host continues the discussion.",
        "Another programme cue follows.",
    ]
    return [
        SimpleNamespace(start_s=index * 10.0, end_s=(index + 1) * 10.0, text=text)
        for index, text in enumerate(texts)
    ]


def _core_and_unrelated():
    core = SimpleNamespace(
        start_s=0.0, end_s=10.0, confidence=0.83,
        label="sponsor_read", kinds=("paid", "host_read"),
    )
    unrelated = SimpleNamespace(
        start_s=70.0, end_s=80.0, confidence=0.61,
        label="produced_spot", kinds=("paid",),
    )
    return core, unrelated


class ContinuationReviewTests(unittest.TestCase):
    def test_unparseable_boundary_reply_reports_false_without_holds(self):
        held = []
        recorded = _worker_continuation_review._record_parseable_boundaries(
            "{", (1, 2), _segments(), 300.0, held,
        )
        self.assertIs(recorded, False)
        self.assertEqual(held, [])

    def test_context_programme_label_is_recorded_without_vetoing_commercial_candidate(self):
        backend = _Backend({3: "programme"})
        held = []

        accepted = verify_adjacent_commercial_extension(
            _Ads(), backend, _segments(), 300.0, (1, 2), held
        )

        self.assertTrue(accepted)
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held], [
            (30.0, 40.0, "programme-boundary"),
        ])
        self.assertEqual(len(backend.generations), 1)
        self.assertEqual(backend.measurements[-1][:3], backend.generations[-1][:3])
        self.assertIn("[ID 0] programme before the sponsor break", backend.generations[0][1])
        self.assertIn("[ID 3] The programme resumes with the interview.", backend.generations[0][1])

    def test_programme_or_mixed_inside_candidate_vetoes_extension(self):
        for label in ("programme", "mixed"):
            with self.subTest(label=label):
                backend = _Backend({2: label})
                held = []

                accepted = verify_adjacent_commercial_extension(
                    _Ads(), backend, _segments(), 300.0, (1, 2), held
                )

                self.assertFalse(accepted)
                self.assertIn((20.0, 30.0, "programme-boundary"), [
                    (span.start_s, span.end_s, span.reason) for span in held
                ])
                self.assertEqual(len(backend.generations), 1)

    def test_complete_candidate_and_both_flanks_are_measured_and_generated(self):
        middle = "Distinctive middle words stay complete. " * 90
        backend = _Backend({3: "programme"})
        segments = _segments(middle_text=middle)

        accepted = verify_adjacent_commercial_extension(
            _Ads(), backend, segments, 300.0, (1, 2), []
        )

        self.assertTrue(accepted)
        measured_prompt, measured_content, measured_schema = backend.measurements[-1]
        generated_prompt, generated_content, generated_schema, prepared = backend.generations[-1]
        self.assertEqual((measured_prompt, measured_content, measured_schema),
                         (generated_prompt, generated_content, generated_schema))
        self.assertIsNotNone(prepared)
        expected_ids = tuple(
            segment_id for segment_id in range(6)
            if 1 - COMMERCIAL_PRESERVATION_FLANK_IDS
            <= segment_id <= 2 + COMMERCIAL_PRESERVATION_FLANK_IDS
        )
        self.assertEqual(
            tuple(map(int, measured_schema["schema"]["properties"]["labels"]["required"])),
            expected_ids,
        )
        self.assertIn("[ID 0] programme before the sponsor break", generated_content)
        self.assertIn("[ID 1] Sponsor message introduces the product.", generated_content)
        self.assertIn("[ID 2] " + middle, generated_content)
        self.assertIn("[ID 3] The programme resumes with the interview.", generated_content)
        self.assertIn("[ID 5] Another programme cue follows.", generated_content)

    def test_positive_context_labels_survive_malformed_reply_and_unhashable_label(self):
        response = json.dumps({
            "labels": {
                "0": "commercial", "1": [], "2": "commercial",
                "3": "mixed", "4": "commercial", "5": "commercial",
            },
            "unexpected": True,
        })
        backend = _Backend(reply=response)
        held = []

        accepted = verify_adjacent_commercial_extension(
            _Ads(), backend, _segments(), 300.0, (1, 2), held
        )

        self.assertFalse(accepted)
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held], [
            (30.0, 40.0, "programme-boundary"),
        ])

    def test_unrequested_far_positive_in_invalid_reply_is_still_recorded(self):
        response = json.dumps({
            "labels": {
                "0": "commercial", "1": "commercial", "2": "commercial",
                "3": "commercial", "4": "commercial", "5": "mixed",
            },
            "unexpected": True,
        })
        backend = _Backend(reply=response)
        held = []

        accepted = verify_adjacent_commercial_extension(
            _Ads(), backend, _segments(), 300.0, (1, 2), held
        )

        requested_ids = backend.generations[0][2]["schema"]["properties"]["labels"]["required"]
        self.assertFalse(accepted)
        self.assertNotIn("5", requested_ids)
        self.assertIn("[ID 5] Another programme cue follows.", backend.generations[0][1])
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held], [
            (50.0, 60.0, "programme-boundary"),
        ])

    def test_partial_reply_and_unknown_label_skip_optional_proof(self):
        replies = (
            '{"labels":{"1":"commercial","3":"programme"}}',
            '{"labels":{"1":"commercial","2":"editorial","3":"mixed",'
            '"0":"commercial","4":"commercial","5":"commercial"}}',
        )
        for response in replies:
            with self.subTest(response=response):
                backend = _Backend(reply=response)
                held = []

                accepted = verify_adjacent_commercial_extension(
                    _Ads(), backend, _segments(), 300.0, (1, 2), held
                )

                self.assertFalse(accepted)
                self.assertIn((30.0, 40.0, "programme-boundary"), [
                    (span.start_s, span.end_s, span.reason) for span in held
                ])

    def test_measurement_overflow_skips_generation(self):
        backend = _Backend(overflow=True)

        accepted = verify_adjacent_commercial_extension(
            _Ads(), backend, _segments(), 300.0, (1, 2), []
        )

        self.assertFalse(accepted)
        self.assertGreaterEqual(len(backend.measurements), 1)
        self.assertEqual(backend.generations, [])

    def test_real_continuation_runner_requires_proof_and_preserves_other_cuts(self):
        for rejected_label in ("programme", "mixed"):
            with self.subTest(label=rejected_label):
                core, unrelated = _core_and_unrelated()
                backend = _Backend({2: rejected_label, 3: "programme"})
                held = []

                recovered = recover_adjacent_ad_pod_continuations(
                    _Ads(), backend, _segments(), [core, unrelated], 300.0, held
                )

                self.assertEqual(recovered, [core, unrelated])
                self.assertEqual((core.start_s, core.end_s), (0.0, 10.0))
                self.assertIn((20.0, 30.0, "programme-boundary"), [
                    (span.start_s, span.end_s, span.reason) for span in held
                ])
                self.assertFalse(any(span.reason in {
                    "pod-continuation-bracket", "total-share-ceiling"
                } for span in held))
                self.assertEqual(sum(call[0] == _worker_prompts.AD_POD_CONTINUATION_PROMPT
                                     for call in backend.generations), 1)
                self.assertEqual(sum(call[0] != _worker_prompts.AD_POD_CONTINUATION_PROMPT
                                     for call in backend.generations), 1)

    def test_malformed_optional_proof_preserves_existing_cuts_without_new_holds(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend(reply="not strict JSON")
        held = []

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, held
        )

        self.assertEqual(recovered, [core, unrelated])
        self.assertEqual(held, [])
        self.assertEqual(len(backend.generations), 2)
        self.assertFalse(any(call[0] not in {
            _worker_prompts.AD_POD_CONTINUATION_PROMPT,
            _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
        } for call in backend.generations))

    def test_commercial_proof_extends_only_proposed_cut_and_preserves_metadata(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend({3: "programme"})
        held = []

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, held
        )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [
            (0.0, 30.0), (70.0, 80.0),
        ])
        self.assertEqual((recovered[0].confidence, recovered[0].label, recovered[0].kinds),
                         (core.confidence, core.label, core.kinds))
        self.assertIs(recovered[1], unrelated)
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held], [
            (30.0, 40.0, "programme-boundary"),
        ])

    def test_positive_conflict_still_uses_whole_original_policy(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend({0: "programme", 3: "programme"})
        held = []

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, held
        )
        conflict_checked = reject_programme_conflicts(recovered, held)
        outcome = _worker_ad_outcome.decide_ad_outcome(
            _worker_ad_audit.AdAnalysisAudit(held_spans=tuple(held)), conflict_checked
        )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(0.0, 30.0), (70.0, 80.0)])
        self.assertEqual(conflict_checked, [])
        self.assertIn("programme-boundary-conflict", [span.reason for span in held])
        self.assertEqual(outcome.keep_whole_reason, _worker_ad_outcome.UNRESOLVED_SPANS_REASON)

    def test_incoming_far_positive_holds_survive_and_still_reject_overlapping_core(self):
        segments = [
            SimpleNamespace(start_s=index * 10.0, end_s=(index + 1) * 10.0,
                            text=f"cue {index}")
            for index in range(64)
        ]
        core = SimpleNamespace(
            start_s=0.0, end_s=100.0, confidence=0.83,
            label="sponsor_read", kinds=("paid", "host_read"),
        )
        incoming = [
            SimpleNamespace(start_s=20.0, end_s=30.0, reason="programme-boundary",
                            classification="programme"),
            SimpleNamespace(start_s=30.0, end_s=40.0, reason="programme-boundary",
                            classification="mixed"),
        ]
        held = list(incoming)
        backend = _Backend(nomination=12)

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, segments, [core], 3000.0, held
        )
        conflict_checked = reject_programme_conflicts(recovered, held)
        outcome = _worker_ad_outcome.decide_ad_outcome(
            _worker_ad_audit.AdAnalysisAudit(held_spans=tuple(held)), conflict_checked
        )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(0.0, 120.0)])
        self.assertEqual(held[:2], incoming)
        self.assertIs(held[0], incoming[0])
        self.assertIs(held[1], incoming[1])
        requested_ids = backend.generations[1][2]["schema"]["properties"]["labels"]["required"]
        self.assertEqual(requested_ids, [str(index) for index in range(8, 14)])
        self.assertEqual(conflict_checked, [])
        self.assertIn("programme-boundary-conflict", [span.reason for span in held])
        self.assertEqual(outcome.keep_whole_reason, _worker_ad_outcome.UNRESOLVED_SPANS_REASON)

    def test_incorrect_nomination_is_not_a_hold_and_independent_proof_decides(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend(nomination=2)
        held = []

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, held
        )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [
            (0.0, 20.0), (70.0, 80.0),
        ])
        self.assertEqual(held, [])
        self.assertEqual(sum(call[0] == _worker_prompts.AD_POD_CONTINUATION_PROMPT
                             for call in backend.generations), 1)
        self.assertEqual(sum(call[0] != _worker_prompts.AD_POD_CONTINUATION_PROMPT
                             for call in backend.generations), 1)

    def test_existing_programme_barrier_skips_independent_review(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend()
        held = [SimpleNamespace(start_s=20.0, end_s=30.0, reason="programme-boundary")]

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, held
        )

        self.assertEqual(recovered, [core, unrelated])
        self.assertEqual(len(backend.generations), 1)
        self.assertEqual(backend.generations[0][0], _worker_prompts.AD_POD_CONTINUATION_PROMPT)
        self.assertEqual(backend.measurements, [])

    def test_no_proposal_makes_no_optional_review_call(self):
        core, unrelated = _core_and_unrelated()
        backend = _Backend(nomination=-1)

        recovered = recover_adjacent_ad_pod_continuations(
            _Ads(), backend, _segments(), [core, unrelated], 300.0, []
        )

        self.assertEqual(recovered, [core, unrelated])
        self.assertEqual(len(backend.generations), 1)
        self.assertEqual(backend.generations[0][0], _worker_prompts.AD_POD_CONTINUATION_PROMPT)
        self.assertEqual(backend.measurements, [])

    @classmethod
    def setUpClass(cls):
        cls.archive_ads, cls.ArchiveSegment = load_runtime_ads()

    def test_self_promotion_variants_use_existing_override_route(self):
        candidate_roles = (
            (False, "own_promo", "programme", False),
            (True, "own_promo", "commercial", True),
            (False, "editorial", "mixed", False),
            (True, "editorial", "mixed", False),
        )
        overrides = _worker_ad_removal.self_promotion_prompt_overrides(self.archive_ads)
        original = _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT
        variant = _worker_prompts.SELF_PROMOTION_COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT

        for enabled, role, expected_label, expected_accept in candidate_roles:
            with self.subTest(enabled=enabled, role=role):
                class Inner:
                    def __init__(self):
                        self.calls = []

                    def measure_prompt(self, prompt, content, *, response_format=None):
                        self.calls.append(("measure", prompt, content, response_format))
                        return (20, 4096, 32)

                    def generate(self, prompt, content, *, response_format=None, prepared_prompt=None):
                        self.calls.append(("generate", prompt, content, response_format))
                        ids = response_format["schema"]["properties"]["labels"]["properties"]
                        candidate_label = (
                            "mixed" if role == "editorial"
                            else "commercial" if prompt == variant
                            else "programme"
                        )
                        labels = {
                            segment_id: (candidate_label if int(segment_id) == 1 else "commercial")
                            for segment_id in ids
                        }
                        return json.dumps({"labels": labels}), 1

                inner = Inner()
                policy_overrides = overrides if enabled else None
                backend = _worker_ad_audit.AuditingBackend(
                    inner, self.archive_ads, segment_count=6,
                    prompt_overrides=policy_overrides,
                )
                segments = [
                    self.ArchiveSegment(index * 10.0, (index + 1) * 10.0, text)
                    for index, text in enumerate((
                        "programme before", "own promotion cue", "offer details",
                        "programme resumes", "more programme", "final cue",
                    ))
                ]
                held = []

                accepted = verify_adjacent_commercial_extension(
                    self.archive_ads, backend, segments, 300.0, (1, 2), held
                )

                self.assertEqual(accepted, expected_accept)
                generate_calls = [call for call in inner.calls if call[0] == "generate"]
                expected_prompt = variant if enabled else original
                self.assertEqual(len(generate_calls), 1)
                self.assertEqual(generate_calls[0][1], expected_prompt)
                self.assertEqual(backend.commercial_review_states[1], expected_label)
                if not expected_accept:
                    self.assertIn((10.0, 20.0, "programme-boundary"), [
                        (span.start_s, span.end_s, span.reason) for span in held
                    ])


if __name__ == "__main__":
    unittest.main()
