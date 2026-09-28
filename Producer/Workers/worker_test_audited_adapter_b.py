"""Test mixin preserving the original unittest class identity."""
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

class AuditedDetectorAdapterMixinB:
    def test_the_render_budget_is_installed_before_the_classifier_runs(self):
        # An install that runs after `detect_ads` would fix nothing: the
        # classification requests are rendered inside it.
        marked = []

        def detector(_segments, _backend):
            marked.append(
                getattr(
                    self.last_ads._render_segments_bounded, wp._PROPORTIONAL_RENDER_MARKER, False
                )
            )
            return []

        self.analysis(detector, [])
        self.assertEqual(marked, [True])

    def test_overlap_resolver_is_installed_before_the_archive_detector_runs(self):
        observed = []

        def detector(segments, _backend):
            resolver = self.last_ads._resolve_overlaps  # noqa: SLF001
            observed.append(getattr(resolver, wp._CONTEXT_AWARE_OVERLAP_MARKER, False))
            runs = resolver(
                [
                    [(0, False, None), (1, True, "self_promo"), (2, False, None)],
                    [(1, False, None), (2, False, None)],
                ],
                segments,
            )
            observed.append([(run.start_id, run.end_id, run.label) for run in runs])
            return []

        self.analysis(detector, [])
        self.assertEqual(observed, [True, [(1, 1, "self_promo")]])

    def test_corrective_response_has_resolved_coverage(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            return []

        analysis, _backend = self.analysis(detector, ["not json", '{"ads":[]}'])
        self.assertEqual(analysis.audit.unresolved_ids, ())

    def test_observed_diagnostics_do_not_claim_archive_filter_state(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([0], truncated=True), response_format=backend._classification_response_format)
            backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            return []

        analysis, _backend = self.analysis(
            detector,
            ['{"ads":[[0,"sponsor_read"]]}', '{"ads":[]}'],
        )
        candidates = {candidate.kind: candidate for candidate in analysis.audit.candidates}
        self.assertEqual(
            set(candidates),
            {"positive-missing-final-span", "request-disagreement", "visible-truncation"},
        )
        self.assertNotIn("sparse", " ".join(candidate.detail for candidate in candidates.values()).lower())

    def test_adaptation_is_disabled_by_default_and_budgeted_when_explicit(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        analysis, backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])
        self.assertEqual(len(backend.calls), 2)
        self.assertEqual(analysis.audit.speculative_cuts, ())
        candidate = analysis.audit.candidates[0]

        experimental, experimental_backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}', '{"ad_ids":[1]}',
             '{"labels":{"0":"programme","1":"commercial","2":"programme"}}'],
            experimental_candidates=[candidate],
            experimental_max_additional_model_calls=2,
        )
        self.assertEqual(experimental.audit.speculative_cuts[0]["ids"], (1,))
        self.assertEqual(experimental.audit.experimental_requests, 2)
        self.assertEqual(len(experimental_backend.calls), 4)

    def test_incomplete_adaptation_returns_no_speculative_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        report, _unused_backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}'],
            experimental_candidates=[wp.AuditCandidate("unobserved", (1,), "missing evidence")],
            experimental_max_additional_model_calls=1,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIsNotNone(report.audit.incomplete_error)

    def test_an_ad_free_episode_is_not_marked_near_empty(self):
        # Zero nominations is a definite answer, not a sick backend's silence:
        # the request and failure counts on the audit are what tell those two
        # apart, so the near-empty note must stay clear of a clean empty run.
        def detector(_segments, _backend):
            return []

        analysis, _backend = self.analysis(detector, [])
        self.assertEqual(analysis.detections, ())
        self.assertIsNone(analysis.audit.near_empty)
        self.assertIsNone(wp.serialize_ad_audit(analysis.audit)["nearEmpty"])

    def test_near_empty_needs_both_floors_not_either(self):
        # The marker is a conjunction. A nomination above the seconds floor
        # is not near-empty even when its share of a long episode is a trace,
        # and a nomination above the share floor is not near-empty even when
        # it is small in absolute terms, so each floor has to be able to hold
        # the marker back on its own.
        def generous_seconds(_segments, _backend):
            return [FakeAd(0.0, 20.0)]

        long_episode, _backend = self.analysis(
            generous_seconds, [], total_seconds=10_000.0
        )
        self.assertIsNone(long_episode.audit.near_empty)

        def generous_share(_segments, _backend):
            return [FakeAd(0.0, 10.0)]

        dense_episode, _backend = self.analysis(
            generous_share, [], total_seconds=1_000.0
        )
        self.assertIsNone(dense_episode.audit.near_empty)

    def test_a_run_without_a_usable_duration_carries_no_near_empty_note(self):
        # The marker is a share as well as a size, so without a denominator
        # there is no note to add; the caller has already failed the run for
        # the missing timing, and a second, invented complaint helps nobody.
        self.assertIsNone(wp._near_empty_nominations([FakeAd(0.0, 1.0)], 0.0))
        self.assertIsNone(wp._near_empty_nominations([FakeAd(0.0, 1.0)], float("inf")))

    def test_unknown_classifier_shape_and_schema_fail_closed(self):
        def unknown_prompt(_segments, backend):
            try:
                backend.generate("new classification format", self.rendered([0]))
            except wp.WorkerError:
                pass
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(unknown_prompt, [])
        self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")

        def wrong_schema(_segments, backend):
            try:
                backend.generate("classify", self.rendered([0]), response_format={"type": "json_object"})
            except wp.WorkerError:
                pass
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(wrong_schema, [])
        self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")

    def test_unrelated_boundary_prompt_is_allowed_but_cannot_replace_classifier_coverage(self):
        def detector(_segments, backend):
            response, _ = backend.generate(
                "BOUNDARY review",
                self.rendered([0]),
                response_format={"field": "program_id", "ids": [0]},
            )
            self.assertEqual(response, '{"program_id":0}')
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ['{"program_id":0}'], auto_cover=False)
        self.assertEqual(raised.exception.code, "ads-classification-incomplete")

    def test_partial_valid_coverage_fails_with_missing_global_ids(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ['{"ads":[]}'], auto_cover=False)
        self.assertEqual(raised.exception.code, "ads-classification-incomplete")
        self.assertIn("1, 2", str(raised.exception))
