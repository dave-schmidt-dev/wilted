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

class SparseCommercialRecoveryTests(unittest.TestCase):
    """A sparse positive can nominate a read, never authorize one by itself."""

    @staticmethod
    def segments(texts, gaps_after=()):
        segments = []
        cursor = 0.0
        for index, text in enumerate(texts):
            segments.append(FakeSegment(cursor, cursor + 10.0, text))
            cursor += 10.0 + (6.0 if index in gaps_after else 0.0)
        return segments

    def recover(self, segments, ad_ids, programme_ids, seed_id, *, existing=(), llm=None):
        llm = llm or FakeLLM(commercial_ad_ids=ad_ids,
                            commercial_programme_ids=programme_ids)
        llm.load()
        ads = install_fake_ads(llm)
        candidates = () if existing else (
            wp.AuditCandidate("positive-missing-final-span", (seed_id,), "sparse positive"),
        )
        audit = wp.AdAnalysisAudit(candidates=candidates)
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = wp.recover_sparse_commercial_reads(
                ads, llm, segments, list(existing), 6000.0, audit
            )
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        return result, llm, events

    @staticmethod
    def prefix_review_llm(segments, prefix_ids, programme_ids, *, role="commercial", cue_role="commercial"):
        labels = {
            str(index): "programme" if index in prefix_ids or index in programme_ids else "commercial"
            for index in range(len(segments))
        }
        return FakeLLM(
            commercial_preservation_answer=json.dumps({"labels": labels}),
            commercial_prefix_role_answer=json.dumps({"classification": role}),
            commercial_prefix_cue_answer=json.dumps({"labels": {
                str(index): cue_role for index in prefix_ids
            }}),
        )

    def test_short_cta_cut_expands_to_whole_news_service_read(self):
        segments = self.segments([
            "the panel discusses the day's reporting",
            "the host follows up with an editorial question",
            "a comparison service can show different views of the same story",
            "the service displays each outlet's coverage",
            "its comparison tools help readers inspect bias",
            "the host explains how the paid service works",
            "an example of the service's comparison display",
            "more details about the paid plan",
            "the offer is available to listeners",
            "visit example dot com and get started with the offer",
            "the host returns to the panel's reporting",
        ], gaps_after=(1, 9))
        existing = (FakeAd(segments[9].start_s, segments[9].end_s, label="sponsor_read"),)
        self.assertEqual(wp.sparse_pause_envelope(segments, 9), tuple(range(2, 10)))
        llm = self.prefix_review_llm(segments, tuple(range(2, 9)), (0, 1, 10))
        result, llm, _events = self.recover(
            segments, list(range(2, 10)), [0, 1, 10], 9, existing=existing, llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[2].start_s, segments[9].end_s)])
        self.assertEqual(result[0].label, "sponsor_read")
        self.assertIn(wp.COMMERCIAL_PREFIX_ROLE_PROMPT, llm.request_prompts)
        self.assertIn(wp.COMMERCIAL_PREFIX_CUE_PROMPT, llm.request_prompts)

    def test_dropped_product_cue_recovers_apparel_read_without_cta_or_domain(self):
        segments = self.segments([
            "the guest finishes an editorial answer",
            "the host introduces the next discussion topic",
            "the host describes a company's socks and material",
            "the apparel maker has a comfort guarantee",
            "more product sizing and fabric details",
            "the host describes trying the socks at home",
            "the paid brand sells different styles",
            "the host continues the apparel offer",
            "the product message wraps up",
            "the hosts return to their interview",
        ], gaps_after=(1, 8))
        self.assertEqual(wp.sparse_pause_envelope(segments, 6), tuple(range(2, 9)))
        llm = self.prefix_review_llm(segments, (2, 3, 4), (0, 1, 9))
        result, _llm, _events = self.recover(
            segments, list(range(2, 9)), [0, 1, 9], 6, llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[2].start_s, segments[8].end_s)])

    def test_dropped_product_cue_recovers_pet_food_read_through_offer_tail(self):
        segments = self.segments([
            "the discussion reaches an editorial conclusion",
            "the hosts preview their next interview",
            "the host describes a delivered pet food product",
            "the subscription is tailored to each animal",
            "details of the recipe and shipping",
            "the host describes why the brand makes it",
            "the product message continues",
            "the classifier observed this product cue",
            "the host explains the plan options",
            "the host explains the first box",
            "the brand offers a listener discount",
            "more details about the pet food offer",
            "the offer has a destination at example dot com",
            "the commercial signs off",
            "the programme returns to the interview",
        ], gaps_after=(1, 13))
        self.assertEqual(wp.sparse_pause_envelope(segments, 7), tuple(range(2, 14)))
        llm = self.prefix_review_llm(segments, tuple(range(2, 7)), (0, 1, 14))
        result, _llm, _events = self.recover(
            segments, list(range(2, 14)), [0, 1, 14], 7, llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[2].start_s, segments[13].end_s)])

    def test_mixed_interior_cue_preserves_the_existing_short_cut(self):
        segments = self.segments([
            "programme before",
            "commercial opening",
            "commercial then the programme returns in this same cue",
            "visit example dot com and get started",
            "programme after",
        ], gaps_after=(0, 3))
        labels = json.dumps({"labels": {
            "0": "programme", "1": "commercial", "2": "mixed",
            "3": "commercial", "4": "programme",
        }})
        llm = FakeLLM(commercial_ad_ids=[1, 2, 3],
                      commercial_preservation_answer=labels)
        original = FakeAd(segments[3].start_s, segments[3].end_s, label="sponsor_read")
        result, _llm, events = self.recover(
            segments, [1, 2, 3], [0, 4], 3, existing=(original,), llm=llm
        )
        self.assertEqual(result, [original])
        self.assertTrue(any(event["stage"] == "ads.detect.sparse.prefix.preserved"
                            for event in events))

    def test_editorial_or_invalid_review_preserves_audio(self):
        segments = self.segments([
            "programme before", "product opening", "editorial discussion",
            "product detail", "programme after",
        ], gaps_after=(0, 3))
        for llm in (
            FakeLLM(commercial_ad_ids=[1, 2, 3],
                    commercial_programme_ids=[0, 2, 4]),
            FakeLLM(commercial_ad_ids=[1, 2, 3],
                    commercial_preservation_answer="invalid json"),
            FakeLLM(commercial_ad_ids=[1, 2, 3],
                    commercial_programme_ids=[]),
        ):
            with self.subTest(llm=llm):
                result, _llm, _events = self.recover(
                    segments, [1, 2, 3], [0, 4], 2, llm=llm
                )
                self.assertEqual(result, [])

    def test_prefix_review_preserves_audio_on_programme_mixed_or_invalid_responses(self):
        segments = self.segments([
            "editorial discussion", "visit example dot com to hear the product anecdote",
            "product details", "visit example dot com and get started",
            "editorial resumes",
        ], gaps_after=(0, 3))
        for role, cue_role in (("programme", "commercial"), ("mixed", "commercial"),
                               ("commercial", "programme"), ("commercial", "mixed"),
                               ("invalid", "commercial")):
            with self.subTest(role=role, cue_role=cue_role):
                llm = self.prefix_review_llm(segments, (1,), (0, 4),
                                             role=role, cue_role=cue_role)
                original = FakeAd(segments[3].start_s, segments[3].end_s,
                                  label="sponsor_read")
                result, llm, _events = self.recover(
                    segments, [1, 2, 3], [0, 4], 3, existing=(original,), llm=llm
                )
                if role == "invalid":
                    self.assertEqual(result, [original])
                else:
                    self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                                     [(segments[2].start_s, segments[3].end_s)])
                    self.assertGreater(result[0].start_s, segments[1].start_s)
                self.assertNotIn(wp.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
                                 llm.request_prompts)

    def test_editorial_inside_the_proposal_is_never_relabelled_as_a_prefix(self):
        segments = self.segments([
            "programme before", "product story", "editorial interview",
            "product offer", "programme after",
        ], gaps_after=(0, 3))
        llm = self.prefix_review_llm(segments, (2,), (0, 4))
        result, llm, _events = self.recover(
            segments, [1, 2, 3], [0, 4], 3, llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[3].start_s, segments[3].end_s)])
        self.assertNotIn(wp.COMMERCIAL_PREFIX_ROLE_PROMPT, llm.request_prompts)

    def test_one_disputed_lead_in_cue_is_kept_before_verified_commercial_suffix(self):
        segments = self.segments([
            "programme before", "the problem is introduced",
            "the service solves that problem", "the service features are explained",
            "the offer details continue", "visit example dot com and get started",
            "programme after",
        ], gaps_after=(0, 5))
        llm = self.prefix_review_llm(segments, (1, 2, 3, 4), (0, 6))
        llm.commercial_prefix_cue_answer = json.dumps({"labels": {
            "1": "programme", "2": "commercial", "3": "commercial", "4": "commercial",
        }})
        original = FakeAd(segments[5].start_s, segments[5].end_s,
                          label="sponsor_read")
        result, _llm, _events = self.recover(
            segments, [1, 2, 3, 4, 5], [0, 6], 5, existing=(original,), llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[2].start_s, segments[5].end_s)])

    def test_mixed_opening_is_kept_before_verified_product_pitch_suffix(self):
        segments = self.segments([
            "programme before", "host hands off to the break",
            "the brand begins its offer", "more sponsor details",
            "observed product cue", "the commercial signs off", "programme after",
        ], gaps_after=(0, 5))
        llm = self.prefix_review_llm(segments, (1, 2, 3), (0, 6), role="mixed")
        llm.commercial_prefix_cue_answer = json.dumps({"labels": {
            "1": "mixed", "2": "commercial", "3": "commercial",
        }})
        result, _llm, _events = self.recover(
            segments, [1, 2, 3, 4, 5], [0, 6], 4, llm=llm
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result],
                         [(segments[2].start_s, segments[5].end_s)])

    def test_keyword_in_editorial_pause_passage_cannot_trigger_single_cue_override(self):
        segments = self.segments([
            "programme before", "hosts discuss visiting example dot com",
            "the interview talks about products", "programme after",
        ], gaps_after=(0, 2))
        llm = FakeLLM(
            commercial_preservation_answer=json.dumps({"labels": {
                "0": "programme", "1": "programme", "2": "programme", "3": "programme",
            }}),
            commercial_conflict_answer=json.dumps({"classification": "commercial"}),
        )
        result, llm, _events = self.recover(
            segments, [1, 2], [0, 1, 2, 3], 1, llm=llm
        )
        self.assertEqual(result, [])
        self.assertNotIn(wp.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
                         llm.request_prompts)

    def test_a_short_cut_requires_whole_cue_evidence_before_expansion(self):
        segments = self.segments([
            "programme before", "visit example dot com and get started",
            "programme after",
        ])
        partial = FakeAd(11.0, 20.0, label="sponsor_read")
        result, llm, _events = self.recover(
            segments, [1], [0, 2], 1, existing=(partial,)
        )
        self.assertEqual(result, [partial])
        self.assertEqual(llm.request_prompts, [])

    def test_exhausted_sparse_review_budget_preserves_the_original_short_cut(self):
        segments = self.segments([
            "programme before", "visit example dot com and get started",
            "programme after",
        ], gaps_after=(0, 1))
        original = FakeAd(segments[1].start_s, segments[1].end_s,
                          label="sponsor_read")
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        exhausted = wp._CallBudgetBackend(llm, 0)
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = wp.recover_sparse_commercial_reads(
                ads, exhausted, segments, [original], 6000.0,
                wp.AdAnalysisAudit(),
            )
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(result, [original])
        self.assertEqual(exhausted.calls, 0)
        self.assertEqual(llm.requests, [])
        self.assertTrue(any(
            event["stage"] == "ads.detect.recovery.skipped"
            and "budget exhausted" in event["detail"]
            for event in events
        ))

    def test_pause_without_classifier_or_cut_evidence_never_nominates(self):
        segments = self.segments([
            "the interview pauses", "an editorial story continues",
            "the host asks another question",
        ], gaps_after=(0, 1))
        audit = wp.AdAnalysisAudit()
        self.assertEqual(wp.sparse_commercial_seeds(segments, [], audit), ())

    def test_consecutive_tiny_transition_cues_are_preserved_after_product_signoff(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme"),
            FakeSegment(16.0, 25.0, "a product pitch begins"),
            FakeSegment(25.5, 35.0, "the offer signs off"),
            FakeSegment(35.5, 35.8, "mm"),
            FakeSegment(36.0, 36.3, "yeah"),
            FakeSegment(42.0, 52.0, "programme resumes"),
        ]
        self.assertEqual(wp.sparse_pause_envelope(segments, 1), (1, 2))
        self.assertIsNone(wp.sparse_pause_envelope(self.segments([
            "programme", "positive cue", "programme"
        ]), 1))

class AdjacentAdPodContinuationTests(unittest.TestCase):
    SEGMENTS = [
        FakeSegment(6.720, 20.000, "verified Plaud commercial"),
        FakeSegment(20.000, 35.000, "commercial details"),
        FakeSegment(35.000, 50.000, "commercial details"),
        FakeSegment(50.000, 65.000, "commercial details"),
        FakeSegment(65.000, 78.000, "commercial details"),
        FakeSegment(78.000, 88.800, "end of the verified commercial"),
        FakeSegment(90.960, 105.000, "check us out and subscribe wherever you listen"),
        FakeSegment(105.000, 121.880, "the Motley Fool Money podcast"),
        FakeSegment(122.840, 140.000, "I'm Imran, and your Daily Crunch starts right now"),
        FakeSegment(140.000, 160.000, "Apple debuts its most powerful chip ever"),
    ]

    def analyze(self, llm, segments=None):
        llm.load()
        ads = install_fake_ads(llm, detections=[FakeAd(6.720, 88.800, label="sponsor_read")])
        with redirect_stderr(io.StringIO()):
            return wp.analyze_ad_detections(ads, llm, segments or self.SEGMENTS, 300.0)

    def test_verified_cut_extends_through_immediate_motley_fool_promotion(self):
        analysis = self.analyze(FakeLLM(
            preroll_program_start_id=0,
            adjacent_program_start_id=8,
        ))
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(6.720, 122.840, "sponsor_read")],
        )

    def test_immediate_programme_or_malformed_review_preserves_verified_cut(self):
        cases = (
            FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=6),
            FakeLLM(preroll_program_start_id=0, adjacent_program_start_answer="not json"),
        )
        for llm in cases:
            with self.subTest(answer=llm.adjacent_program_start_answer or llm.adjacent_program_start_id):
                analysis = self.analyze(llm)
                self.assertEqual(
                    [(ad.start_s, ad.end_s) for ad in analysis.detections],
                    [(6.720, 88.800)],
                )

    def test_only_a_gap_at_or_below_the_three_second_boundary_is_reviewed(self):
        just_inside = [*self.SEGMENTS]
        just_inside[6] = FakeSegment(91.800, 105.000, just_inside[6].text)
        inside = self.analyze(FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=8), just_inside)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in inside.detections], [(6.720, 122.840)])

        just_outside = [*self.SEGMENTS]
        just_outside[6] = FakeSegment(91.801, 105.000, just_outside[6].text)
        llm = FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=8)
        outside = self.analyze(llm, just_outside)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in outside.detections], [(6.720, 88.800)])
        self.assertFalse(any(request.get("field") == "program_start_id" for request in llm.requests))

    def test_out_of_window_or_over_budget_continuation_never_extends_the_cut(self):
        too_many = [*self.SEGMENTS[:6]]
        for index in range(13):
            start = 90.960 + index * 5
            too_many.append(FakeSegment(start, start + 5, f"promo cue {index}"))
        llm = FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=18)
        analysis = self.analyze(llm, too_many)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in analysis.detections], [(6.720, 88.800)])

        oversized = [*self.SEGMENTS]
        oversized[6] = FakeSegment(90.960, 105.000, "x" * (wp.COMMERCIAL_RECOVERY_CONTEXT_CHARS + 1))
        llm = FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=8)
        analysis = self.analyze(llm, oversized)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in analysis.detections], [(6.720, 88.800)])
        self.assertFalse(any(request.get("field") == "program_start_id" for request in llm.requests))

    def test_an_unverified_or_non_sponsor_detection_never_nominates_its_neighbour(self):
        detection = FakeAd(6.720, 88.800, label="ad_break")
        llm = FakeLLM(preroll_program_start_id=0, adjacent_program_start_id=8)
        llm.load()
        ads = install_fake_ads(llm, detections=[detection])
        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(ads, llm, self.SEGMENTS, 300.0)
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(6.720, 88.800, detection.label)],
        )
        self.assertFalse(any(request.get("field") == "program_start_id" for request in llm.requests))
