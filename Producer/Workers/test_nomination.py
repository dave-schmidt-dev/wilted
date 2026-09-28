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

class NominatedPodBoundTests(unittest.TestCase):
    """The proportional pod bound is a supplied parameter, and no value lands.

    The archive's bracket bound is a fixed ten minutes, so on a short episode a
    single pod can swallow most of the programme. The corpus cannot calibrate a
    proportional replacement: its three cases are all tuning inputs and the
    recorded short-episode overcut input is gone (`gaps`, id
    `techcrunch-short-episode-overcut`), so replay evidence alone cannot
    establish a safe value. The seam is what this class tests; `None` is the
    production default and applies no bound.
    """

    def setUp(self):
        self.segments = [FakeSegment(0.0, 30.0, "one long produced passage")]
        self.llm = FakeLLM(loaded=True)
        self.ads = install_fake_ads(self.llm, detections=[FakeAd(0.0, 30.0, label="ad_break")])

    def test_the_bound_is_a_parameter_and_no_module_constant_lands(self):
        parameters = inspect.signature(wp.detect_nominated_ad_spans).parameters
        self.assertIn("pod_share_bound", parameters)
        self.assertIsNone(parameters["pod_share_bound"].default)
        analysis_parameters = inspect.signature(wp.analyze_ad_detections).parameters
        self.assertIn("pod_share_bound", analysis_parameters)
        self.assertIsNone(analysis_parameters["pod_share_bound"].default)
        for name in worker_namespaces():
            self.assertNotIn(
                "POD_SHARE", name.upper(),
                f"a pod bound constant landed: {name}; the bound must stay a parameter",
            )

    def test_no_bound_supplied_leaves_the_produced_span_set_unchanged(self):
        omitted = wp.detect_nominated_ad_spans(self.ads, self.llm, self.segments, 100.0)
        explicit_none = wp.detect_nominated_ad_spans(
            self.ads, self.llm, self.segments, 100.0, pod_share_bound=None
        )
        expected = [(0.0, 30.0, "ad_break")]
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in omitted], expected)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in explicit_none], [(0.0, 30.0)])

    def test_a_nominated_pod_over_the_bound_is_dropped_uncut(self):
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.detect_nominated_ad_spans(
                self.ads, self.llm, self.segments, 100.0, pod_share_bound=0.25
            )
        self.assertEqual(kept, [])
        details = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual([event["stage"] for event in details], ["ads.detect.pod.rejected"])
        self.assertIn("30% of the episode", details[0]["detail"])
        self.assertIn("25%", details[0]["detail"])

    def test_only_the_pod_over_the_bound_is_dropped(self):
        ads = install_fake_ads(self.llm, detections=[FakeAd(0.0, 10.0, label="ad_break"),
                                                     FakeAd(40.0, 70.0, label="ad_break")])
        kept = wp.detect_nominated_ad_spans(ads, self.llm, self.segments, 100.0, pod_share_bound=0.25)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in kept], [(0.0, 10.0)])

    def test_the_analysis_seam_applies_a_supplied_bound_to_the_produced_spans(self):
        bounded = wp.analyze_ad_detections(
            self.ads, self.llm, self.segments, 100.0, pod_share_bound=0.25
        )
        self.assertEqual(bounded.detections, ())
        default = wp.analyze_ad_detections(self.ads, self.llm, self.segments, 100.0)
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in default.detections], [(0.0, 30.0)],
            "no bound supplied must leave the produced span set at its prior value",
        )
        self.assertTrue(
            all((ad.end_s - ad.start_s) / 100.0 <= 0.25 for ad in bounded.detections),
            "a supplied bound must not leave a pod whose share exceeds it",
        )

class CorpusBracketingMeasurementTests(unittest.TestCase):
    """Task 5.3: the figure that blocks a proportional pod bound.

    A proportional bound cannot be calibrated from replay alone unless the
    corpus holds bracketed pods a bound would have to pass. This walks the
    labels: how many labelled pods exist, how many have labelled programme on
    both sides, and whether any short episode has one. The figure is pinned so
    adding a case re-opens the calibration question deliberately.
    """

    @classmethod
    def setUpClass(cls):
        cls.corpus = load_ad_corpus()
        cls.cases = cls.corpus.load_manifest()["cases"]

    def test_labelled_pods_merge_touching_cuts_and_ignore_other_labels(self):
        case = {"id": "synthetic", "show": "S", "audioDurationSeconds": 100.0, "expected": [
            {"start": 0.0, "end": 5.0, "label": "must-keep"},
            {"start": 10.0, "end": 15.0, "label": "must-cut"},
            {"start": 15.0, "end": 20.0, "label": "must-cut"},
            {"start": 30.0, "end": 35.0, "label": "acceptable-cut"},
            {"start": 40.0, "end": 45.0, "label": "must-cut"},
        ]}
        self.assertEqual(
            [(pod.start, pod.end) for pod in self.corpus.labelled_pods(case)],
            [(10.0, 20.0), (40.0, 45.0)],
            "adjacent must-cut spans are one pod; acceptable-cut is not a pod",
        )

    def test_bracketing_needs_labelled_programme_on_both_sides(self):
        case = {"id": "synthetic", "show": "S", "audioDurationSeconds": 100.0, "expected": [
            {"start": 0.0, "end": 5.0, "label": "must-keep"},
            {"start": 10.0, "end": 20.0, "label": "must-cut"},
            {"start": 25.0, "end": 28.0, "label": "must-keep"},
            {"start": 30.0, "end": 40.0, "label": "must-cut"},
            {"start": 60.0, "end": 70.0, "label": "acceptable-cut"},
        ]}
        self.assertEqual(
            [(pod.start, pod.end) for pod in self.corpus.bracketed_labelled_pods(case)],
            [(10.0, 20.0)],
            "acceptable-cut does not bracket; the later pod has no programme after it",
        )

    def test_the_corpus_holds_two_bracketed_pods_in_one_long_case(self):
        measured = self.corpus.bracketing_measurement(self.cases)
        # Reread 2026-09-23 when the Planet Money case landed: one more bracketed
        # pod, 4.7% of a mid-length episode, so a proportional bound now has a
        # second show's pod to pass. Reread again the same day for the TechCrunch
        # Alexa case: two more pods, neither bracketed. Still no short episode
        # with a bracketed pod.
        self.assertEqual(measured["cases"], 6)
        self.assertEqual(measured["labelled_pods"], 14)
        self.assertEqual(measured["bracketed_pods"], 3)
        self.assertEqual(measured["cases_with_bracketed_pods"], 2)
        by_id = {row["id"]: row for row in measured["per_case"]}
        practical = by_id["practical-ai-two-host-reads-left-whole"]
        self.assertEqual(practical["bracketed_pods"], 2)
        self.assertTrue(
            all(0.0 < share < 0.05 for share in practical["bracketed_shares"]),
            "both bracketed pods are a few percent of a long episode",
        )
        techcrunch = by_id["techcrunch-preroll-swallowed-the-headline-lead-in"]
        self.assertLess(techcrunch["audio_seconds"], 400.0, "the corpus's shortest episode")
        self.assertEqual(
            techcrunch["bracketed_pods"], 0,
            "the short episode's overcut is an opening pod; bracketing cannot delimit it",
        )
        planet_money = by_id["planet-money-palantir-midroll-pod-left-whole"]
        self.assertEqual(planet_money["bracketed_pods"], 1, "the mid-roll pod between host lines")
        self.assertTrue(all(0.0 < share < 0.05 for share in planet_money["bracketed_shares"]))
        alexa = by_id["techcrunch-alexa-postroll-left-its-opening"]
        self.assertLess(alexa["audio_seconds"], 600.0)
        self.assertEqual(
            (alexa["labelled_pods"], alexa["bracketed_pods"]), (2, 0),
            "an opening pod and a closing one; neither has programme on both sides",
        )
