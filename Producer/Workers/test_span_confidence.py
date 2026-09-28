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

class ProducedSpanConfidenceTests(unittest.TestCase):
    """Every worker-produced span reports measured confidence, never 1.0.

    The four recovery sites used to stamp their spans with a literal 1.0 --
    the same value a classifier assigns -- so nothing downstream could tell a
    reviewed span from a classified one. Confidence is now a receipt of the
    evidence the recovery observed. It is reporting only: the seconds cut are
    unchanged, which the cut-set test below pins.
    """

    PREROLL = [
        FakeSegment(0.0, 30.0, "produced spot for a game"),
        FakeSegment(30.0, 60.0, "the spot continues"),
        FakeSegment(60.0, 90.0, "the spot ends"),
        FakeSegment(90.0, 120.0, "more produced spot"),
        FakeSegment(120.0, 150.0, "still produced spot"),
        FakeSegment(150.0, 180.0, "Hey everybody, welcome to the show"),
    ]

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def produced_preroll(self, **llm_kwargs):
        llm = FakeLLM(**llm_kwargs)
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=600.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        return spans

    def test_no_worker_site_passes_a_literal_confidence_for_a_produced_span(self):
        literals = []
        for path in WORKER_SOURCES:
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "AdSegment"):
                    continue
                third = (
                    node.args[2] if len(node.args) >= 3
                    else next((kw.value for kw in node.keywords if kw.arg == "confidence"), None)
                )
                if isinstance(third, ast.Constant) and third.value == 1.0:
                    literals.append((path.name, node.lineno))
        self.assertEqual(literals, [], "produced spans must carry measured confidence, not 1.0")

    def test_the_recovered_confidence_band_is_bounded_and_monotonic(self):
        self.assertLess(wp.RECOVERED_CONFIDENCE_FLOOR, wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertLess(wp.RECOVERED_CONFIDENCE_CEILING, 1.0)
        self.assertEqual(wp.recovered_confidence(0, 4), wp.RECOVERED_CONFIDENCE_FLOOR)
        self.assertEqual(wp.recovered_confidence(4, 4), wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertLess(wp.recovered_confidence(2, 4), wp.recovered_confidence(4, 4))
        self.assertEqual(wp.recovered_confidence(9, 4), wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertEqual(wp.recovered_confidence(1, 0), wp.RECOVERED_CONFIDENCE_FLOOR)

    def test_weak_and_strong_openings_report_different_confidences(self):
        # Same recovery, two evidence strengths: the confirmation agreeing is
        # stronger than a boundary the second question had to move.
        strong = self.produced_preroll(preroll_program_start_id=5, preroll_program_id=-1)
        weak = self.produced_preroll(preroll_program_start_id=5, preroll_program_id=4)
        self.assertEqual(len(strong), 1)
        self.assertEqual(len(weak), 1)
        self.assertEqual(strong[0]["confidence"], wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertLess(weak[0]["confidence"], strong[0]["confidence"])

    def test_a_measured_confidence_does_not_change_which_span_is_cut(self):
        # Confidence is reporting. The span set is exactly what the literal-1.0
        # site produced; only the number beside it moved.
        spans = self.produced_preroll(preroll_program_start_id=5, preroll_program_id=-1)
        self.assertEqual(
            [(span["startSeconds"], span["endSeconds"], span["label"]) for span in spans],
            [(0.0, 150.0, "ad_break")],
        )
        self.assertNotEqual(spans[0]["confidence"], 1.0)

class RuntimeRecoveryConfidenceTests(unittest.TestCase):
    """The Runtime's own recovery reviews report a measured receipt too.

    The archive's bracket and anchor recoveries stamped their spans with a
    literal 1.0 even after the worker's four recovery sites carried measured
    confidence, so a recovered span was distinguishable from a classified one
    only by which file built it. Their certainty is the share of their own
    corroboration contract that was actually observed -- window overlap,
    agreeing reviews, agreeing probes -- mapped onto the same 0.5-0.9 band the
    worker uses.
    """

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    class Backend:
        """Answer the bounded reviews in order and record every call."""

        def __init__(self, responses):
            self.responses = list(responses)
            self.calls = []

        def generate(self, system_prompt, content, *, response_format=None):
            self.calls.append((system_prompt, content))
            response = self.responses.pop(0)
            return response if isinstance(response, tuple) else (response, 1)

    def segment(self, start, end, text):
        return self.Segment(start, end, text)

    def test_the_runtime_band_matches_the_worker_band(self):
        self.assertEqual(self.ads.RECOVERED_CONFIDENCE_FLOOR, wp.RECOVERED_CONFIDENCE_FLOOR)
        self.assertEqual(self.ads.RECOVERED_CONFIDENCE_CEILING, wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertEqual(self.ads.recovered_confidence(0, 4), self.ads.RECOVERED_CONFIDENCE_FLOOR)
        self.assertEqual(self.ads.recovered_confidence(4, 4), self.ads.RECOVERED_CONFIDENCE_CEILING)
        self.assertLess(self.ads.recovered_confidence(2, 4), self.ads.recovered_confidence(4, 4))
        self.assertLess(self.ads.RECOVERED_CONFIDENCE_CEILING, 1.0)
        self.assertEqual(self.ads.recovered_confidence(1, 0), self.ads.RECOVERED_CONFIDENCE_FLOOR)

    def test_no_site_in_either_layer_passes_a_literal_confidence(self):
        # Clause 1's whole surface: the worker's four recovery reviews and the
        # Runtime's bracket and anchor recoveries. The worker's sites are
        # covered behaviorally by ProducedSpanConfidenceTests; this scans both
        # sources so a new literal cannot land in either one silently.
        def literal_sites(path):
            sites = []
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
                if name != "AdSegment":
                    continue
                third = (
                    node.args[2] if len(node.args) >= 3
                    else next((kw.value for kw in node.keywords if kw.arg == "confidence"), None)
                )
                if isinstance(third, ast.Constant) and third.value == 1.0:
                    sites.append((path.name, node.lineno))
            return sites

        self.assertEqual(
            [site for path in WORKER_SOURCES for site in literal_sites(path)], [],
            "worker produced spans must carry measured confidence, not 1.0",
        )
        self.assertEqual(
            literal_sites(RUNTIME_ADS_PATH), [],
            "Runtime recovery spans must carry measured confidence, not 1.0",
        )
        self.assertIn(
            "def recovered_confidence", RUNTIME_ADS_PATH.read_text(encoding="utf-8")
        )

    def bracketed_segments(self):
        return [
            self.segment(0, 10, "We'll be right back."),
            self.segment(10, 20, "Hot nights can leave you tossing and turning."),
            self.segment(20, 30, "The mattress has cooling upgrades and free shipping."),
            self.segment(30, 40, "This is a paid ad for BetterHelp."),
            self.segment(40, 50, "Visit betterhelp.com today for a free trial."),
            self.segment(50, 60, "And now back to the show."),
            self.segment(60, 70, "The interview resumes."),
        ]

    def test_a_seeded_bracketed_pod_reports_the_corroboration_it_observed(self):
        backend = self.Backend(['{"include":true}', '{"start_id":2}', '{"include":true}'])
        pods = self.ads._recover_bracketed_ad_pods(
            self.bracketed_segments(),
            backend,
            [self.ads._CoarseAdRun(2, 2, 0.775, "sponsor_read")],
        )
        self.assertEqual(
            [(pod.start_s, pod.end_s, pod.label) for pod in pods], [(10, 60, "ad_break")]
        )
        # Seed classification, early-seed review and one neighbour probe all
        # agreed: three of the four corroborations this pass can collect.
        self.assertEqual(pods[0].confidence, self.ads.recovered_confidence(3, 4))
        self.assertLess(pods[0].confidence, 1.0)

    def test_an_unseeded_bracketed_pod_reports_the_band_floor(self):
        # The mandatory bumpers, sponsor opening and commercial cue produce
        # the span, but no independent classification or review corroborated
        # it, and the receipt says exactly that instead of claiming certainty.
        backend = self.Backend([])
        pods = self.ads._recover_bracketed_ad_pods(self.bracketed_segments(), backend, [])
        self.assertEqual(len(pods), 1)
        self.assertEqual(pods[0].confidence, self.ads.RECOVERED_CONFIDENCE_FLOOR)
        self.assertEqual(backend.calls, [], "an unseeded pod asks the model nothing")

    def test_an_anchor_recovery_reports_where_the_verifier_placed_content(self):
        segments = [
            self.segment(0, 10, "Today's sponsor is Acme."),
            self.segment(10, 20, "Visit acme.com."),
            self.segment(20, 30, "Program discussion."),
            self.segment(30, 40, "More program discussion."),
        ]
        seed = [self.ads._CoarseAdRun(1, 1, 0.775, "sponsor_read")]
        interior = self.Backend(['{"content_start_id":2}'])
        recovered, _claimed = self.ads._recover_explicit_sponsor_pods(segments, interior, seed)
        self.assertEqual(len(recovered), 1)
        # Seed, complete review context and a resumption inside the window:
        # three of the four corroborations this pass can collect.
        self.assertEqual(recovered[0].confidence, self.ads.recovered_confidence(3, 4))
        edge = self.Backend(['{"content_start_id":3}'])
        recovered_edge, _claimed = self.ads._recover_explicit_sponsor_pods(segments, edge, seed)
        self.assertEqual(len(recovered_edge), 1)
        # The verifier placed content at the window edge, so that one
        # corroboration was not observed.
        self.assertEqual(recovered_edge[0].confidence, self.ads.recovered_confidence(2, 4))
        self.assertLess(recovered_edge[0].confidence, recovered[0].confidence)
        self.assertLess(recovered_edge[0].confidence, 1.0)

    def test_a_detected_episode_reports_more_than_one_confidence(self):
        # A corpus-length episode is wider than one classification window, so
        # its edge segments get a single vote and a fully covered interior
        # segment gets two; the reported spans are a receipt of that window
        # overlap rather than one flat number.
        segments = [
            self.segment(
                index * 60.0,
                index * 60.0 + 60.0,
                "visit acme.com" if index in {0, 1, 8, 10, 11} else f"programme {index}",
            )
            for index in range(12)
        ]
        windows = iter([{0, 1, 8}, {8, 10, 11}])

        class Classifier:
            def generate(self, system_prompt, content, *, response_format=None):
                ad_ids = next(windows)
                ids = [int(value) for value in re.findall(r"\[ID (\d+)\]", content)]
                return json.dumps({
                    "ads": [
                        [segment_id, "sponsor_read"]
                        for segment_id in ids if segment_id in ad_ids
                    ]
                }), 1

        def verified(run, segments, _backend):
            return self.ads.AdSegment(
                segments[run.start_id].start_s,
                segments[run.end_id].end_s,
                run.confidence,
                run.label,
            )

        with mock.patch.object(self.ads, "_verify_ad_boundaries", verified), \
                mock.patch.object(self.ads, "_recover_bracketed_ad_pods", lambda *args: []), \
                mock.patch.object(
                    self.ads, "_recover_explicit_sponsor_pods", lambda *args: ([], [])
                ):
            spans = self.ads.detect_ads(segments, Classifier())
        confidences = {span.confidence for span in spans}
        self.assertEqual(
            confidences,
            {self.ads.coarse_confidence(1, 2), self.ads.coarse_confidence(2, 2)},
            "the spans' confidences are the window overlap each segment was seen with",
        )
        self.assertTrue(all(0.0 < value < 1.0 for value in confidences))
