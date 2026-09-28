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

class PrerollPromptWordingTests(unittest.TestCase):
    """Pin the two clauses a measured experiment proved the opening needs.

    The gate cannot run the detector -- that needs a four-gigabyte model -- so
    nothing else here would notice these being reworded. They are not style: the
    first stopped Pop Culture Happy Hour losing twenty seconds of its premise,
    and removing either returns the opening to deciding advertising by how a
    passage sounds rather than by what it does. `make ad-corpus-replay` is what
    re-measures them; this only makes a silent revert impossible.
    """

    def prompts(self):
        return (wp.PREROLL_PROGRAM_START_PROMPT, wp.PREROLL_CONFIRM_PROMPT)

    def test_both_opening_questions_count_the_show_s_own_subject_as_program(self):
        for prompt in self.prompts():
            self.assertIn("reporting or discussion", prompt)

    def test_both_opening_questions_refuse_to_be_fooled_by_a_conversational_advertisement(self):
        for prompt in self.prompts():
            self.assertIn("however conversational its voice", prompt)

    def test_the_confirmation_does_not_single_out_a_self_naming_promoter(self):
        # Tried on 2026-09-05 and measured strictly worse: Waveform did not move
        # and Pop Culture Happy Hour went back to losing its premise. It reads
        # like a tightening, so this says plainly that it was tested.
        self.assertNotIn("names themselves", wp.PREROLL_CONFIRM_PROMPT)

class TranscriptStartPrerollRecoveryTests(unittest.TestCase):
    """`recover_transcript_start_preroll` called directly, to reach the guard
    cases the corpus-level `AdDetectionTests` do not exercise on their own:
    the confirmation answered, the confirmation unanswerable, and the two
    guards (already-claimed, under the minimum) that skip it outright. Also
    pins the `ads.detect.preroll.nominated` progress line added on 2026-09-05,
    which is what first showed the nomination question itself over-nominating
    on Waveform -- see the history note above `PREROLL_PROGRAM_START_PROMPT`.
    """

    def preroll(self, llm, segments, detections=()):
        ads = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        stream = io.StringIO()
        with redirect_stderr(stream):
            result = wp.recover_transcript_start_preroll(ads, llm, segments, list(detections))
        details = {json.loads(line)["stage"]: json.loads(line)["detail"]
                   for line in stream.getvalue().splitlines()}
        return result, details

    def segments(self):
        return [FakeSegment(i * 20.0, i * 20.0 + 20.0, f"segment {i}") for i in range(6)]

    def existing(self):
        return [FakeAd(150.0, 180.0, label="sponsor_read")]

    def test_a_confirmation_that_finds_no_program_content_is_cut_and_merged(self):
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=-1)
        result, _details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in result],
            [(0.0, 100.0, "ad_break"), (150.0, 180.0, "sponsor_read")],
        )

    def test_a_confirmation_that_finds_the_hosts_at_the_top_leaves_detections_unchanged(self):
        # Program content at the first ID or the one after it is a cold open
        # the nomination should never have claimed, and nothing may be cut.
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=1)
        result, details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in result],
                          [(150.0, 180.0, "sponsor_read")])
        self.assertIn("program content at 1", details["ads.detect.preroll.skipped"])

    def test_a_confirmation_that_finds_the_program_further_in_shortens_the_cut(self):
        # Economics of Everyday Things 70: the nomination put the program at
        # 185.8s, the confirmation found it at ID 5, and abandoning the whole
        # recovery left the episode opening on two untouched sponsor reads.
        # The confirmation read that passage, so its boundary is the one taken.
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=2)
        result, details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in result],
                          [(0.0, 40.0, "ad_break"), (150.0, 180.0, "sponsor_read")])
        self.assertEqual(details["ads.detect.preroll.shortened"],
                         "program moved to ID 2 at 40.000s")

    def test_a_shortened_boundary_under_the_minimum_cuts_nothing(self):
        segments = [FakeSegment(i * 4.0, i * 4.0 + 4.0, f"segment {i}") for i in range(6)]
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=2)
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(150.0, 180.0)])
        self.assertIn("shortened opening is only 8.0s long",
                      details["ads.detect.preroll.skipped"])

    def test_an_unanswerable_confirmation_leaves_detections_unchanged(self):
        # `answer` is the detector's own "[]", which is not a program_id
        # object: a malformed completion leaves the audio alone.
        llm = FakeLLM(preroll_program_start_id=5, answer="not json")
        result, details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in result],
                          [(150.0, 180.0, "sponsor_read")])
        self.assertIn("opening confirmation failed", details["ads.detect.preroll.skipped"])

    def test_a_program_starting_at_the_first_segment_asks_no_confirmation_question(self):
        llm = FakeLLM(preroll_program_start_id=0)
        result, _details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(150.0, 180.0)])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_id"], [])

    def test_an_opening_the_detector_already_claimed_asks_no_questions_at_all(self):
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=-1)
        existing = [FakeAd(0.5, 30.0, label="sponsor_read")]
        result, _details = self.preroll(llm, self.segments(), existing)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(0.5, 30.0)])
        self.assertEqual(llm.requests, [])

    def test_a_nominated_boundary_under_the_minimum_asks_no_confirmation_question(self):
        segments = [FakeSegment(0.0, 5.0, "segment 0"), FakeSegment(5.0, 10.0, "segment 1"),
                    FakeSegment(10.0, 15.0, "segment 2")]
        llm = FakeLLM(preroll_program_start_id=1)
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual([(ad.start_s, ad.end_s) for ad in result], [(150.0, 180.0)])
        self.assertIn("only 5.0s long", details["ads.detect.preroll.skipped"])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_id"], [])

    def test_the_nomination_progress_line_reports_the_nominated_id_and_seconds(self):
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=-1)
        _result, details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual(details["ads.detect.preroll.nominated"], "program ID 5 at 100.000s")

    def test_consecutive_preroll_extends_to_first_verified_programme_return(self):
        # Synthetic consecutive preroll:
        # Cues 0-1: sponsor 1 (Shopify-like e-commerce platform ad)
        # Cues 2-3: sponsor 2 (ChatGPT-like AI tool ad)
        # Cues 4-5: programme begins (editorial topic discussion)
        segments = [
            FakeSegment(0.0, 20.0, "grow your business with an online store"),
            FakeSegment(20.0, 40.0, "sign up for a one dollar per month trial at acme dot com"),
            FakeSegment(40.0, 60.0, "introducing an assistant that can write code and summarize documents"),
            FakeSegment(60.0, 80.0, "try it today and get started"),
            FakeSegment(80.0, 100.0, "welcome back to the programme and our discussion today"),
            FakeSegment(100.0, 120.0, "our panel reports on the latest industry developments"),
        ]
        # Q1 identifies programme start at cue 4 (80.0s).
        # Q2 mistakenly identifies cue 2 (40.0s) as the start of the program because sponsor 2 began.
        # Preroll continuation review queries from cue 2 and identifies cue 4 (80.0s).
        llm = FakeLLM(
            preroll_program_start_id=4,
            preroll_program_id=2,
            preroll_continuation_id=4,
        )
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in result],
            [(0.0, 80.0, "ad_break"), (150.0, 180.0, "sponsor_read")],
        )
        self.assertEqual(
            details["ads.detect.preroll.shortened"],
            "program moved to ID 2 at 40.000s",
        )
        self.assertEqual(
            details["ads.detect.preroll.extended"],
            "opening extended to ID 4 at 80.000s",
        )

    def test_preroll_continuation_preserves_editorial_opening_when_programme_is_confirmed(self):
        # When Q2 shortened to an editorial cue (e.g. cue 2) and continuation finds
        # no further ad pod continuation (-1), shortened boundary is preserved.
        segments = [FakeSegment(i * 20.0, i * 20.0 + 20.0, f"segment {i}") for i in range(6)]
        llm = FakeLLM(
            preroll_program_start_id=5,
            preroll_program_id=2,
            preroll_continuation_id=-1,
        )
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in result],
            [(0.0, 40.0, "ad_break"), (150.0, 180.0, "sponsor_read")],
        )
        self.assertIn(
            "continuation found no subsequent programme return",
            details["ads.detect.preroll.continuation.skipped"],
        )

    def test_preroll_continuation_fails_closed_on_invalid_response(self):
        segments = [FakeSegment(i * 20.0, i * 20.0 + 20.0, f"segment {i}") for i in range(6)]
        llm = FakeLLM(
            preroll_program_start_id=5,
            preroll_program_id=2,
            preroll_continuation_answer="invalid json",
        )
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in result],
            [(0.0, 40.0, "ad_break"), (150.0, 180.0, "sponsor_read")],
        )
        self.assertIn(
            "opening continuation review failed",
            details["ads.detect.preroll.continuation.skipped"],
        )

    def test_preroll_continuation_is_strictly_capped_at_first_verified_programme_return(self):
        # Q1 verified programme return at cue 4 (80.0s).
        # Continuation tries to return cue 5 (100.0s).
        # The extension MUST be capped at cue 4, never overcutting verified programme.
        segments = [FakeSegment(i * 20.0, i * 20.0 + 20.0, f"segment {i}") for i in range(6)]
        llm = FakeLLM(
            preroll_program_start_id=4,
            preroll_program_id=2,
            preroll_continuation_id=5,
        )
        result, details = self.preroll(llm, segments, self.existing())
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in result],
            [(0.0, 80.0, "ad_break"), (150.0, 180.0, "sponsor_read")],
        )
        self.assertEqual(
            details["ads.detect.preroll.extended"],
            "opening extended to ID 4 at 80.000s",
        )
