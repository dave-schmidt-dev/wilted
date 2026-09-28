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
from worker_test_explicit_sponsor_b import ExplicitSponsorRecoveryMixinB

class ExplicitSponsorRecoveryTests(ExplicitSponsorRecoveryMixinB, unittest.TestCase):
    def setUp(self):
        self.audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def detect(self, segments, detections, content_start_id=None, duration=5000.0, **llm_kwargs):
        if content_start_id is None:
            content_start_id = max(1, len(segments) - 1)
        llm = FakeLLM(boundary_content_start_id=content_start_id, **llm_kwargs)
        self.last_llm = llm
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: list(detections)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=duration):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        return spans, events

    def test_unclaimed_claude_anchor_adds_and_sorts_the_fifth_span(self):
        segments = [
            FakeSegment(
                3813.36,
                3830.0,
                "sponsor i'm really excited this week in tech brought to you this week by claud",
            ),
            FakeSegment(3830.0, 3850.0, "claude dot ai has the full product details"),
            FakeSegment(4119.56, 4139.88, "learn more about claude today"),
            FakeSegment(4139.88, 4150.0, "back to our discussion of artificial intelligence"),
        ]
        existing = [
            FakeAd(900.0, 920.0),
            FakeAd(120.0, 140.0),
            FakeAd(450.0, 470.0),
            FakeAd(700.0, 720.0),
        ]
        spans, events = self.detect(segments, existing)
        self.assertEqual([span["startSeconds"] for span in spans], [120.0, 450.0, 700.0, 900.0, 3813.36])
        self.assertEqual(
            spans[-1],
            {"startSeconds": 3813.36, "endSeconds": 4139.88, "label": "sponsor_read",
             "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut",
             "confidence": 0.8},
        )
        recovered = next(event for event in events if event["stage"] == "ads.detect.recovered")
        self.assertIn("1 spans", recovered["detail"])
        self.assertIn("3813.360-4139.880", recovered["detail"])

    def test_cue_by_cue_review_recovers_a_bounded_explicit_read(self):
        segments = [
            FakeSegment(0.0, 10.0, "we were discussing the episode topic"),
            FakeSegment(10.0, 20.0, "the interview continues"),
            FakeSegment(20.0, 30.0, "this episode is brought to you by acme"),
            FakeSegment(30.0, 40.0, "visit acme dot com to get started today"),
            FakeSegment(40.0, 50.0, "now back to the episode discussion"),
            FakeSegment(50.0, 60.0, "the interview continues"),
        ]
        spans, _events = self.detect(
            segments, [], content_start_id=4, duration=500.0,
        )
        self.assertEqual(
            spans,
            [{"startSeconds": 20.0, "endSeconds": 40.0,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.8}],
        )

    def test_cue_by_cue_review_preserves_an_interior_programme_cue(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before the read"),
            FakeSegment(10.0, 20.0, "another programme cue before the read"),
            FakeSegment(20.0, 30.0, "this episode is brought to you by acme"),
            FakeSegment(30.0, 40.0, "the guest answers the editorial question"),
            FakeSegment(40.0, 50.0, "visit acme dot com to get started today"),
            FakeSegment(50.0, 60.0, "more programme after the read"),
        ]
        spans, events = self.detect(
            segments, [], content_start_id=3, duration=500.0,
        )
        self.assertEqual(spans, [])
        self.assertIn("found programme before evidence", " ".join(event["detail"] for event in events))



    def test_the_exact_granola_missing_leading_word_variant_recovers_on_raw_timing(self):
        # The single Parakeet 1.1B pass omitted only the leading word. This
        # narrow compatibility anchor still takes every boundary from its raw
        # cues and still needs CTA/domain evidence plus verified content return.
        segments = [
            FakeSegment(4066.16, 4076.0, "  for the show comes from granola"),
            FakeSegment(4076.0, 4095.0, "visit granola dot com for the details"),
            FakeSegment(4095.0, 4122.76, "learn more and get started today"),
            FakeSegment(4122.76, 4132.0, "back to the gadget discussion"),
        ]
        spans, events = self.detect(segments, [], content_start_id=3)
        self.assertEqual(
            spans,
            [{"startSeconds": 4066.16, "endSeconds": 4122.76,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.8}],
        )
        nominated = next(event for event in events if event["stage"] == "ads.detect.recovery.nominated")
        self.assertIn("raw anchor ID 0", nominated["detail"])
        self.assertIn("4066.160s", nominated["detail"])



    def test_the_granola_variant_requires_a_domain_not_only_name_recurrence(self):
        segments = [
            FakeSegment(100.0, 110.0, "for the show comes from granola"),
            FakeSegment(110.0, 120.0, "granola helps you work and granola keeps notes"),
            FakeSegment(120.0, 130.0, "try granola today and learn more"),
            FakeSegment(130.0, 140.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=3)
        self.assertEqual(spans, [])



    def test_editorial_non_anchor_phrasing_does_not_nominate(self):
        segments = [
            FakeSegment(100.0, 110.0, "the idea for the show comes from acme research"),
            FakeSegment(110.0, 120.0, "visit acme dot com to learn more"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(spans, [])
        self.assertNotIn("ads.detect.recovery.nominated", [event["stage"] for event in events])

    def test_post_cut_audit_fails_if_a_proposed_explicit_anchor_is_dropped(self):
        segments = [
            FakeSegment(0.0, 10.0, "support for the show comes from granola"),
            FakeSegment(10.0, 20.0, "visit granola dot com for the details"),
            FakeSegment(20.0, 30.0, "learn more and get started today"),
            FakeSegment(30.0, 40.0, "back to the gadget discussion"),
        ]
        with self.assertRaises(wp.WorkerError) as raised:
            self.detect(segments, [], content_start_id=3, duration=50.0)
        self.assertEqual(raised.exception.code, "ads-recovery-audit-failed")

    def test_cta_and_domain_without_explicit_anchor_does_not_cut(self):
        spans, events = self.detect(
            [FakeSegment(10.0, 20.0, "visit example dot com to learn more about this story")],
            [],
        )
        self.assertEqual(spans, [])
        self.assertNotIn("ads.detect.recovered", [event["stage"] for event in events])




    def test_numeric_and_editorial_slashes_are_not_domain_evidence(self):
        segments = [
            FakeSegment(0.0, 1.0, "this week in tech brought to you this week by claud"),
            FakeSegment(1.0, 2.0, "we are available 24/7 and/or whenever you need us"),
            FakeSegment(2.0, 3.0, "get started with the discussion"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])


    def test_a_recurring_name_without_a_call_to_action_does_not_cut(self):
        # Recurrence replaces the address, not the instruction. A company
        # discussed at length is still a company being discussed.
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by video game town"),
            FakeSegment(10.0, 20.0, "video game town keeps coming up in the news this week"),
            FakeSegment(20.0, 30.0, "video game town hired three people"),
            FakeSegment(30.0, 40.0, "video game town is still a small operation"),
            FakeSegment(40.0, 50.0, "anyway that was the news"),
        ]
        spans, events = self.detect(segments, [])
        self.assertEqual(spans, [])
        self.assertIn("ads.detect.recovery.skipped", [event["stage"] for event in events])


    def test_the_anchors_own_naming_is_not_recurrence(self):
        # "brought to you by Video Game Town Video Game Town is an independent"
        # is one naming run into the next sentence by a transcript with no
        # punctuation. Counting it would give every anchor a free mention.
        anchor = "this episode is brought to you by video game town video game town is an"
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        pattern = ads._EXPLICIT_HOST_READ_OPENING_RE
        counts = {}
        wp.count_sponsor_name_mentions(
            wp.sponsor_name_recurrence_text(anchor, pattern),
            wp.explicit_sponsor_name_phrases(anchor, pattern),
            counts,
        )
        self.assertEqual(counts.get("video game town", 0), 0)

    def test_evidence_patterns_cover_how_a_host_read_actually_reads(self):
        # Every one of these was a miss: `.town` is not in a 2005 top-level
        # domain list, and "check them out" is not "check it out".
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE.search("check them out at videogame.town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_DOT_DOMAIN_RE.search("that is videogame dot town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_CTA_RE.search("so check them out at videogame.town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_CTA_RE.search("and be sure to subscribe wherever you listen"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_SPOKEN_PATH_RE.search("directly support at patreon slash videogametown"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_OFFER_CODE_RE.search("use code wilted for ten percent off"))
        # A figure of speech is not an address, and a person is not a sponsor.
        self.assertIsNone(wp.EXPLICIT_SPONSOR_SPOKEN_PATH_RE.search("he is a writer slash producer"))
        self.assertIsNone(wp.EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE.search("we talked about that yesterday"))


    def test_a_business_partner_named_in_conversation_is_not_a_read(self):
        # "Our partner" is ordinary speech as well as sponsor language, which is
        # why anchoring on it is only safe while the recovery still demands its
        # two independent signals. A company discussed at length is a company
        # being discussed.
        segments = [
            FakeSegment(0.0, 10.0, "we built that integration with our partner northwind logistics last year"),
            FakeSegment(10.0, 20.0, "northwind logistics had run into exactly the same problem we did"),
            FakeSegment(20.0, 30.0, "northwind logistics eventually solved it in house"),
            FakeSegment(30.0, 40.0, "anyway back to the architecture question"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])



    def test_abutting_detection_does_not_claim_anchor_and_recovery_extends_it(self):
        segments = [
            FakeSegment(100.0, 110.0, "this week in tech brought to you this week by claud"),
            FakeSegment(110.0, 120.0, "visit claude.ai for the details"),
            FakeSegment(120.0, 130.0, "learn more and get started"),
            FakeSegment(130.0, 140.0, "back to the show"),
        ]
        spans, events = self.detect(segments, [FakeAd(90.0, 100.0)], content_start_id=3)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (90.0, 130.0))
        self.assertIn("ads.detect.recovered", [event["stage"] for event in events])

    def test_truncated_overlapping_detection_is_extended_to_verified_content(self):
        segments = [
            FakeSegment(100.0, 110.0, "this week in tech brought to you this week by claud"),
            FakeSegment(110.0, 120.0, "visit claude dot ai"),
            FakeSegment(120.0, 130.0, "learn more about the product"),
            FakeSegment(130.0, 140.0, "back to the show"),
        ]
        spans, _events = self.detect(segments, [FakeAd(99.0, 115.0)], content_start_id=3)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (99.0, 130.0))


    def test_anchor_prefix_overlapping_detected_read_extends_left(self):
        segments = [
            FakeSegment(0.0, 100.0, "programme before the ad"),
            FakeSegment(100.0, 115.0, "this episode is brought to you by shipstation"),
            FakeSegment(115.0, 130.0, "shipstation makes shipping simple for small businesses"),
            FakeSegment(130.0, 140.0, "visit shipstation dot com to get a sixty day free trial"),
            FakeSegment(140.0, 200.0, "programme content resumes here"),
        ]
        spans, events = self.detect(
            segments,
            [FakeAd(110.0, 140.0, label="sponsor_read")],
            content_start_id=4,
        )
        self.assertEqual(len(spans), 1)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (100.0, 140.0))
        self.assertIn("ads.detect.recovered", [event["stage"] for event in events])



    def consecutive_preroll(self, *, left_include=None, left_answer=None, anchor_start=20.4):
        segments = [
            FakeSegment(0.24, 20.4, "produced conversational first sponsor spot"),
            FakeSegment(anchor_start, 32.88, "support for the show comes from acme at acme dot com"),
            FakeSegment(33.52, 42.16, "the sponsor describes its service"),
            FakeSegment(42.72, 62.96, "visit today to learn more about the service"),
            FakeSegment(62.96, 66.08, "get started at acme dot com"),
            FakeSegment(68.48, 80.0, "the hosts begin the episode discussion"),
        ]
        llm = FakeLLM(
            boundary_content_start_id=5,
            left_boundary_include=left_include,
            left_boundary_answer=left_answer,
        )
        self.last_llm = llm
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: []
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=5000.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        return spans, [json.loads(line) for line in stream.getvalue().splitlines()]

    def test_consecutive_opening_spots_join_the_verified_anchor_to_transcript_start(self):
        spans, events = self.consecutive_preroll(left_include=True)
        self.assertEqual(
            spans,
            [{"startSeconds": 0.0, "endSeconds": 66.08,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.8}],
        )
        extended = next(
            event for event in events
            if event["stage"] == "ads.detect.recovery.preroll.extended"
        )
        self.assertIn("anchor ID 1", extended["detail"])
        self.assertIn("prefix ID 0", extended["detail"])


    def test_an_unanswered_left_probe_keeps_the_explicit_anchor_boundary(self):
        spans, events = self.consecutive_preroll(left_answer="not json")
        self.assertEqual(spans[0]["startSeconds"], 20.4)
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=unanswered", left["detail"])


    def test_a_non_opening_anchor_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 10.0, "editorial opening"),
            FakeSegment(10.0, 20.0, "produced promotion"),
            FakeSegment(20.0, 30.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 2), 20.0)
        self.assertEqual(llm.requests, [])

    def test_an_anchor_after_the_first_minute_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 50.0, "produced promotion"),
            FakeSegment(60.01, 70.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 1), 60.01)
        self.assertEqual(llm.requests, [])

