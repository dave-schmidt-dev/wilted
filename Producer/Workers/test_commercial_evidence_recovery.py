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

class CommercialEvidenceRecoveryTests(unittest.TestCase):
    def analyze(self, segments, *, ad_ids, programme_ids):
        llm = FakeLLM(commercial_ad_ids=ad_ids, commercial_programme_ids=programme_ids)
        llm.load()
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: []
        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(ads, llm, segments, 500.0)
        return analysis, llm

    def preserve(self, llm, segments, candidate_ids):
        ads = install_fake_ads(llm)
        llm.load()
        stream = io.StringIO()
        with redirect_stderr(stream):
            preserved = wp._commercial_envelope_preserved(
                ads, llm, segments, 500.0, candidate_ids, nominate=False
            )
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        return preserved, details

    @staticmethod
    def preservation_labels(segments, **overrides):
        labels = {str(index): "programme" for index in range(1, 7)}
        labels.update({"3": "commercial", "4": "commercial"})
        labels.update(overrides)
        return json.dumps({"labels": labels})

    def test_adjacent_cta_and_destination_recover_an_unanchored_read(self):
        segments = [
            FakeSegment(0.0, 10.0, "the programme discusses its topic"),
            FakeSegment(10.0, 20.0, "visit acme dot com for the offer"),
            FakeSegment(20.0, 30.0, "get started today with acme"),
            FakeSegment(30.0, 40.0, "the programme interview resumes"),
        ]
        analysis, _llm = self.analyze(segments, ad_ids=[1, 2], programme_ids=[0, 3])
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(10.0, 30.0, "sponsor_read")],
        )
        # The receipt is two of the recovery's three signals: the seed sits in
        # one cue carrying both the call to action and the destination, but the
        # nomination widened it to two. The span is reported, never 1.0.
        self.assertEqual(analysis.detections[0].confidence, 0.7667)
        self.assertLess(analysis.detections[0].confidence, 1.0)

    def test_destination_split_across_cues_still_nominates_the_exact_window(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit acme dot"),
            FakeSegment(20.0, 30.0, "com for thirty percent off"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        self.assertEqual(wp.commercial_evidence_seed_ids(segments, []), ((1, 2),))

    def test_call_to_action_split_across_cues_still_nominates_the_exact_window(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "acme dot com can help you get"),
            FakeSegment(20.0, 30.0, "started today"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        self.assertEqual(wp.commercial_evidence_seed_ids(segments, []), ((1, 2),))

    def test_complete_oversized_cue_is_rejected_instead_of_truncated_for_review(self):
        interior = "the guest explains the editorial result"
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(
                10.0,
                20.0,
                "visit acme dot com " + ("offer " * 1100) + interior
                + ("details " * 900) + " get started today",
            ),
            FakeSegment(20.0, 30.0, "programme after"),
        ]
        analysis, llm = self.analyze(segments, ad_ids=[1], programme_ids=[0, 2])
        self.assertEqual(analysis.detections, ())
        self.assertFalse(
            any(request.get("schema", {}).get("properties", {}).get("ad_ids")
                for request in llm.requests)
        )

    def test_long_host_read_is_not_lost_to_the_context_id_bound(self):
        segments = [FakeSegment(0.0, 2.0, "the programme discusses its topic")]
        segments.extend(
            FakeSegment(
                float(segment_id * 2),
                float(segment_id * 2 + 2),
                "visit acme dot com and get started today with the sponsor",
            )
            for segment_id in range(1, 31)
        )
        segments.append(FakeSegment(62.0, 64.0, "the programme interview resumes"))
        analysis, _llm = self.analyze(
            segments,
            ad_ids=list(range(1, 31)),
            programme_ids=[0, 31],
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(2.0, 62.0, "sponsor_read")],
        )

    def test_noncontiguous_or_programme_intersecting_nominations_preserve_audio(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit acme dot com"),
            FakeSegment(20.0, 30.0, "get started today"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        noncontiguous, _ = self.analyze(segments, ad_ids=[1, 3], programme_ids=[0, 3])
        self.assertEqual(noncontiguous.detections, ())
        intersecting, _ = self.analyze(segments, ad_ids=[1, 2], programme_ids=[0, 2, 3])
        self.assertEqual(intersecting.detections, ())

    def test_missing_programme_context_does_not_reach_commercial_inference(self):
        segments = [
            FakeSegment(0.0, 10.0, "visit acme dot com"),
            FakeSegment(10.0, 20.0, "get started today"),
            FakeSegment(20.0, 30.0, "programme resumes"),
        ]
        analysis, llm = self.analyze(segments, ad_ids=[0, 1], programme_ids=[2])
        self.assertEqual(analysis.detections, ())
        self.assertFalse(any(request.get("schema", {}).get("properties", {}).get("ad_ids") for request in llm.requests))

    def test_overlapping_and_excess_evidence_seeds_are_bounded_before_inference(self):
        segments = [FakeSegment(0.0, 1.0, "programme context")]
        for index in range(1, 18):
            text = "visit acme dot com get started today" if index % 2 else "get started today at acme dot com"
            segments.append(FakeSegment(float(index), float(index + 1), text))
        segments.append(FakeSegment(18.0, 19.0, "programme context"))
        seeds = wp.commercial_evidence_seed_ids(segments, [])
        self.assertLessEqual(len(seeds), wp.COMMERCIAL_RECOVERY_MAX_CANDIDATES)
        self.assertTrue(all(right[-1] < left[0] for left, right in zip(seeds, seeds[1:])))

    def test_programme_flanks_and_a_commercial_proposal_are_cut(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        llm = FakeLLM(commercial_ad_ids=[3, 4], commercial_programme_ids=[1, 2, 5, 6])
        preserved, _details = self.preserve(llm, segments, (3, 4))
        self.assertEqual(preserved, (3, 4))

    def test_a_mixed_proposed_passage_is_declined(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        llm = FakeLLM(
            commercial_preservation_answer=self.preservation_labels(
                segments, **{"3": "mixed"}
            )
        )
        preserved, details = self.preserve(llm, segments, (3, 4))
        self.assertIsNone(preserved)
        self.assertIn(
            "intersects the proposed cut at IDs 3", details["ads.detect.recovery.skipped"]
        )

    def test_commercial_labels_on_one_flank_do_not_confirm_the_proposal(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        llm = FakeLLM(
            commercial_preservation_answer=self.preservation_labels(
                segments, **{"1": "commercial", "2": "commercial"}
            )
        )
        preserved, details = self.preserve(llm, segments, (3, 4))
        self.assertIsNone(preserved)
        self.assertIn(
            "not confirmed on both sides", details["ads.detect.recovery.skipped"]
        )

    def test_malformed_preservation_labels_decline_without_cutting(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        labels = json.loads(self.preservation_labels(segments))["labels"]
        malformed = []
        missing = dict(labels)
        missing.pop("1")
        malformed.append(json.dumps({"labels": missing}))
        extra = dict(labels)
        extra["9"] = "programme"
        malformed.append(json.dumps({"labels": extra}))
        invalid = dict(labels)
        invalid["3"] = "advertisement"
        malformed.append(json.dumps({"labels": invalid}))
        for response in malformed:
            with self.subTest(response=response):
                preserved, details = self.preserve(
                    FakeLLM(commercial_preservation_answer=response), segments, (3, 4)
                )
                self.assertIsNone(preserved)
                self.assertIn("invalid shape", details["ads.detect.recovery.skipped"])

    def test_preservation_request_labels_only_the_proposal_and_nearby_flanks(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        llm = FakeLLM(commercial_ad_ids=[3, 4], commercial_programme_ids=[1, 2, 5, 6])
        preserved, _details = self.preserve(llm, segments, (3, 4))
        self.assertEqual(preserved, (3, 4))
        request = next(
            content for content in llm.request_contents if content.startswith("IDs to classify:")
        )
        self.assertEqual(
            request.partition("\n")[0], "IDs to classify: 1, 2, 3, 4, 5, 6"
        )

    def test_commercial_right_flank_walks_past_a_pod(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(12)
        ]
        llm = FakeLLM(commercial_ad_ids=[3, 4], commercial_programme_ids=[1, 2, 7, 8])
        preserved, _details = self.preserve(llm, segments, (3, 4))
        requests = [content for content in llm.request_contents if content.startswith("IDs to classify:")]
        self.assertEqual(preserved, (3, 4))
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1].partition("\n")[0], "IDs to classify: 7, 8")

    def test_commercial_left_flank_walks_past_a_pod(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(12)
        ]
        llm = FakeLLM(commercial_ad_ids=[7, 8], commercial_programme_ids=[3, 4, 9, 10])
        preserved, _details = self.preserve(llm, segments, (7, 8))
        requests = [content for content in llm.request_contents if content.startswith("IDs to classify:")]
        self.assertEqual(preserved, (7, 8))
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1].partition("\n")[0], "IDs to classify: 3, 4")

    def test_commercial_flank_walk_stops_after_its_step_bound(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(16)
        ]
        llm = FakeLLM(commercial_ad_ids=[3, 4], commercial_programme_ids=[1, 2, 13])
        preserved, details = self.preserve(llm, segments, (3, 4))
        requests = [content for content in llm.request_contents if content.startswith("IDs to classify:")]
        self.assertIsNone(preserved)
        self.assertIn("not confirmed on both sides", details["ads.detect.recovery.skipped"])
        self.assertEqual(len(requests), 1 + wp.COMMERCIAL_PRESERVATION_FLANK_STEPS)
        # Each step labels the next IDs out, never the same flank again.
        self.assertEqual(requests[-1].partition("\n")[0], "IDs to classify: 11, 12")

    def test_commercial_flank_walk_stops_at_the_context_end(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(9)
        ]
        llm = FakeLLM(commercial_ad_ids=[3, 4], commercial_programme_ids=[1, 2])
        preserved, details = self.preserve(llm, segments, (3, 4))
        requests = [content for content in llm.request_contents if content.startswith("IDs to classify:")]
        self.assertIsNone(preserved)
        self.assertIn("not confirmed on both sides", details["ads.detect.recovery.skipped"])
        for request in requests:
            ids = request.partition("\n")[0].partition(": ")[2].split(", ")
            self.assertTrue(all(0 <= int(segment_id) < len(segments) for segment_id in ids))

    def test_malformed_commercial_flank_follow_up_declines_without_cutting(self):
        segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"invented passage {index}")
            for index in range(12)
        ]
        llm = FakeLLM(
            commercial_preservation_answers=[
                self.preservation_labels(segments, **{"5": "commercial", "6": "commercial"}),
                '{"labels":{}}',
            ]
        )
        preserved, details = self.preserve(llm, segments, (3, 4))
        self.assertIsNone(preserved)
        self.assertIn("invalid shape", details["ads.detect.recovery.skipped"])

    def test_conflicting_evidence_cta_destination_cue_recovers_ground_news_like_midroll(self):
        # Synthetic Ground News-like host midroll:
        # Cue 0: programme context before
        # Cues 1-2: sponsor read narrative/body
        # Cue 3: CTA and destination initially mislabelled as programme
        # Cue 4: programme context resumes
        segments = [
            FakeSegment(0.0, 20.0, "the hosts discuss the news and interview the panel"),
            FakeSegment(20.0, 40.0, "our sponsor helps you see every side of every story"),
            FakeSegment(40.0, 60.0, "compare coverage and see bias charts for yourself"),
            FakeSegment(60.0, 80.0, "go check them out at example dot com slash news and get started today"),
            FakeSegment(80.0, 100.0, "welcome back to our ongoing reporting and analysis"),
        ]
        # Initially preservation labels cue 3 as programme
        preservation = json.dumps({"labels": {
            "0": "programme", "1": "commercial", "2": "commercial", "3": "programme", "4": "programme"
        }})
        llm = FakeLLM(
            commercial_ad_ids=[1, 2, 3],
            commercial_preservation_answer=preservation,
            commercial_conflict_answer=json.dumps({"classification": "commercial"}),
        )
        preserved, details = self.preserve(llm, segments, (1, 2, 3))
        self.assertEqual(preserved, (1, 2, 3))
        self.assertEqual(
            details["ads.detect.commercial.conflict.resolved"],
            "candidate ID 3 resolved to commercial",
        )

    def test_conflicting_evidence_review_preserves_actual_programme_and_mixed_cues(self):
        segments = [
            FakeSegment(0.0, 20.0, "programme before"),
            FakeSegment(20.0, 40.0, "sponsor read message body"),
            FakeSegment(40.0, 60.0, "go check them out at example dot com slash show and get started today"),
            FakeSegment(60.0, 80.0, "programme after"),
        ]
        preservation = json.dumps({"labels": {
            "0": "programme", "1": "commercial", "2": "programme", "3": "programme"
        }})
        # When conflict review confirms actual programme, audio is preserved
        llm_prog = FakeLLM(
            commercial_ad_ids=[1, 2],
            commercial_preservation_answer=preservation,
            commercial_conflict_answer=json.dumps({"classification": "programme"}),
        )
        preserved_prog, details_prog = self.preserve(llm_prog, segments, (1, 2))
        self.assertIsNone(preserved_prog)
        self.assertEqual(
            details_prog["ads.detect.commercial.conflict.preserved"],
            "candidate ID 2 confirmed as programme",
        )

        # When conflict review classifies as mixed, audio is preserved
        llm_mixed = FakeLLM(
            commercial_ad_ids=[1, 2],
            commercial_preservation_answer=preservation,
            commercial_conflict_answer=json.dumps({"classification": "mixed"}),
        )
        preserved_mixed, details_mixed = self.preserve(llm_mixed, segments, (1, 2))
        self.assertIsNone(preserved_mixed)
        self.assertEqual(
            details_mixed["ads.detect.commercial.conflict.preserved"],
            "candidate ID 2 confirmed as mixed",
        )

    def test_conflicting_evidence_review_fails_closed_on_malformed_response(self):
        segments = [
            FakeSegment(0.0, 20.0, "programme before"),
            FakeSegment(20.0, 40.0, "sponsor read message body"),
            FakeSegment(40.0, 60.0, "go check them out at example dot com and get started today"),
            FakeSegment(60.0, 80.0, "programme after"),
        ]
        preservation = json.dumps({"labels": {
            "0": "programme", "1": "commercial", "2": "programme", "3": "programme"
        }})
        llm = FakeLLM(
            commercial_ad_ids=[1, 2],
            commercial_preservation_answer=preservation,
            commercial_conflict_answer="not json",
        )
        preserved, details = self.preserve(llm, segments, (1, 2))
        self.assertIsNone(preserved)
        self.assertIn("conflict review failed", details["ads.detect.commercial.conflict.skipped"])

    def test_mixed_preservation_label_is_never_overridden_by_conflict_review(self):
        segments = [
            FakeSegment(0.0, 20.0, "programme before"),
            FakeSegment(20.0, 40.0, "sponsor read message body"),
            FakeSegment(40.0, 60.0, "go check them out at example dot com and get started today"),
            FakeSegment(60.0, 80.0, "programme after"),
        ]
        preservation = json.dumps({"labels": {
            "0": "programme", "1": "commercial", "2": "mixed", "3": "programme"
        }})
        llm = FakeLLM(
            commercial_ad_ids=[1, 2],
            commercial_preservation_answer=preservation,
            commercial_conflict_answer=json.dumps({"classification": "commercial"}),
        )
        preserved, details = self.preserve(llm, segments, (1, 2))
        self.assertIsNone(preserved)
        self.assertIn("intersects the proposed cut at IDs 2", details["ads.detect.recovery.skipped"])
        self.assertFalse(any(wp.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT == p for p in llm.request_prompts))
