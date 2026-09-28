"""Podcast worker tests."""
from __future__ import annotations
import ast
import importlib.util
import inspect
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import commercial_recovery as _worker_commercial_recovery
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import edge_recovery as _worker_edge_recovery
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import span_bounds as _worker_span_bounds
from wilted_worker import tail_recovery as _worker_tail_recovery
from wilted_worker import transcript_sources as _worker_transcript_sources
from worker_test_support import *
from worker_test_fake_llm import *
from worker_test_fake_ads import *
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources
from worker_test_audited_adapter_b import AuditedDetectorAdapterMixinB

class AuditedDetectorAdapterTests(AuditedDetectorAdapterMixinB, unittest.TestCase):
    """Exercise retry coverage without loading the archived model or detector."""

    def setUp(self):
        self.segments = [
            FakeSegment(0.0, 10.0, "first segment"),
            FakeSegment(10.0, 20.0, "second segment"),
            FakeSegment(20.0, 30.0, "third segment"),
        ]
        self.patches = [
            mock.patch.object(_WORKER_PATCH_MODULES[name], name, passthrough)
            for name, passthrough in (
                ("recover_unclaimed_explicit_sponsor_reads", _passthrough_detections),
                ("recover_sparse_commercial_reads", _passthrough_detections),
                ("recover_commercial_evidence_reads", _passthrough_detections),
                ("recover_transcript_start_preroll", _passthrough_detections),
                ("recover_transcript_end_postroll", _passthrough_detections),
                # This one reports what the review vouched for alongside them.
                ("resize_oversized_ad_spans", _passthrough_reviewed_detections),
            )
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def ads(self, detector):
        ads = types.ModuleType("wilted.ads")
        ads._AD_DETECT_SYSTEM_PROMPT = "classify"
        ads._AD_DETECT_CORRECTION_PROMPT = "correct"
        ads._AD_DETECT_RESPONSE_FORMAT = {
            "type": "json_object",
            "schema": {
                "type": "object",
                "properties": {"ads": {"type": "array"}},
                "required": ["ads"],
                "additionalProperties": False,
            },
        }

        def parse_ad_response(response, expected_ids):
            parsed = json.loads(response)
            if not isinstance(parsed, dict) or set(parsed) != {"ads"} or not isinstance(parsed["ads"], list):
                raise ValueError("invalid response")
            positions = {segment_id: index for index, segment_id in enumerate(expected_ids)}
            labels = {}
            for item in parsed["ads"]:
                if (not isinstance(item, list) or len(item) != 2 or isinstance(item[0], bool)
                        or not isinstance(item[0], int) or item[0] not in positions
                        or item[0] in labels or item[1] not in {
                            "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"
                        }):
                    raise ValueError("invalid ad entry")
                labels[item[0]] = item[1]
            if list(labels) != sorted(labels, key=positions.__getitem__):
                raise ValueError("out-of-order response")
            return [(segment_id, segment_id in labels, labels.get(segment_id)) for segment_id in expected_ids]

        ads._parse_ad_response = parse_ad_response
        ads._SPONSOR_OPENING_RE = re.compile("sponsor")
        ads._EXPLICIT_HOST_READ_OPENING_RE = re.compile("sponsor")
        ads._SPARSE_PROMO_CUES = ()
        attach_archive_render_helpers(
            ads,
            lambda index, segment: f"[ID {index}] [{segment.start_s:.2f}s - {segment.end_s:.2f}s] ",
        )
        attach_archive_overlap_resolver(ads)
        ads.detect_ads = detector
        # Kept so a test can ask what the worker installed on the module the
        # detector was actually handed.
        self.last_ads = ads
        return ads

    @staticmethod
    def rendered(ids, *, truncated=False):
        lines = [f"[ID {segment_id}] [{segment_id}.0s - {segment_id + 1}.0s] cue" for segment_id in ids]
        if truncated:
            lines.append(" …[TRUNCATED]… ")
        return "\n".join(lines)

    @staticmethod
    def classifier(backend, ids, *, result=None, truncated=False):
        response, _tokens = backend.generate(
            "classify",
            AuditedDetectorAdapterTests.rendered(ids, truncated=truncated),
            response_format=backend._classification_response_format,
        )
        if result is not None:
            return result(response)
        response, _tokens = backend.generate(
            "correct",
            AuditedDetectorAdapterTests.rendered(ids, truncated=truncated),
            response_format=backend._classification_response_format,
        )
        return response

    def analysis(self, detector, responses, *, auto_cover=True, total_seconds=100.0, **kwargs):
        class Backend:
            def __init__(inner):
                inner.responses = iter(responses)
                inner.calls = []

            def generate(inner, prompt, content, *, response_format=None):
                inner.calls.append((prompt, content))
                if prompt == "classify" and content == AuditedDetectorAdapterTests.rendered([0, 1, 2]):
                    return '{"ads":[]}', 1
                return next(inner.responses), 1

        backend = Backend()
        def detector_with_coverage(segments, auditing_backend):
            result = detector(segments, auditing_backend)
            if auto_cover:
                auditing_backend.generate(
                    "classify", self.rendered([0, 1, 2]),
                    response_format=auditing_backend._classification_response_format,
                )
            return result

        return wp.analyze_ad_detections(
            self.ads(detector_with_coverage), backend, self.segments, total_seconds, **kwargs
        ), backend



    def test_exhausted_singleton_is_unresolved_not_a_clean_no_ads_result(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ["not json", "still not json"])
        self.assertEqual(raised.exception.code, "ads-classification-unresolved")

    def test_corrected_and_split_classification_has_resolved_coverage(self):
        def detector(_segments, backend):
            first = self.classifier(backend, [0, 1])
            self.assertEqual(first, "still not json")
            left, _ = backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            right, _ = backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            self.assertEqual(left, '{"ads":[]}')
            self.assertEqual(right, '{"ads":[[1,"sponsor_read"]]}')
            return [FakeAd(10.0, 20.0)]

        analysis, _backend = self.analysis(
            detector,
            ["not json", "still not json", '{"ads":[]}', '{"ads":[[1,"sponsor_read"]]}'],
        )
        self.assertEqual(analysis.audit.unresolved_ids, ())
        self.assertEqual(len(analysis.detections), 1)

    def test_the_recovery_passes_run_in_the_order_the_worker_defines(self):
        # The order is the contract, not an implementation detail: the start
        # and end recoveries nominate spans that the resize pass then bounds,
        # so resizing first would bound spans that do not exist yet. It lives
        # here rather than in the corpus tests because both the live path and
        # the replay reach it only through this entry -- which is the point of
        # there being one entry.
        order = []
        for name in ("recover_unclaimed_explicit_sponsor_reads", "recover_commercial_evidence_reads",
                     "recover_sparse_commercial_reads",
                     "recover_transcript_start_preroll",
                     "recover_transcript_end_postroll", "resize_oversized_ad_spans"):
            def record(*args, _name=name, **_kwargs):
                order.append(_name)
                if _name == "resize_oversized_ad_spans":
                    return args[3], frozenset()
                return args[3]
            patcher = mock.patch.object(_WORKER_PATCH_MODULES[name], name, record)
            patcher.start()
            self.addCleanup(patcher.stop)

        def detector(_segments, backend):
            order.append("detect_ads")
            return []

        self.analysis(detector, [])
        self.assertEqual(order, [
            "detect_ads",
            "recover_unclaimed_explicit_sponsor_reads",
            "recover_commercial_evidence_reads",
            "recover_sparse_commercial_reads",
            "recover_transcript_start_preroll",
            "recover_transcript_end_postroll",
            "resize_oversized_ad_spans",
        ])


    def test_an_independently_failed_window_remains_unresolved(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ["bad", "bad", '{"ads":[]}'])
        self.assertEqual(raised.exception.code, "ads-classification-unresolved")
        self.assertIn("0", str(raised.exception))




    def test_adaptation_over_budget_returns_no_speculative_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        baseline, _backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])

        report, _backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}'],
            experimental_candidates=[baseline.audit.candidates[0]],
            experimental_max_additional_model_calls=1,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIn("budget", report.audit.incomplete_error)
        self.assertEqual(len(_backend.calls), 2, "budget refusal must occur before experimental inference")

    def test_a_run_that_nominates_a_trace_is_marked_near_empty(self):
        # A backend that answers, but answers with almost nothing, is the case
        # that used to be indistinguishable from an ad-free episode. 0.4s on a
        # 100s episode is under both floors, so the audit has to say so -- and
        # say it without changing the cut.
        def detector(_segments, _backend):
            return [FakeAd(10.0, 10.4)]

        analysis, _backend = self.analysis(detector, [])
        self.assertIsNotNone(analysis.audit.near_empty)
        self.assertIn("under both", analysis.audit.near_empty)
        self.assertIsNotNone(wp.serialize_ad_audit(analysis.audit)["nearEmpty"])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in analysis.detections], [(10.0, 10.4)])



    def test_the_near_empty_floors_are_strict(self):
        # The floors sit at the corpus minimum rather than under it, so a
        # nomination exactly on both floors is not near-empty by one epsilon,
        # and a nomination a hair under both is.
        floor_total = wp.NOMINATED_SECONDS_FLOOR / wp.NOMINATED_SHARE_FLOOR

        def on_the_floors(_segments, _backend):
            return [FakeAd(0.0, wp.NOMINATED_SECONDS_FLOOR)]

        at_floor, _backend = self.analysis(on_the_floors, [], total_seconds=floor_total)
        self.assertIsNone(at_floor.audit.near_empty)

        def under_the_floors(_segments, _backend):
            return [FakeAd(0.0, wp.NOMINATED_SECONDS_FLOOR - 1.0)]

        under, _backend = self.analysis(under_the_floors, [], total_seconds=floor_total)
        self.assertIsNotNone(under.audit.near_empty)
        self.assertIn("under both", under.audit.near_empty)
        self.assertIsNotNone(wp.serialize_ad_audit(under.audit)["nearEmpty"])





    def test_invalid_experimental_answer_returns_no_arbitrary_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        baseline, _backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])
        report, _backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}', '{"ad_ids":[99]}'],
            experimental_candidates=[baseline.audit.candidates[0]],
            experimental_max_additional_model_calls=2,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIn("incomplete", report.audit.incomplete_error)
        self.assertEqual(report.audit.experimental_requests, 1)

    def test_experimental_nonfinite_duration_and_oversized_context_fail_before_calls(self):
        class Backend:
            calls = 0

            def generate(self, *_args, **_kwargs):
                self.calls += 1
                raise AssertionError("unsafe experimental input reached inference")

        candidate = wp.AuditCandidate("visible-truncation", (1,), "bounded evidence")
        audit = wp.AdAnalysisAudit(candidates=(candidate,))
        backend = Backend()
        result = wp._experimental_speculative_cuts(audit, backend, self.segments, float("inf"), [candidate], 2)
        self.assertEqual((backend.calls, result.speculative_cuts), (0, ()))

        segments = [FakeSegment(float(i), float(i + 1), f"cue {i}") for i in range(70)]
        candidate = wp.AuditCandidate("visible-truncation", tuple(range(1, 65)), "bounded evidence")
        audit = wp.AdAnalysisAudit(candidates=(candidate,))
        backend = Backend()
        result = wp._experimental_speculative_cuts(audit, backend, segments, 1000.0, [candidate], 2)
        self.assertEqual((backend.calls, result.speculative_cuts), (0, ()))
        self.assertIn("context ID budget", result.incomplete_error)

    def test_duplicate_and_out_of_range_rendered_ids_fail_closed(self):
        for ids in ([0, 0], [99]):
            with self.subTest(ids=ids):
                def detector(_segments, backend, ids=ids):
                    try:
                        backend.generate("classify", self.rendered(ids), response_format=backend._classification_response_format)
                    except wp.WorkerError:
                        pass
                    return []

                with self.assertRaises(wp.WorkerError) as raised:
                    self.analysis(detector, [])
                self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")
