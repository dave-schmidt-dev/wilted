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

class AdDetectionMixinB:
    def test_a_run_the_detector_threw_away_is_named_in_the_journal(self):
        # The archive drops a flagged run it cannot evidence and says so at
        # INFO, below the level the warning forwarder relays. Without this,
        # a missing advertisement cannot be told apart from one that was never
        # flagged, and the two want different fixes.
        llm = FakeLLM()
        ads = install_fake_ads(llm)
        logger = logging.getLogger("wilted.ads")

        def detect(segments, _backend):
            logger.info("Discarding sparse ad run %d-%d without promotional evidence", 0, 1)
            logger.info("Discarding self-promo housekeeping run %d-%d", 1, 1)
            return []

        ads.detect_ads = detect
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        detail = next(json.loads(line)["detail"] for line in stream.getvalue().splitlines()
                      if json.loads(line)["stage"] == "ads.detect.discarded")
        self.assertIn("2 flagged runs dropped", detail)
        # With clock times, because a segment ID means nothing after the run.
        self.assertIn("(0.0-4.0s)", detail)
        self.assertIn("(2.0-4.0s)", detail)

    def test_the_detector_log_level_is_put_back_after_detection(self):
        # The level is lifted only for the length of the detection; leaving it
        # raised would relay every INFO line the archive writes for the rest of
        # the run.
        logger = logging.getLogger("wilted.ads")
        logger.setLevel(logging.ERROR)
        self.addCleanup(logger.setLevel, logging.NOTSET)
        llm = FakeLLM()
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(logger.level, logging.ERROR)
        self.assertEqual([h for h in logger.handlers if isinstance(h, wp.DiscardedRuns)], [])

    def test_an_ordinary_ad_break_is_left_alone_by_the_size_guard(self):
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(6.72, 187.0, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=563.17):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual([span["startSeconds"] for span in spans], [6.72])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertNotIn("ads.detect.span.rejected", stages)

    def test_a_shortened_span_holding_program_content_is_left_alone(self):
        # A retry that cannot produce a valid answer may not vouch for the
        # original span or guess its safe prefix.
        llm = FakeLLM(
            preroll_program_start_id=9,
            program_id_answers=[3],
            boundary_starts_program=False,
        )
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("safe-prefix confirmation failed", details["ads.detect.span.resize.skipped"])
        self.assertNotIn(wp.OVERSIZED_SPAN_RESCAN_PROMPT, llm.request_prompts)
        self.assertEqual(self.confirmed, frozenset())

    def test_a_span_the_review_calls_advertising_throughout_is_confirmed(self):
        # Reading the whole span and finding no programme in it is an answer,
        # not a failure to answer. A short news alert can legitimately be
        # mostly advertising, so the verdict stands and the span is vouched for.
        llm = FakeLLM(preroll_program_start_id=-1)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("advertising throughout", details["ads.detect.span.confirmed"])
        self.assertEqual(self.confirmed, frozenset({(6.72, 456.88)}))

    def test_a_confirmed_span_over_the_total_ceiling_is_held_without_a_cut(self):
        confirmed = frozenset({(6.72, 292.64)})
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans([FakeAd(6.72, 292.64)], 459.0, confirmed)
        self.assertEqual(kept, [])
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        held = [event for event in events if event["stage"] == "ads.detect.span.held"]
        self.assertEqual(len(held), 1)
        self.assertIn("6.720-292.640", held[0]["detail"])
        self.assertIn("62% of the episode", held[0]["detail"])

    def test_a_fully_confirmed_cut_that_crosses_the_programme_floor_keeps_the_episode_whole(self):
        # The floor binds even when every span was vouched for: a review that
        # reads 95% of an episode as advertising is a detector failure that no
        # confirmation can rescue, not a verdict.
        confirmed = frozenset({(0.0, 570.0)})
        self.assertLess(1 - 570.0 / 600.0, wp.MINIMUM_PROGRAMME_SHARE)
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans([FakeAd(0.0, 570.0)], 600.0, confirmed)
        self.assertEqual(kept, [])
        self.assertIn("keeping the episode whole", stream.getvalue())

    def test_unreviewed_spans_have_a_tighter_bound_than_the_total(self):
        # Two spans that are each plausible add up past half the episode with
        # nothing vouching for either. The total ceiling alone would permit
        # that until 60%; the unreviewed bound is the extra, tighter net, and
        # it is additional to the total rather than a replacement for it.
        self.assertLess(wp.MAXIMUM_UNCONFIRMED_AD_SHARE, wp.MAXIMUM_TOTAL_AD_SHARE)
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(0.0, 150.0), FakeAd(200.0, 360.0)], 600.0
            )
        # 310 of 600 seconds is 52%: under the 60% total, over the 50% bound.
        self.assertEqual(kept, [])
        self.assertIn("without review", stream.getvalue())

    def test_the_unconfirmed_bound_with_nothing_vouched_keeps_the_episode_whole(self):
        # The same tighter net with no verdict to fall back on: there is no
        # vouched-for set to keep, so the correct disposition is the whole
        # episode, and the refusal has to say so rather than name a set that
        # does not exist.
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(0.0, 180.0), FakeAd(220.0, 360.0)], 600.0
            )
        self.assertEqual(kept, [])
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        self.assertIn("without review", details["ads.detect.refused"])
        self.assertIn("keeping the episode whole", details["ads.detect.refused"])

    def test_the_rescan_asks_a_different_question_than_the_first_review(self):
        self.assertNotIn("program_start_id", wp.OVERSIZED_SPAN_RESCAN_PROMPT)
        self.assertIn("advertisement_evidence_id", wp.OVERSIZED_SPAN_RESCAN_PROMPT)
        self.assertIn("second time", wp.OVERSIZED_SPAN_RESCAN_PROMPT)
        self.assertIn("Do not\nlook for a boundary", wp.OVERSIZED_SPAN_RESCAN_PROMPT)
        for confusable in ("interviews", "host introductions", "credits", "length is not evidence"):
            self.assertIn(confusable, wp.OVERSIZED_SPAN_RESCAN_PROMPT)

    def test_an_unanswered_resize_review_never_shortens_a_span(self):
        llm = FakeLLM(answer="not json")
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("resize review failed", details["ads.detect.span.resize.skipped"])

    def test_a_produced_spot_after_the_sign_off_is_cut_to_the_end_of_the_file(self):
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm)
        # To the probed duration, not to the last cue: what lies between them is
        # the spot's own music bed.
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in recovered],
                         [(760.0, 810.0, "ad_break")])
        # The receipt is the opening's mirror: the closing review found the
        # appended spot, the confirmation agreed, and the tail is well over the
        # floor, so the produced span reports the band's measured ceiling.
        self.assertEqual(recovered[0].confidence, wp.RECOVERED_CONFIDENCE_CEILING)
        self.assertNotEqual(recovered[0].confidence, 1.0)
        # The closing review is the pass that positively established this run
        # as the sign-off/credits/music-bed shape; a mid-roll produced break
        # stays paid advertising.
        self.assertEqual(recovered[0].kinds, ("credits",))
        self.assertIn("after program ID 19", details["ads.detect.postroll"])

    def test_a_clean_postroll_break_skips_the_tail_probe(self):
        segments = [
            FakeSegment(0.0, 500.0, "invented programme discussion"),
            FakeSegment(500.0, 537.68, "invented programme sign-off"),
            FakeSegment(543.24, 580.0, "invented promotion for another show"),
            FakeSegment(580.0, 600.0, "invented promotion details"),
        ]
        llm = FakeLLM(
            postroll_advertising_start_id=2,
            tail_carries_program=True,
            preroll_program_id=-1,
        )
        recovered, details = self.postroll(llm, total=600.0, segments=segments)
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered], [(537.68, 600.0)]
        )
        self.assertNotIn(wp.BOUNDARY_SEGMENT_TAIL_PROMPT, llm.request_prompts)
        self.assertEqual(
            details["ads.detect.boundary.clean"],
            "segment 2 starts 5.56s after the segment before it, "
            "so it cannot share the sign-off's last words",
        )

    # TechCrunch Daily "Obama urges Democrats to have a 'clear plan' for AI
    # safeguards" (2026-09): the last 20 s were a Motley Fool Hidden Gems promo
    # that survived a 2026-09-16 preparation, when the closing-boundary probe ran
    # unconditionally, answered "carries program" for the spot and moved the cut
    # past it. Times are the retained prepared cues mapped back to source time
    # (+180.68 s after the 6.64-187.32 sponsor cut). The text of the last
    # segment is the show's usual spot continuation: the cut audio left no cue.
    OBAMA_TAIL = [
        FakeSegment(476.88, 497.04, "invented programme reporting"),
        FakeSegment(497.52, 517.76, "invented programme reporting continues"),
        FakeSegment(517.84, 537.84, "and folks that's your daily crunch today's stories are reported by"),
        FakeSegment(538.0, 538.4, "dot com"),
        FakeSegment(543.72, 563.88, "hey there i'm travis hoyam one of the hosts of motley fool hidden gems"),
        FakeSegment(563.88, 575.608, "tune in for insights and a long term perspective on investing"),
    ]

    def test_the_obama_episode_tail_promo_is_cut_whole_when_the_spot_is_nominated(self):
        llm = FakeLLM(postroll_advertising_start_id=4, tail_carries_program=True, preroll_program_id=-1)
        recovered, details = self.postroll(
            llm, detections=[FakeAd(6.64, 187.32, "sponsor_read")], total=575.608, segments=self.OBAMA_TAIL
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered], [(6.64, 187.32), (538.4, 575.608)]
        )
        self.assertNotIn(wp.BOUNDARY_SEGMENT_TAIL_PROMPT, llm.request_prompts)
        self.assertIn("segment 4 starts 5.32s after the segment before it", details["ads.detect.boundary.clean"])

    def test_the_obama_episode_tail_promo_is_cut_whole_when_the_dot_com_orphan_is_nominated(self):
        # The spot's 0.4 s "dot com" lead-in sits flush against the sign-off, so
        # the probe still runs for it; one step on lands on the spot, not past it.
        llm = FakeLLM(postroll_advertising_start_id=3, tail_carries_program=True, preroll_program_id=-1)
        recovered, details = self.postroll(
            llm, detections=[FakeAd(6.64, 187.32, "sponsor_read")], total=575.608, segments=self.OBAMA_TAIL
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered], [(6.64, 187.32), (538.4, 575.608)]
        )
        self.assertIn("segment 3", details["ads.detect.boundary.shortened"])

    def test_terminal_window_with_earlier_unclaimed_promo_gap_recovers_across_ending(self):
        # TWiT 1100 regression: two terminal cuts left a promo fragment between
        # them. Re-reviewing the bounded ending must be able to join that gap.
        segments = [
            FakeSegment(10100.0, 10200.0, "programme reporting and discussion"),
            FakeSegment(10200.0, 10251.56, "programme wrap-up and sign-off"),
            FakeSegment(10251.56, 10304.12, "club twit subscription promo"),
            FakeSegment(10304.12, 10341.28, "unclaimed promo fragment for sister show"),
            FakeSegment(10341.28, 10380.0, "closing sponsor commercial and music bed"),
        ]
        detections = [
            FakeAd(10251.56, 10304.12, label="self_promo"),
            FakeAd(10341.28, 10380.0, label="ad_break"),
        ]
        llm = FakeLLM(
            postroll_advertising_start_id=3,
            tail_carries_program=False,
            preroll_program_id=-1,
        )
        recovered, details = self.postroll(
            llm, detections=detections, total=10380.0, segments=segments
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered],
            [(10251.56, 10380.0)],
        )
        self.assertIn("ads.detect.postroll", details)

    def test_terminal_programme_gap_between_detections_remains_uncut(self):
        segments = [
            FakeSegment(10100.0, 10200.0, "programme reporting and discussion"),
            FakeSegment(10200.0, 10251.56, "programme wrap-up and sign-off"),
            FakeSegment(10251.56, 10304.12, "club twit subscription promo"),
            FakeSegment(10304.12, 10341.28, "programme discussion continues"),
            FakeSegment(10341.28, 10380.0, "closing sponsor commercial and music bed"),
        ]
        detections = [
            FakeAd(10251.56, 10304.12, label="self_promo"),
            FakeAd(10341.28, 10380.0, label="ad_break"),
        ]
        llm = FakeLLM(postroll_advertising_start_id=-1)
        recovered, details = self.postroll(
            llm, detections=detections, total=10380.0, segments=segments
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered],
            [(10251.56, 10304.12), (10341.28, 10380.0)],
        )
        self.assertIn("runs to the end", details["ads.detect.postroll.skipped"])

    def test_a_program_that_runs_to_the_end_is_left_whole(self):
        llm = FakeLLM(postroll_advertising_start_id=-1)
        recovered, details = self.postroll(llm)
        self.assertEqual(recovered, [])
        self.assertIn("runs to the end", details["ads.detect.postroll.skipped"])

    def test_a_confirmation_that_moves_the_boundary_once_still_cuts(self):
        # The realistic disagreement: the first question overshoots and the
        # confirmation finds the sign-off inside what it nominated. Narrow the
        # ending to what is left and ask once more.
        llm = FakeLLM(postroll_advertising_start_id=17, tail_carries_program=False,
                      program_id_answers=[18, -1])
        recovered, details = self.postroll(llm)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])
        self.assertIn("narrowed to 19", details["ads.detect.postroll.shrunk"])

    def test_a_boundary_segment_still_carrying_the_program_starts_the_cut_after_it(self):
        # The sign-off and the spot's first words share a segment. Taking it
        # would take the show's last sentence with it.
        llm = FakeLLM(postroll_advertising_start_id=18, tail_carries_program=True,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])
        self.assertIn("still running inside segment 18", details["ads.detect.boundary.shortened"])

    def test_an_ending_that_would_be_most_of_the_episode_is_refused(self):
        # The 300-second window reaches across most of a short episode, so the
        # share check is what stops the closing review becoming a whole-episode
        # verdict. The bound cannot be reached on a long show and does the work
        # here, which is why the fixture is three minutes rather than thirteen.
        short = [FakeSegment(index * 20.0, index * 20.0 + 20.0, f"segment {index}") for index in range(10)]
        llm = FakeLLM(postroll_advertising_start_id=2, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm, total=200.0, segments=short)
        self.assertEqual(recovered, [])
        self.assertIn("80% of the episode", details["ads.detect.postroll.skipped"])

    def test_an_opening_that_still_holds_program_content_is_left_alone(self):
        # The second question is the guard against cutting a cold open: it is
        # handed only the passage the first answer nominated, and finding the
        # hosts inside it withdraws the whole span.
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=1)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        skipped = [json.loads(line) for line in stream.getvalue().splitlines()
                   if json.loads(line)["stage"] == "ads.detect.preroll.skipped"]
        self.assertIn("program content at 1", skipped[0]["detail"])

    def test_a_show_that_opens_on_itself_is_never_asked_twice(self):
        llm = FakeLLM(preroll_program_start_id=0)
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_id"], [])

    def test_a_pre_roll_too_short_to_be_an_advertisement_is_left_alone(self):
        # A positive answer one segment in is more likely the model splitting
        # a sentence than a spot worth cutting.
        llm = FakeLLM(preroll_program_start_id=1, preroll_program_id=-1)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        self.assertIn("only 6.4s long", stream.getvalue())
