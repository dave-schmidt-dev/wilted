"""Tests for self-promotion-aware prompt variants and AuditingBackend overrides."""
from __future__ import annotations

import contextlib
import json
import re
import types
import unittest
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import prompts as _worker_prompts
from wilted_worker import reporting as _worker_reporting
from worker_test_support import *  # noqa: F403
from worker_test_support import load_runtime_ads, worker_namespaces, wp


class RecordingInnerBackend:
    """Inner backend recording (prompt, content, response_format)."""

    def __init__(self, response: str = "{}"):
        self.response = response
        self.calls: list[tuple[str, str, dict | None]] = []

    def generate(self, prompt: str, content: str, *, response_format=None):
        self.calls.append((prompt, content, response_format))
        return self.response, 1


class SelfPromotionPromptsTests(unittest.TestCase):
    """Test self-promotion prompt variants, AuditingBackend overrides, and ad_removal integration."""

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    def prompt_pairs(self):
        """Return the eight (original, variant) prompt pairs."""
        return [
            (self.ads._AD_DETECT_SYSTEM_PROMPT, _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT),
            (self.ads._AD_DETECT_CORRECTION_PROMPT, _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT),
            (self.ads._SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT, _worker_prompts.SELF_PROMOTION_SPARSE_CONTENT_VERIFY_PROMPT),
            (_worker_prompts.OVERSIZED_SPAN_RESCAN_PROMPT, _worker_prompts.SELF_PROMOTION_OVERSIZED_SPAN_RESCAN_PROMPT),
            (_worker_prompts.POSTROLL_PROGRAM_END_PROMPT, _worker_prompts.SELF_PROMOTION_POSTROLL_PROGRAM_END_PROMPT),
            (_worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT, _worker_prompts.SELF_PROMOTION_COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT),
            (_worker_prompts.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT, _worker_prompts.SELF_PROMOTION_COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT),
            (_worker_prompts.COMMERCIAL_PREFIX_ROLE_PROMPT, _worker_prompts.SELF_PROMOTION_COMMERCIAL_PREFIX_ROLE_PROMPT),
        ]

    def test_every_variant_ends_with_original_return_only_suffix_and_differs(self):
        for original, variant in self.prompt_pairs():
            with self.subTest(original_prefix=original[:40]):
                self.assertIn("Return only", original)
                return_only_suffix = original[original.index("Return only"):]
                self.assertTrue(
                    variant.endswith(return_only_suffix),
                    f"Variant does not end with expected suffix:\n{return_only_suffix!r}\n\nVariant:\n{variant!r}",
                )
                self.assertNotEqual(variant, original)

        # The two classifier variants must differ from each other
        self.assertNotEqual(
            _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT,
            _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT,
        )
        self.assertTrue(
            _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT.startswith("Your previous response was invalid")
        )

    def test_content_and_commercial_stances_in_variants(self):
        key_variants = [
            _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT,
            _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT,
            _worker_prompts.SELF_PROMOTION_OVERSIZED_SPAN_RESCAN_PROMPT,
            _worker_prompts.SELF_PROMOTION_COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            _worker_prompts.SELF_PROMOTION_COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
            _worker_prompts.SELF_PROMOTION_COMMERCIAL_PREFIX_ROLE_PROMPT,
        ]
        commercial_phrases = ["roll call", "ad-free", "Patreon"]
        programme_phrases = ["title", "tagline", "episode description"]

        for variant in key_variants:
            with self.subTest(variant_prefix=variant[:40]):
                for phrase in commercial_phrases:
                    self.assertIn(
                        phrase,
                        variant,
                        f"Expected commercial phrase {phrase!r} not found in variant:\n{variant}",
                    )
                for phrase in programme_phrases:
                    self.assertIn(
                        phrase,
                        variant,
                        f"Expected programme phrase {phrase!r} not found in variant:\n{variant}",
                    )

        # Sparse content verify stance: seed inside promotion block, programme resumes
        self.assertIn("seed may sit inside", _worker_prompts.SELF_PROMOTION_SPARSE_CONTENT_VERIFY_PROMPT)
        self.assertIn("programme discussion resumes", _worker_prompts.SELF_PROMOTION_SPARSE_CONTENT_VERIFY_PROMPT)

        # Postroll variant stance: sign-off/credits stay programme, closing plug is advertising
        self.assertIn("sign-off", _worker_prompts.SELF_PROMOTION_POSTROLL_PROGRAM_END_PROMPT)
        self.assertIn("credits", _worker_prompts.SELF_PROMOTION_POSTROLL_PROGRAM_END_PROMPT)
        self.assertIn("closing plug", _worker_prompts.SELF_PROMOTION_POSTROLL_PROGRAM_END_PROMPT)

    def test_no_variant_trips_audit_contract_guard(self):
        overrides = _worker_ad_removal.self_promotion_prompt_overrides(self.ads)
        content = "[ID 0] first\n[ID 1] second\n[ID 2] third\n"
        for _, variant in self.prompt_pairs():
            with self.subTest(variant_prefix=variant[:40]):
                inner = RecordingInnerBackend()
                backend = _worker_ad_audit.AuditingBackend(inner, self.ads, prompt_overrides=overrides)
                try:
                    backend.generate(variant, content, response_format=None)
                except wp.WorkerError as error:
                    self.fail(f"Variant tripped audit contract guard: {error}")
                except Exception:
                    pass
                self.assertEqual(backend.contract_errors, [])

    def test_overrides_with_real_archive_has_eight_entries_and_forwards_variants(self):
        overrides = _worker_ad_removal.self_promotion_prompt_overrides(self.ads)
        self.assertEqual(len(overrides), 8)

        # A backend built with them forwards each original as its variant
        for original, expected_variant in self.prompt_pairs():
            with self.subTest(original_prefix=original[:40]):
                inner = RecordingInnerBackend()
                backend = _worker_ad_audit.AuditingBackend(inner, self.ads, segment_count=10, prompt_overrides=overrides)
                is_clf = original in (self.ads._AD_DETECT_SYSTEM_PROMPT, self.ads._AD_DETECT_CORRECTION_PROMPT)
                fmt = self.ads._AD_DETECT_RESPONSE_FORMAT if is_clf else None
                inner.response = '{"ads": []}' if is_clf else "{}"
                content = "[ID 0] first\n[ID 1] second\n"
                backend.generate(original, content, response_format=fmt)
                self.assertEqual(len(inner.calls), 1)
                self.assertEqual(inner.calls[0][0], expected_variant)

        # Classification requests still create lineages
        inner = RecordingInnerBackend('{"ads": []}')
        backend = _worker_ad_audit.AuditingBackend(inner, self.ads, segment_count=5, prompt_overrides=overrides)
        backend.generate(
            self.ads._AD_DETECT_SYSTEM_PROMPT,
            "[ID 0] first\n[ID 1] second\n",
            response_format=self.ads._AD_DETECT_RESPONSE_FORMAT,
        )
        self.assertEqual(len(backend.lineages), 1)
        self.assertEqual(backend.lineages[0].ids, (0, 1))
        self.assertEqual(backend.contract_errors, [])

        # Commercial preservation requests still update commercial_review_states
        inner_pres = RecordingInnerBackend('{"labels": {"1": "commercial", "2": "programme"}}')
        backend_pres = _worker_ad_audit.AuditingBackend(inner_pres, self.ads, segment_count=5, prompt_overrides=overrides)
        pres_schema = {
            "type": "json_object",
            "schema": {"properties": {"labels": {"required": ["1", "2"]}}},
        }
        backend_pres.generate(
            _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            "[ID 1] one\n[ID 2] two\n",
            response_format=pres_schema,
        )
        self.assertEqual(backend_pres.commercial_review_states.get(1), "commercial")
        self.assertEqual(backend_pres.commercial_review_states.get(2), "programme")

        # Commercial conflict requests still update commercial_review_states
        inner_conf = RecordingInnerBackend('{"classification": "commercial"}')
        backend_conf = _worker_ad_audit.AuditingBackend(inner_conf, self.ads, segment_count=5, prompt_overrides=overrides)
        backend_conf.generate(
            _worker_prompts.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
            "Candidate ID to resolve: 3\n[ID 3] candidate\n",
            response_format={"type": "json_object"},
        )
        self.assertEqual(backend_conf.commercial_review_states.get(3), "commercial")

    def test_with_no_overrides_inner_backend_receives_original_prompts(self):
        for original, _ in self.prompt_pairs():
            with self.subTest(original_prefix=original[:40]):
                inner = RecordingInnerBackend()
                backend = _worker_ad_audit.AuditingBackend(inner, self.ads, segment_count=10, prompt_overrides=None)
                self.assertFalse(backend.removes_self_promotion)
                is_clf = original in (self.ads._AD_DETECT_SYSTEM_PROMPT, self.ads._AD_DETECT_CORRECTION_PROMPT)
                fmt = self.ads._AD_DETECT_RESPONSE_FORMAT if is_clf else None
                inner.response = '{"ads": []}' if is_clf else "{}"
                content = "[ID 0] first\n[ID 1] second\n"
                backend.generate(original, content, response_format=fmt)
                self.assertEqual(len(inner.calls), 1)
                self.assertEqual(inner.calls[0][0], original)

    def test_fake_ads_module_missing_archive_prompts_yields_only_five_worker_entries(self):
        fake_ads = types.ModuleType("fake.ads")
        overrides = _worker_ad_removal.self_promotion_prompt_overrides(fake_ads)
        self.assertEqual(len(overrides), 5)
        expected_worker_prompts = {
            _worker_prompts.OVERSIZED_SPAN_RESCAN_PROMPT,
            _worker_prompts.POSTROLL_PROGRAM_END_PROMPT,
            _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            _worker_prompts.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
            _worker_prompts.COMMERCIAL_PREFIX_ROLE_PROMPT,
        }
        self.assertEqual(set(overrides.keys()), expected_worker_prompts)

    def test_analyze_ad_detections_mismatched_auditing_backend_raises_worker_error(self):
        cues = [self.Segment(0.0, 10.0, "test segment")]

        # Mismatch 1: backend has no overrides, but remove_self_promotion=True
        inner_1 = RecordingInnerBackend()
        backend_no_overrides = _worker_ad_audit.AuditingBackend(inner_1, self.ads, prompt_overrides=None)
        with self.assertRaises(wp.WorkerError) as ctx_1:
            _worker_ad_removal.analyze_ad_detections(
                self.ads, backend_no_overrides, cues, 10.0, remove_self_promotion=True
            )
        self.assertEqual(ctx_1.exception.code, "ads-audit-contract-unavailable")
        self.assertEqual(
            str(ctx_1.exception),
            "audit backend prompt mode does not match the self-promotion flag",
        )
        self.assertEqual(len(inner_1.calls), 0)

        # Mismatch 2: backend has overrides, but remove_self_promotion=False
        inner_2 = RecordingInnerBackend()
        overrides = _worker_ad_removal.self_promotion_prompt_overrides(self.ads)
        backend_with_overrides = _worker_ad_audit.AuditingBackend(inner_2, self.ads, prompt_overrides=overrides)
        with self.assertRaises(wp.WorkerError) as ctx_2:
            _worker_ad_removal.analyze_ad_detections(
                self.ads, backend_with_overrides, cues, 10.0, remove_self_promotion=False
            )
        self.assertEqual(ctx_2.exception.code, "ads-audit-contract-unavailable")
        self.assertEqual(
            str(ctx_2.exception),
            "audit backend prompt mode does not match the self-promotion flag",
        )
        self.assertEqual(len(inner_2.calls), 0)

    def test_detect_and_cut_prompt_delivery_by_self_promotion_flag(self):
        segments = [self.Segment(0.0, 10.0, "content passage")]
        captured_prompts: dict[str, list[str]] = {"on": [], "off": []}
        expected_originals: dict[str, list[str]] = {"on": [], "off": []}

        for flag_on in (True, False):
            mode = "on" if flag_on else "off"
            request = {"removeSelfPromotion": True} if flag_on else {}

            class MockInnerModelBackend:
                def __init__(self):
                    self.calls = []

                def generate(self, prompt, content, *, response_format=None):
                    self.calls.append((prompt, content, response_format))
                    captured_prompts[mode].append(prompt)
                    return '{"ads": []}', 1

                def load(self):
                    pass

                def close(self):
                    pass

            inner_model = MockInnerModelBackend()
            fake_llm = types.ModuleType("wilted.llm")
            fake_llm.DEFAULT_GGUF_MODEL = "test.gguf"
            fake_llm.create_backend = lambda kind, model: inner_model

            def mock_analyze(ads_module, backend, segs, total, **kwargs):
                expected_originals[mode].append(ads_module._AD_DETECT_SYSTEM_PROMPT)
                backend.generate(
                    ads_module._AD_DETECT_SYSTEM_PROMPT,
                    "[ID 0] content passage\n",
                    response_format=ads_module._AD_DETECT_RESPONSE_FORMAT,
                )
                return wp.AdAnalysis((), wp.AdAnalysisAudit())

            with mock.patch("wilted.llm.create_backend", fake_llm.create_backend), \
                 mock.patch.object(_worker_ad_removal, "analyze_ad_detections", mock_analyze), \
                 mock.patch.object(_worker_cue_timing, "probe_duration", return_value=10.0):
                wp.detect_and_cut(
                    request,
                    Path("test.mp3"),
                    [],
                    segments,
                    model_lock=contextlib.nullcontext(),
                )

        self.assertEqual(len(captured_prompts["on"]), 1)
        self.assertEqual(captured_prompts["on"][0], _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT)

        self.assertEqual(len(captured_prompts["off"]), 1)
        self.assertEqual(captured_prompts["off"][0], expected_originals["off"][0])


if __name__ == "__main__":
    unittest.main()
