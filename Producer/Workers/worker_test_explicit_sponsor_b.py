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

class ExplicitSponsorRecoveryMixinB:
    def test_transcript_start_anchor_also_preserves_an_interior_programme_cue(self):
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by acme"),
            FakeSegment(10.0, 20.0, "the guest answers the editorial question"),
            FakeSegment(20.0, 30.0, "visit acme dot com to get started today"),
            FakeSegment(30.0, 40.0, "more programme after the read"),
        ]
        spans, events = self.detect(
            segments, [], content_start_id=1, duration=500.0,
        )
        self.assertEqual(spans, [])
        self.assertIn("found programme before evidence", " ".join(event["detail"] for event in events))

    def test_generic_brought_to_you_without_cta_and_domain_does_not_cut(self):
        spans, events = self.detect(
            [
                FakeSegment(10.0, 20.0, "brought to you by our continuing editorial discussion"),
                FakeSegment(20.0, 30.0, "the interview continues without promotional copy"),
            ],
            [],
        )
        self.assertEqual(spans, [])
        self.assertIn("ads.detect.recovery.skipped", [event["stage"] for event in events])

    def test_raw_anchor_ids_are_unique_and_deterministic(self):
        segments = [FakeSegment(4066.16, 4076.0, "for the show comes from granola")]
        ads = install_fake_ads(FakeLLM())
        pattern = wp.explicit_sponsor_opening_pattern(ads)
        nominated = [
            (anchor_id, segments[anchor_id].start_s)
            for anchor_id in wp.explicit_sponsor_anchor_ids(segments, pattern)
        ]
        repeated = [
            (anchor_id, segments[anchor_id].start_s)
            for anchor_id in wp.explicit_sponsor_anchor_ids(segments, pattern)
        ]
        self.assertEqual(nominated, [(0, 4066.16)])
        self.assertEqual(repeated, nominated)

    def test_the_granola_variant_without_cta_and_domain_does_not_cut(self):
        segments = [
            FakeSegment(4066.16, 4076.0, "for the show comes from granola"),
            FakeSegment(4076.0, 4086.0, "the hosts continue their discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=1)
        self.assertEqual(spans, [])

    def test_the_missing_word_variant_rejects_offer_code_only_corroboration(self):
        segments = [
            FakeSegment(100.0, 110.0, "for this show comes from acme"),
            FakeSegment(110.0, 120.0, "use promo code acme and learn more today"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(spans, [])

    def test_the_generic_missing_leading_word_variant_cuts_with_full_corroboration(self):
        segments = [
            FakeSegment(100.0, 110.0, "for the show comes from acme"),
            FakeSegment(110.0, 120.0, "visit acme dot com to learn more"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(
            spans,
            [{"startSeconds": 100.0, "endSeconds": 120.0,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.8}],
        )

    def test_distant_domain_and_cta_still_require_verified_content_resumption(self):
        segments = [
            FakeSegment(10.0, 20.0, "this week in tech brought to you this week by claud"),
            FakeSegment(20.0, 30.0, "claude dot ai is the product address"),
            FakeSegment(30.0, 40.0, "the host changes topics"),
            FakeSegment(40.0, 50.0, "more editorial discussion follows"),
            FakeSegment(50.0, 60.0, "learn more about the unrelated story"),
        ]
        spans, events = self.detect(segments, [], content_start_id=99)
        self.assertEqual(spans, [])
        self.assertIn("ads.detect.recovery.skipped", [event["stage"] for event in events])

    def test_recovery_scan_stops_before_the_sixty_fifth_segment(self):
        segments = [
            FakeSegment(0.0, 1.0, "this week in tech brought to you this week by claud"),
            FakeSegment(1.0, 2.0, "claude dot ai has product details"),
        ]
        segments.extend(FakeSegment(float(index), float(index + 1), "filler") for index in range(2, 64))
        segments.append(FakeSegment(64.0, 65.0, "learn more today"))
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

    def test_recovery_scan_stops_after_ten_minutes(self):
        segments = [
            FakeSegment(0.0, 1.0, "this week in tech brought to you this week by claud"),
            FakeSegment(1.0, 2.0, "claude dot ai has product details"),
            FakeSegment(600.01, 601.0, "learn more today"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

    def test_a_sponsor_whose_address_is_ordinary_words_is_recovered_by_its_own_name(self):
        # Giant Bombcast 955 shipped with this ninety-second read intact. The
        # detector found the anchor and the recovery declined it: the address
        # is videogame.town, which an unpunctuated transcript writes as three
        # ordinary words, so every address pattern in the gate found nothing.
        # The sponsor's name came back thirteen times, which is what a read is.
        segments = [
            FakeSegment(3455.16, 3458.28, "this episode is brought to you by video game town"),
            FakeSegment(3458.28, 3470.52, "video game town is an independent media site with fascinating articles"),
            FakeSegment(3470.52, 3483.32, "video game town proudly presents the best in gaming coverage"),
            FakeSegment(3483.32, 3499.68, "video game town is run by two friends grant and jared"),
            FakeSegment(3499.68, 3517.76, "so check them out at video game town wherever you get your podcasts"),
            FakeSegment(3527.0, 3540.0, "holy moly don't get discombobulated folks"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(
            spans,
            # The receipt is 0.7: recurrence and the call to action were
            # observed, but no spoken address and no destination corroborate
            # them. It is the weaker of the recoveries this suite pins.
            [{"startSeconds": 3455.16, "endSeconds": 3517.76,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.7}],
        )

    def test_a_name_that_only_recurs_minutes_later_is_not_a_read(self):
        # Ten minutes is long enough for a topic to be named this often
        # honestly, so recurrence only counts while it is dense.
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by video game town"),
            FakeSegment(120.0, 130.0, "video game town came up again"),
            FakeSegment(240.0, 250.0, "video game town once more"),
            FakeSegment(360.0, 370.0, "video game town a third time"),
            FakeSegment(380.0, 390.0, "go check it out"),
            FakeSegment(400.0, 410.0, "back to the show"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

    def test_a_partner_named_mid_sentence_is_recovered(self):
        # Practical AI's Framer read, as the aligned transcript actually carries
        # it. Nothing announces the read: it opens inside a sentence about being
        # a business owner and names the sponsor as "our partner". Every window
        # covering it classified all four cues as content with the vanity URL and
        # the discount in plain view, so the anchor is the only thing left.
        segments = [
            FakeSegment(1117.52, 1137.70, "that's why i appreciate so much what our partner framer is doing framer is the"),
            FakeSegment(1137.70, 1157.80, "pro website builder for creators teams and businesses that want a professional site"),
            FakeSegment(1157.80, 1166.30, "you can learn more about framer"),
            FakeSegment(1166.90, 1186.92, "get started building for free today at framer dot com slash practical ai for thirty percent off"),
            FakeSegment(1186.92, 1194.80, "so that is super cool i'm going to borrow those techniques myself"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(
            spans,
            [{"startSeconds": 1117.52, "endSeconds": 1186.92,
              "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.8}],
        )

    def test_the_partner_anchor_names_the_sponsor_and_needs_one(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        pattern = wp.explicit_sponsor_opening_pattern(ads)
        self.assertIn(
            "framer",
            wp.explicit_sponsor_name_phrases(
                "what our partner framer is doing framer is the", pattern
            ),
        )
        # An anchor with nothing after it names nobody, so it can raise no
        # recurrence evidence and cannot carry a recovery on its own.
        self.assertEqual(wp.explicit_sponsor_name_phrases("thanks to our partner", pattern), [])

    def test_already_covered_explicit_anchor_does_not_add_a_cut(self):
        segments = [
            FakeSegment(100.0, 110.0, "this week in tech brought to you this week by claud"),
            FakeSegment(110.0, 120.0, "visit claude dot ai"),
            FakeSegment(120.0, 130.0, "learn more today"),
        ]
        spans, events = self.detect(segments, [FakeAd(99.0, 131.0)])
        self.assertEqual(len(spans), 1)
        self.assertEqual(spans[0]["startSeconds"], 99.0)
        self.assertNotIn("ads.detect.recovered", [event["stage"] for event in events])

    def test_anchor_prefix_adjoining_detected_read_extends_left(self):
        segments = [
            FakeSegment(0.0, 100.0, "programme before the ad"),
            FakeSegment(100.0, 110.0, "this episode is brought to you by simplisafe"),
            FakeSegment(110.0, 120.0, "simplisafe is advanced home security done right"),
            FakeSegment(120.0, 130.0, "twenty four seven professional monitoring protects your home"),
            FakeSegment(130.0, 140.0, "visit simplisafe dot com slash rogan to get started today"),
            FakeSegment(140.0, 200.0, "back to the conversation with our guest"),
        ]
        spans, events = self.detect(
            segments,
            [FakeAd(120.0, 140.0, label="sponsor_read")],
            content_start_id=5,
        )
        self.assertEqual(len(spans), 1)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (100.0, 140.0))
        self.assertIn("ads.detect.recovered", [event["stage"] for event in events])

    def test_false_editorial_prefix_before_detected_read_remains_uncut(self):
        segments = [
            FakeSegment(0.0, 100.0, "programme before the ad"),
            FakeSegment(100.0, 110.0, "this episode is brought to you by simplisafe"),
            FakeSegment(110.0, 120.0, "the host discusses an unrelated editorial topic"),
            FakeSegment(120.0, 130.0, "twenty four seven professional monitoring protects your home"),
            FakeSegment(130.0, 140.0, "visit simplisafe dot com slash rogan to get started today"),
            FakeSegment(140.0, 200.0, "back to the conversation with our guest"),
        ]
        spans, events = self.detect(
            segments,
            [FakeAd(120.0, 140.0, label="sponsor_read")],
            content_start_id=2,
        )
        self.assertEqual(len(spans), 1)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (120.0, 140.0))
        self.assertIn(
            "found programme before evidence",
            " ".join(event["detail"] for event in events if "detail" in event),
        )

    def test_literal_domain_and_cta_survive_realistic_cue_density(self):
        segments = [FakeSegment(0.0, 2.0, "this week in tech brought to you this week by claud")]
        segments.extend(FakeSegment(index * 2.0, index * 2.0 + 2.0, "product details") for index in range(1, 10))
        segments.append(FakeSegment(20.0, 22.0, "visit claude.ai"))
        segments.extend(FakeSegment(index * 2.0, index * 2.0 + 2.0, "more product details") for index in range(11, 20))
        segments.append(FakeSegment(40.0, 42.0, "get started today"))
        segments.extend(FakeSegment(index * 2.0, index * 2.0 + 2.0, "offer terms") for index in range(21, 40))
        segments.append(FakeSegment(80.0, 82.0, "back to the show"))
        spans, _events = self.detect(segments, [], content_start_id=40)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (0.0, 80.0))

    def test_a_false_left_probe_keeps_the_explicit_anchor_boundary(self):
        spans, events = self.consecutive_preroll(left_include=False)
        self.assertEqual(spans[0]["startSeconds"], 20.4)
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=false", left["detail"])

    def test_a_failed_left_probe_keeps_the_explicit_anchor_boundary(self):
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        ads._probe_boundary_candidate = mock.Mock(side_effect=RuntimeError("probe failed"))
        segments = [
            FakeSegment(0.24, 20.4, "produced conversational first sponsor spot"),
            FakeSegment(20.4, 32.88, "support for the show comes from acme"),
        ]
        stream = io.StringIO()
        with redirect_stderr(stream):
            start_s = wp.consecutive_preroll_start(ads, llm, segments, 1)
        self.assertEqual(start_s, 20.4)
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=unanswered", left["detail"])

    def test_a_left_gap_greater_than_fifteen_seconds_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 10.0, "produced promotion"),
            FakeSegment(25.01, 35.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 1), 25.01)
        self.assertEqual(llm.requests, [])
