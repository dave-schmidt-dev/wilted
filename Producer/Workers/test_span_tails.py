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

class StraddlingSpanTailTests(unittest.TestCase):
    """Every span ends on a cue edge; only some of those cues are all advertising."""

    # Twenty-second cues, so a span ending at 200.0 ends on cue 9's edge and
    # trimming it hands back 180.0-200.0. The shape of TechCrunch Daily's
    # failure, where cue 9 held the sponsor sign-off and then the host's
    # lead-in to the episode.
    SEGMENTS = [FakeSegment(index * 20.0, index * 20.0 + 20.0, f"segment {index}") for index in range(28)]

    def trim(self, llm, *ads):
        ads_module = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        pattern = wp.explicit_sponsor_opening_pattern(ads_module)
        stream = io.StringIO()
        with redirect_stderr(stream):
            trimmed = wp.trim_straddling_span_tails(
                ads_module, llm, self.SEGMENTS, list(ads), pattern
            )
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        return [(ad.start_s, ad.end_s) for ad in trimmed], details

    def test_a_tail_cue_holding_the_program_start_is_handed_back(self):
        llm = FakeLLM(boundary_starts_program=True)
        trimmed, details = self.trim(llm, FakeAd(6.72, 200.0))
        self.assertEqual(trimmed, [(6.72, 180.0)])
        self.assertIn("the program starts inside segment 9", details["ads.detect.tail.shortened"])

    def test_a_tail_cue_that_is_advertising_throughout_is_left_alone(self):
        # The safeguard has to be able to answer "no". A span whose last cue is
        # all advertising keeps its full length, or every correct cut loses its
        # final cue to a safeguard meant for a rarer failure.
        llm = FakeLLM(boundary_starts_program=False)
        trimmed, details = self.trim(llm, FakeAd(6.72, 200.0))
        self.assertEqual(trimmed, [(6.72, 200.0)])
        self.assertNotIn("ads.detect.tail.shortened", details)

    def test_an_unanswerable_probe_leaves_the_span_exactly_as_it_was(self):
        # The one place this safeguard does NOT inherit the usual "no answer is
        # not permission" rule. It screens every span in the episode rather than
        # one boundary already nominated, so trimming on silence would let a
        # single bad response shave the tail off every correct cut in the file.
        llm = FakeLLM(answer="not json")
        trimmed, details = self.trim(llm, FakeAd(6.72, 200.0))
        self.assertEqual(trimmed, [(6.72, 200.0)])
        self.assertIn("ads.detect.tail.unanswered", details)
        self.assertNotIn("ads.detect.tail.shortened", details)

    def test_a_span_ending_mid_cue_is_not_a_straddle_and_is_untouched(self):
        # Already refined off a cue edge by something upstream, so there is no
        # tail cue to hand back and nothing to ask about.
        llm = FakeLLM(boundary_starts_program=True)
        trimmed, details = self.trim(llm, FakeAd(6.72, 193.4))
        self.assertEqual(trimmed, [(6.72, 193.4)])
        self.assertNotIn("ads.detect.tail.shortened", details)

    def test_trimming_never_empties_a_span_confined_to_one_cue(self):
        # The cut lives entirely inside cue 9, so stopping at that cue's start
        # would invert the span. Leave it whole instead.
        llm = FakeLLM(boundary_starts_program=True)
        trimmed, details = self.trim(llm, FakeAd(185.0, 200.0))
        self.assertEqual(trimmed, [(185.0, 200.0)])
        self.assertNotIn("ads.detect.tail.shortened", details)

    def test_the_probe_count_is_bounded_across_many_spans(self):
        # One probe per span tail, but a transcript of many short spans must
        # not turn the safeguard into a second unbounded pass over the episode.
        llm = FakeLLM(boundary_starts_program=True)
        spans = [FakeAd(index * 20.0, index * 20.0 + 40.0) for index in range(0, 24, 2)]
        trimmed, _details = self.trim(llm, *spans)
        shortened = sum(
            1 for (start, end), ad in zip(trimmed, spans) if end != ad.end_s
        )
        self.assertEqual(shortened, wp.STRADDLING_TAIL_MAX_PROBES)

class LegacySponsorOpeningCompatibilityTests(unittest.TestCase):
    def test_observed_openings_match_both_legacy_anchor_patterns(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        openings = (
            "our show this week brought to you by superhuman",
            "this week in tech brought to you this week by claud",
            "i show today brought to you by doppel",
        )
        for opening in openings:
            with self.subTest(opening=opening):
                self.assertIsNotNone(ads._SPONSOR_OPENING_RE.search(opening))
                self.assertIsNotNone(ads._EXPLICIT_HOST_READ_OPENING_RE.search(opening))

    def test_support_for_the_show_is_not_installed_into_either_archive_pattern(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        openings = (
            "support for the show comes from grokipedia",
            "support for this show comes from acme",
        )
        for opening in openings:
            with self.subTest(opening=opening):
                self.assertIsNone(ads._SPONSOR_OPENING_RE.search(opening))
                self.assertIsNone(ads._EXPLICIT_HOST_READ_OPENING_RE.search(opening))

    def test_repeated_install_keeps_both_legacy_patterns_unchanged(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        once = (ads._SPONSOR_OPENING_RE.pattern, ads._EXPLICIT_HOST_READ_OPENING_RE.pattern)
        wp.install_legacy_sponsor_opening_compatibility(ads)
        self.assertEqual(
            (ads._SPONSOR_OPENING_RE.pattern, ads._EXPLICIT_HOST_READ_OPENING_RE.pattern),
            once,
        )

    def test_editorial_sentence_is_not_an_opening(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        editorial = "this week in tech brought a guest to your attention before the interview"
        self.assertIsNone(ads._SPONSOR_OPENING_RE.search(editorial))
        self.assertIsNone(ads._EXPLICIT_HOST_READ_OPENING_RE.search(editorial))

    def test_missing_legacy_anchor_is_a_contract_failure(self):
        ads = install_fake_ads(FakeLLM())
        del ads._SPONSOR_OPENING_RE
        with self.assertRaises(AttributeError):
            wp.install_legacy_sponsor_opening_compatibility(ads)

class ProducedDisclaimerEvidenceTests(unittest.TestCase):
    """The gate that decides whether a one- or two-segment flagged run survives.

    The archived detector asks `any(pattern.search(text))` over its cue tuple
    and discards the run when nothing matches. These tests ask the same
    question of the tuple this worker installs.
    """

    # As the detector saw it: a produced brand spot naming no price, no
    # address and no offer code, which the gate discarded on The Daily's
    # Hegseth episode.
    CHASE_SPOT = (
        "with my sapphire preferred card we took a trip to a desert oasis earning five times the points on chase travel two times the points on all other travel plus a hundred dollar hotel credit chase sapphire preferred a card that's preferred for a reason cards issued by jp morgan chase bank and a member of fdic subject to credit approval terms apply"
    )
    # The pre-roll from the same episode, produced copy of the same shape.
    YOUTUBE_SPOT = (
        "if you like youtube you'll love youtube premium hi i'm haley bailey with youtube premium i get ad free videos offline downloads background play and so much more so try youtube premium for two months free at youtube dot com slash premium trial eligibility varies terms apply cancel any time"
    )

    def evidenced(self, ads, text):
        return any(pattern.search(text) for pattern in ads._SPARSE_PROMO_CUES)

    def test_a_produced_spot_reciting_terms_survives_the_sparse_gate(self):
        ads = install_fake_ads(FakeLLM())
        self.assertFalse(
            self.evidenced(ads, self.CHASE_SPOT),
            "the archive's own cues are what let this spot through in the first place",
        )
        wp.install_produced_disclaimer_evidence(ads)
        self.assertTrue(self.evidenced(ads, self.CHASE_SPOT))

    def test_a_produced_spot_naming_a_domain_needs_no_help(self):
        ads = install_fake_ads(FakeLLM())
        self.assertTrue(
            self.evidenced(ads, self.YOUTUBE_SPOT),
            "the archive already keeps this one for its address",
        )

    def test_editorial_speech_is_still_discarded(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_produced_disclaimer_evidence(ads)
        editorial = (
            "Ford rehired engineers after its AI rollout failed.",
            "The discussion turned to Ford's business strategy and recent layoffs.",
            "Analysts discussed the back-to-school event and its weak effect on retail demand.",
            "The panel debated whether seasonal sales still matter to shoppers.",
            "The same terms apply to the agreement the two sides signed last week.",
            "The bank issued a statement about the approval process for new accounts.",
        )
        for text in editorial:
            with self.subTest(text=text):
                self.assertFalse(self.evidenced(ads, text))

    def test_the_archive_cues_are_kept_and_the_new_one_goes_last(self):
        ads = install_fake_ads(FakeLLM())
        before = ads._SPARSE_PROMO_CUES
        wp.install_produced_disclaimer_evidence(ads)
        after = ads._SPARSE_PROMO_CUES
        self.assertEqual(after[: len(before)], before)
        self.assertEqual(len(after), len(before) + 1)
        # One caller slices the sponsor acknowledgement off the front to ask
        # for a commercial signal beyond it. Appending keeps that slice whole.
        self.assertEqual(after[-1].pattern, wp.PRODUCED_DISCLAIMER_CUE_PATTERN)

    def test_repeated_install_appends_once(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_produced_disclaimer_evidence(ads)
        once = ads._SPARSE_PROMO_CUES
        wp.install_produced_disclaimer_evidence(ads)
        self.assertEqual(ads._SPARSE_PROMO_CUES, once)

    def test_a_missing_archive_cue_tuple_is_a_contract_failure(self):
        ads = install_fake_ads(FakeLLM())
        del ads._SPARSE_PROMO_CUES
        with self.assertRaises(AttributeError):
            wp.install_produced_disclaimer_evidence(ads)

def install_legacy_recovery_fixture(llm: FakeLLM):
    """Exercise the detector seam, seed gate, and resume gate without a model.

    This is deliberately a small double of the legacy recovery path, not a
    second implementation of detection: the production bridge supplies the
    two anchors, while the fixture only models the legacy path's three
    observable gates (positive model seed, sponsor opening, and content
    resumption) and returns its recovered source boundaries.
    """
    ads = install_fake_ads(llm)

    def recover(segments, backend):
        seed_body, _ = backend.generate(
            "classify", "positive sponsor candidate", response_format={"type": "json_object"}
        )
        seed = json.loads(seed_body)
        if not seed.get("ads"):
            return []
        for index, segment in enumerate(segments[:-1]):
            if not ads._SPONSOR_OPENING_RE.search(segment.text):  # noqa: SLF001
                continue
            if not ads._EXPLICIT_HOST_READ_OPENING_RE.search(segment.text):  # noqa: SLF001
                continue
            resume = next(
                (
                    candidate
                    for candidate in segments[index + 1 :]
                    if re.search(r"\bback\s+to\s+(?:the\s+)?(?:show|content)\b", candidate.text, re.I)
                ),
                None,
            )
            if resume is not None:
                return [FakeAd(segment.start_s, resume.start_s, confidence=seed["ads"][0]["confidence"])]
        return []

    ads.detect_ads = recover
    return ads

class LegacySponsorRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def test_positive_seed_and_verified_resumption_return_exact_superhuman_boundary(self):
        llm = FakeLLM(answer=json.dumps({"ads": [{"confidence": 0.97}]}))
        ads = install_legacy_recovery_fixture(llm)
        segments = [
            FakeSegment(212.25, 216.0, "our show this week brought to you by superhuman"),
            FakeSegment(216.0, 248.75, "this is the sponsor message"),
            FakeSegment(248.75, 252.0, "and now back to the show"),
        ]
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=300.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(
            spans,
            [{"startSeconds": 212.25, "endSeconds": 248.75, "label": "sponsor", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.97}],
        )
        # Three calls: the classifier, the resumption probe, and the tail
        # straddle probe the span-tail safeguard asks about segment 1, whose
        # end the recovered span lands on. That probe cannot read this
        # fixture's seed answer, so it returns no verdict and the boundary
        # above is the untrimmed one.
        self.assertEqual(
            llm.requests,
            [ads._AD_DETECT_RESPONSE_FORMAT, {"type": "json_object"}, {"type": "json_object"}],
        )

    def test_positive_seed_without_sponsor_opening_is_editorial_content(self):
        llm = FakeLLM(answer=json.dumps({"ads": [{"confidence": 0.97}]}))
        install_legacy_recovery_fixture(llm)
        segments = [
            FakeSegment(212.25, 216.0, "this week brought a guest to your attention"),
            FakeSegment(216.0, 248.75, "and now back to the show"),
        ]
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=300.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(spans, [])
