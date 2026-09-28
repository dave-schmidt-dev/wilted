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

class ProportionalRenderBudgetTests(unittest.TestCase):
    """The classifier must see a whole sponsor read whenever the batch fits."""

    # Shaped like a real classification window: a long host read beside the
    # short conversational cues that surround it. Under the archive's equal
    # split the short cues hold budget they cannot spend and the read loses its
    # middle, which is how the Practical AI Framer read reached the model with
    # its call to action cut out.
    HOST_READ = (
        "our sponsor framer is the pro website builder for creators teams and "
        "businesses that want to look professional without hiring a designer "
        "and you can start free today at framer dot com slash practical ai for "
        "thirty percent off your first year of a pro plan"
    )
    CUES = ["right", "yeah exactly", HOST_READ, "mm hmm", "that is wild", "okay so"]

    def setUp(self):
        self.ads = install_fake_ads(FakeLLM())
        wp.install_proportional_render_budget(self.ads)
        self.segments = [
            FakeSegment(float(index) * 10, float(index + 1) * 10, text)
            for index, text in enumerate(self.CUES)
        ]
        self.ids = list(range(len(self.CUES)))

    def render(self, max_chars, ids=None, headers=None):
        return self.ads._render_segments_bounded(
            self.ids if ids is None else ids, self.segments, headers, max_chars
        )

    @staticmethod
    def flat_budgets(lengths, text_budget):
        """The equal split this replaces, for contrast."""
        share, remainder = divmod(text_budget, len(lengths))
        return [share + (position < remainder) for position in range(len(lengths))]

    def fixed_chars(self, ids, headers=()):
        prefixes = [self.ads._segment_prefix(i, self.segments[i]) for i in ids]
        line_count = len(headers) + len(ids)
        return sum(map(len, headers)) + sum(map(len, prefixes)) + max(0, line_count - 1)

    def fits_cap(self):
        # Shaped like a real window: the whole batch fits, and one equal share
        # does not cover the host read. Both halves matter -- the first is why
        # nothing should be truncated, the second is why the archive was.
        return self.fixed_chars(self.ids) + 400

    def test_a_batch_that_fits_renders_every_cue_in_full(self):
        rendered = self.render(self.fits_cap())
        self.assertNotIn(self.ads._TRUNCATION_MARKER, rendered)
        for text in self.CUES:
            self.assertIn(text, rendered)

    def test_the_equal_split_would_have_truncated_the_read_that_fits(self):
        # The defect, stated as arithmetic: the batch is well under the cap and
        # the archive truncates anyway, because the short cues are handed a
        # share of the budget they will never use.
        budget = self.fits_cap() - self.fixed_chars(self.ids)
        lengths = [len(text) for text in self.CUES]
        self.assertLess(sum(lengths), budget, "this batch fits under the cap in full")
        flat = self.flat_budgets(lengths, budget)
        self.assertLess(flat[2], lengths[2], "the equal split truncates the host read")
        proportional = wp._proportional_render_budgets(lengths, budget)
        self.assertEqual(proportional, lengths, "every cue is given exactly what it needs")

    def test_over_budget_batches_stay_under_the_cap_and_keep_the_short_cues(self):
        cap = self.fixed_chars(self.ids) + 120
        rendered = self.render(cap)
        self.assertLessEqual(len(rendered), cap)
        self.assertIn(self.ads._TRUNCATION_MARKER, rendered)
        lines = rendered.split("\n")
        self.assertEqual(len(lines), len(self.CUES))
        for index, text in enumerate(self.CUES):
            if index == 2:
                continue
            self.assertIn(text, lines[index], "a short cue is never truncated to pay for a long one")
        self.assertIn(self.ads._TRUNCATION_MARKER, lines[2])

    def test_uniform_cues_render_exactly_as_the_equal_split_did(self):
        # The fallback has to be the behaviour it replaces, or this is a
        # rewrite of the archive's renderer rather than a budget fix.
        lengths = [400, 400, 400, 400]
        self.assertEqual(
            wp._proportional_render_budgets(lengths, 802), self.flat_budgets(lengths, 802)
        )

    def test_every_allocation_spends_no_more_than_the_budget(self):
        for lengths, budget in (
            ([5, 5, 5], 9),
            ([1, 1, 900], 100),
            ([0, 0, 0], 7),
            ([300], 12),
            ([], 50),
            ([2, 3, 4, 500, 600], 61),
        ):
            with self.subTest(lengths=lengths, budget=budget):
                budgets = wp._proportional_render_budgets(lengths, budget)
                self.assertEqual(len(budgets), len(lengths))
                self.assertLessEqual(sum(budgets), budget)
                for allocated, length in zip(budgets, lengths):
                    self.assertGreaterEqual(allocated, 0)
                if sum(lengths) <= budget:
                    self.assertEqual(budgets, lengths, "a batch that fits is never truncated")

    def test_prefixes_order_and_headers_are_unchanged(self):
        headers = ["window 0", "classify each ID"]
        rendered = self.render(self.fits_cap() + sum(map(len, headers)) + 2, headers=headers)
        lines = rendered.split("\n")
        self.assertEqual(lines[: len(headers)], headers)
        for index, line in enumerate(lines[len(headers) :]):
            self.assertTrue(line.startswith(self.ads._segment_prefix(index, self.segments[index])))

    def test_required_ids_that_cannot_fit_are_still_a_contract_failure(self):
        with self.assertRaises(ValueError):
            self.render(self.fixed_chars(self.ids) - 1)

    def test_repeated_install_replaces_the_renderer_once(self):
        once = self.ads._render_segments_bounded
        wp.install_proportional_render_budget(self.ads)
        self.assertIs(self.ads._render_segments_bounded, once)

    def test_a_missing_archive_helper_is_a_contract_failure(self):
        ads = install_fake_ads(FakeLLM())
        del ads._truncate_head_tail
        with self.assertRaises(AttributeError):
            wp.install_proportional_render_budget(ads)

class ContextAwareOverlapVoteTests(unittest.TestCase):
    """Only a better-context positive run overrides the archive's tie rule."""

    def setUp(self):
        self.ads = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(self.ads)
        self.segments = [
            FakeSegment(float(index), float(index + 1), f"cue {index}")
            for index in range(5)
        ]

    def resolve(self, raw_classifications):
        return self.ads._resolve_overlaps(raw_classifications, self.segments)  # noqa: SLF001

    @staticmethod
    def run_shape(runs):
        return [
            (run.start_id, run.end_id, run.confidence, run.label)
            for run in runs
        ]

    def test_contextual_tie_recovers_the_label_and_context_only_confidence(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        runs = self.resolve(
            [
                [
                    (0, False, None),
                    (1, True, "self_promo"),
                    (2, True, "self_promo"),
                    (3, True, "self_promo"),
                    (4, False, None),
                ],
                [(2, False, None), (3, False, None), (4, False, None)],
            ]
        )
        self.assertEqual(self.run_shape(runs), [(1, 3, 1.0, "self_promo")])
        self.assertGreaterEqual(runs[0].confidence, 0.8)

    def test_an_ordinary_tie_remains_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertEqual(
            self.resolve([[(1, True, "self_promo")], [(1, False, None)]]),
            [],
        )

    def test_runs_touching_either_source_window_edge_remain_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        cases = (
            [
                [(0, True, "self_promo"), (1, True, "self_promo"), (2, False, None)],
                [(0, False, None), (1, False, None)],
            ],
            [
                [(0, False, None), (1, True, "self_promo"), (2, True, "self_promo")],
                [(1, False, None), (2, False, None)],
            ],
        )
        for classifications in cases:
            with self.subTest(classifications=classifications):
                self.assertEqual(self.resolve(classifications), [])

    def test_content_window_starting_outside_the_run_remains_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertEqual(
            self.resolve(
                [
                    [
                        (0, False, None),
                        (1, True, "self_promo"),
                        (2, True, "self_promo"),
                        (3, False, None),
                    ],
                    [
                        (0, False, None),
                        (1, False, None),
                        (2, False, None),
                        (3, False, None),
                    ],
                ]
            ),
            [],
        )

    def test_missing_resolver_raises_and_reinstallation_is_idempotent(self):
        with self.assertRaises(AttributeError):
            wp.install_context_aware_overlap_resolution(types.ModuleType("wilted.ads"))
        missing_sparse_verifier = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(missing_sparse_verifier)
        del missing_sparse_verifier._verify_sparse_content_start  # noqa: SLF001
        with self.assertRaises(AttributeError):
            wp.install_context_aware_overlap_resolution(missing_sparse_verifier)
        wp.install_context_aware_overlap_resolution(self.ads)
        installed = self.ads._resolve_overlaps  # noqa: SLF001
        installed_sparse_verifier = self.ads._verify_sparse_content_start  # noqa: SLF001
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertIs(self.ads._resolve_overlaps, installed)  # noqa: SLF001
        self.assertIs(
            self.ads._verify_sparse_content_start,  # noqa: SLF001
            installed_sparse_verifier,
        )

    def test_detection_installs_the_resolver_before_the_archive_detector_runs(self):
        llm = FakeLLM(loaded=True)
        ads = install_fake_ads(llm)
        observed = []

        def detector(segments, backend):
            observed.append(
                getattr(
                    ads._resolve_overlaps,  # noqa: SLF001
                    wp._CONTEXT_AWARE_OVERLAP_MARKER,
                    False,
                )
            )
            backend.generate(
                ads._AD_DETECT_SYSTEM_PROMPT,  # noqa: SLF001
                "\n".join(
                    f"[ID {index}] [{segment.start_s:.2f}s - {segment.end_s:.2f}s] {segment.text}"
                    for index, segment in enumerate(segments)
                ),
                response_format=ads._AD_DETECT_RESPONSE_FORMAT,  # noqa: SLF001
            )
            return []

        ads.detect_ads = detector
        with redirect_stderr(io.StringIO()):
            wp.analyze_ad_detections(ads, llm, self.segments, 5.0)
        self.assertEqual(observed, [True])

class ContextRecoveredBoundaryTests(unittest.TestCase):
    """Context provenance suppresses only the archive's sparse right expansion."""

    def setUp(self):
        self.ads = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(self.ads)
        self.segments = [
            FakeSegment(float(index), float(index + 1), f"cue {index}")
            for index in range(194)
        ]
        self.sparse_calls = []

        def sparse_content_start(coarse_run, confirmed_start_id, _segments, _backend):
            self.sparse_calls.append((coarse_run.start_id, coarse_run.end_id, confirmed_start_id))
            return 193

        self.ads._verify_sparse_content_start = sparse_content_start  # noqa: SLF001

        def verify_boundaries(coarse_run, segments, backend):
            verified_start = coarse_run.start_id
            for _ in range(2):
                candidate_id = verified_start - 1
                if candidate_id < 0 or candidate_id != 182:
                    break
                verified_start = candidate_id
            verified_end = coarse_run.end_id
            if coarse_run.end_id - coarse_run.start_id + 1 <= 2:
                content_start_id = self.ads._verify_sparse_content_start(  # noqa: SLF001
                    coarse_run, verified_start, segments, backend
                )
                verified_end = content_start_id - 1
            return verified_start, verified_end, coarse_run.confidence, coarse_run.label

        self.ads._verify_ad_boundaries = verify_boundaries  # noqa: SLF001
        wp.install_context_aware_overlap_resolution(self.ads)

    @staticmethod
    def contextual_votes():
        return [
            [
                (182, False, None),
                (183, True, "self_promo"),
                (184, True, "self_promo"),
                (185, False, None),
            ],
            [(segment_id, False, None) for segment_id in range(183, 194)],
        ]

    @staticmethod
    def ordinary_sparse_votes():
        return [[(183, True, "self_promo"), (184, True, "self_promo")]]

    def detect(self, raw_classifications):
        runs = self.ads._resolve_overlaps(raw_classifications, self.segments)  # noqa: SLF001
        return [
            self.ads._verify_ad_boundaries(run, self.segments, object())  # noqa: SLF001
            for run in runs
        ]

    def test_context_recovery_keeps_the_coarse_right_edge_after_left_probe(self):
        self.assertEqual(
            self.detect(self.contextual_votes()),
            [(182, 184, 1.0, "self_promo")],
        )
        self.assertEqual(self.sparse_calls, [])

    def test_next_ordinary_sparse_run_still_uses_right_boundary_expansion(self):
        self.detect(self.contextual_votes())
        self.sparse_calls.clear()
        self.assertEqual(
            self.detect(self.ordinary_sparse_votes()),
            [(182, 192, 1.0, "self_promo")],
        )
        self.assertEqual(self.sparse_calls, [(183, 184, 182)])
