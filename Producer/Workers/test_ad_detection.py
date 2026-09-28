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
from worker_test_ad_detection_b import AdDetectionMixinB
from worker_test_ad_detection_c import AdDetectionMixinC

class AdDetectionTests(AdDetectionMixinB, AdDetectionMixinC, unittest.TestCase):
    """The TWiT 1098 regression: a backend that was never loaded classified
    1,345 segments as content in 174 ms and the episode shipped as prepared."""

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.segments = [FakeSegment(0, 2, "buy this"), FakeSegment(2, 4, "content")]
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def test_the_model_is_loaded_before_detection_and_closed_after(self):
        llm = FakeLLM()
        ads = install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertTrue(llm.loaded)
        self.assertTrue(llm.closed)
        self.assertEqual((spans, keeps), ([], []))
        # Constrained JSON is how the tuned prompts were accepted; the proxy
        # must not strip the keyword on its way through. The last two requests
        # are the opening and closing reviews, which every episode gets once.
        self.assertEqual(llm.requests, [ads._AD_DETECT_RESPONSE_FORMAT,
                                        {"field": "program_start_id", "ids": [0, 1]},
                                        {"field": "advertising_start_id", "ids": [-1, 0, 1]}])

    def test_sponsor_opening_compatibility_is_installed_before_detection(self):
        llm = FakeLLM()
        ads = install_fake_ads(llm)
        observed = []

        def detect(segments, backend):
            observed.append((
                ads._SPONSOR_OPENING_RE.search("our show this week brought to you by superhuman") is not None,
                ads._EXPLICIT_HOST_READ_OPENING_RE.search(
                    "this week in tech brought to you this week by claud"
                ) is not None,
            ))
            return []

        ads.detect_ads = detect
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(observed, [(True, True)])

    def test_a_backend_that_never_answers_is_a_failure_not_zero_ads(self):
        llm = FakeLLM(fail_generate=RuntimeError("llama_decode returned -1"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("llama_decode returned -1", str(raised.exception))
        self.assertTrue(llm.closed)




    def test_detections_are_reported_and_the_call_count_is_journaled(self):
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(0.0, 2.0)])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=4.0):
            _path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 2.0, "label": "sponsor", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.9}])
        self.assertEqual(keeps, [])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.calls", stages)
        self.assertIn("ads.cut.refused", stages)

    def test_a_span_covering_most_of_the_episode_is_dropped_and_said_out_loud(self):
        # TechCrunch Daily, 9:23 long, came back 1:52 with "1 ad removed
        # (7:30)". The one span ran 0:07 to 7:37 and held two real host reads
        # at either end with every news item of the episode between them: the
        # archived detector brackets an ad that goes out and comes back as one
        # pod, bounded at ten minutes, which is the whole of a short show.
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(6.72, 456.88, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=563.17):
            path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        # Nothing cut, and the audio handed back is the audio handed in:
        # preparation writes over the download, so an over-cut is permanent.
        self.assertEqual((path, spans, keeps), (self.audio, [], []))
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        rejected = [event for event in events if event["stage"] == "ads.detect.span.rejected"]
        self.assertEqual(len(rejected), 1)
        self.assertIn("80% of the episode", rejected[0]["detail"])


    def test_spans_that_are_individually_plausible_can_still_be_refused_together(self):
        # Each of these is under the single-span limit and the three together
        # take two thirds of the episode, which no episode survives being.
        llm = FakeLLM()
        install_fake_ads(llm, detections=[
            FakeAd(0.0, 240.0), FakeAd(250.0, 400.0), FakeAd(410.0, 400.0 + 90.0),
        ])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=600.0):
            path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual((path, spans, keeps), (self.audio, [], []))
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        self.assertIn("ads.detect.refused", details)
        self.assertIn("keeping the episode whole", details["ads.detect.refused"])



    # A short episode's whole programme, bracketed as one advertisement. The
    # advertising is genuinely at the front; everything from segment 9 on is
    # the news, and the detector's absolute pod bounds swallowed all of it.
    OVERSIZED = [FakeSegment(index * 20.0, index * 20.0 + 20.0, f"segment {index}") for index in range(28)]

    def resize(self, llm, ad, total=563.17, segments=None):
        ads = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        stream = io.StringIO()
        with redirect_stderr(stream):
            resized, self.confirmed = wp.resize_oversized_ad_spans(
                ads, llm, self.OVERSIZED if segments is None else segments, [ad], total
            )
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        return resized, details

    def test_an_oversized_span_is_shortened_to_where_the_program_resumes(self):
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=False)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88, label="sponsor_read"))
        # The advertising the detector found is kept; the programme it swept up
        # behind that advertising is handed back.
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in resized],
                         [(6.72, 180.0, "sponsor_read")])
        self.assertIn("ads.detect.span.resized", details)
        self.assertIn("before program ID 9", details["ads.detect.span.resized"])





    # David, 2026-09-16, after three TechCrunch preparations failed in one
    # morning: "on a short episode which is just a news alert, it really might
    # be half ads ... that should not trigger anything except further review".
    # Size is a reason to look harder. It is never the verdict.



    def test_spans_that_would_cross_the_programme_floor_keep_the_episode_whole(self):
        # 55% of the episode vouched for plus 23% unreviewed is 78% removed,
        # which leaves 22% programme -- under the absolute floor. The floor
        # overrides even the reviewed verdict rather than falling back to it:
        # a detector and a reviewer that between them want most of the
        # episode are both wrong, and the whole episode is kept.
        confirmed = frozenset({(0.0, 330.0)})
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(0.0, 330.0), FakeAd(340.0, 420.0), FakeAd(430.0, 490.0)],
                600.0,
                confirmed,
            )
        self.assertEqual(kept, [])
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        self.assertIn("under the 30% floor", details["ads.detect.refused"])
        self.assertIn("keeping the episode whole", details["ads.detect.refused"])






    def test_sponsor_prefix_before_a_mixed_programme_cue_is_confirmed_once(self):
        # TechCrunch's cue 9 starts at 167.64 seconds. It ends a Plaud sponsor
        # read and starts the episode title and first headline, so the first
        # confirmation rightly finds programme there. Re-confirming only cues
        # before 9 may preserve the sponsor prefix, but must not rescan the
        # original oversized span.
        segments = [
            FakeSegment(
                167.64 if index == 9 else index * 20.0,
                187.64 if index == 9 else (167.64 if index == 8 else index * 20.0 + 20.0),
                "Visit Acme.example for the sponsor offer."
                if index == 4 else
                "Plaud sponsor tail, then the programme begins with the daily report."
                if index == 9 else
                f"opening cue {index}",
            )
            for index in range(28)
        ]
        llm = FakeLLM(
            preroll_program_start_id=20,
            program_id_answers=[9, -1],
            rescan_evidence_id=4,
        )
        resized, details = self.resize(llm, FakeAd(6.72, 456.88), segments=segments)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 167.64)])
        self.assertIn("before program ID 9", details["ads.detect.span.resized"])
        self.assertNotIn("ads.detect.span.rescan.confirmed", details)
        self.assertNotIn(wp.OVERSIZED_SPAN_RESCAN_PROMPT, llm.request_prompts)
        self.assertEqual(self.confirmed, frozenset({(6.72, 167.64)}))


    def test_a_span_that_fails_the_rescan_too_is_left_unvouched_for(self):
        # An unreadable first review has no programme finding to preserve, so
        # it may still take the second, advertising-evidence route. Neither
        # review can vouch for this span, and the size ceiling catches it.
        llm = FakeLLM(answer="not json", rescan_evidence_id=-1)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("no advertising evidence on a second read",
                      details["ads.detect.span.rescan.rejected"])
        self.assertEqual(self.confirmed, frozenset())
        with redirect_stderr(io.StringIO()):
            self.assertEqual(wp.reject_implausible_ad_spans(resized, 563.17, self.confirmed), [])

    def rescan(self, llm, ad, segments=None):
        ads = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        stream = io.StringIO()
        with redirect_stderr(stream):
            verdict = wp._rescan_unconfirmed_oversized_span(
                ads, llm, self.OVERSIZED if segments is None else segments, ad
            )
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        return verdict, details


    def test_the_rescan_declines_a_span_it_cannot_evidence(self):
        llm = FakeLLM(rescan_evidence_id=-1)
        verdict, details = self.rescan(llm, FakeAd(6.72, 456.88))
        self.assertFalse(verdict)
        self.assertIn("no advertising evidence on a second read",
                      details["ads.detect.span.rescan.rejected"])
        self.assertEqual(len(llm.requests), 1)




    def test_a_boundary_segment_holding_the_program_start_is_left_in(self):
        # TechCrunch segment 9 is five seconds of Plaud call to action and then
        # "apple debuts its most powerful chip ever i'm imran shake and your
        # daily crunch starts right now". Cutting to the segment after it takes
        # the episode title and the host introduction out of the file, so the
        # cut stops one segment short and leaves the advertisement's tail in.
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=True)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 160.0)])
        self.assertIn("the program starts inside segment 8", details["ads.detect.boundary.shortened"])

    def test_an_unanswerable_boundary_question_keeps_the_segment(self):
        # No answer is not permission. The segment might hold the program, so
        # the cut stops before it exactly as if the answer had been yes.
        llm = FakeLLM(answer="not json", preroll_program_start_id=9, preroll_program_id=-1)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 160.0)])
        self.assertIn("ads.detect.boundary.unanswered", details)

    # The Daily ends on a Chase Sapphire spot and TechCrunch Daily on a Motley
    # Fool one, both after the sign-off, both missed. Twenty segments of forty
    # seconds, with the show finishing somewhere in the last three.
    POSTROLL = [FakeSegment(index * 40.0, index * 40.0 + 40.0, f"segment {index}") for index in range(20)]

    def postroll(self, llm, detections=(), total=810.0, segments=None):
        ads = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        stream = io.StringIO()
        with redirect_stderr(stream):
            recovered = wp.recover_transcript_end_postroll(
                ads, llm, segments or self.POSTROLL, list(detections), total
            )
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        return recovered, details




    def test_a_silence_too_long_to_be_a_leader_is_left_where_it_is(self):
        # A minute of silence is more likely untranscribed program audio than a
        # spot's leader, so the claim stops fifteen seconds short of the spot
        # rather than running back to the sign-off.
        gap = [*self.POSTROLL[:19], FakeSegment(790.0, 800.0, "segment 19")]
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, _details = self.postroll(llm, segments=gap)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(775.0, 810.0)])








    def test_a_confirmation_contradicting_the_segment_itself_loses(self):
        # A promotion for another podcast describes its own content the way a
        # show describes itself, and the confirmation reads the first segment of
        # it as this program. The question asked about that segment alone, with
        # nothing else to weigh, said there was no program in it. That answer
        # wins, and the whole spot comes out instead of a third of it.
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=19)
        recovered, details = self.postroll(llm)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])
        self.assertIn("keeping the boundary", details["ads.detect.postroll.contested"])

    def test_an_ending_holding_program_content_is_not_cut(self):
        # Two disagreements is not a boundary dispute, it is the review being
        # wrong about the whole ending.
        llm = FakeLLM(postroll_advertising_start_id=17, tail_carries_program=False,
                      program_id_answers=[18, 19])
        recovered, details = self.postroll(llm)
        self.assertEqual(recovered, [])
        self.assertIn("still holds program content at 19", details["ads.detect.postroll.skipped"])


    def test_an_ending_too_short_to_be_a_spot_is_left_alone(self):
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm, total=765.0)
        self.assertEqual(recovered, [])
        self.assertIn("too short", details["ads.detect.postroll.skipped"])



    def test_a_plausible_span_is_never_sent_for_review(self):
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=False)
        resized, _details = self.resize(llm, FakeAd(6.72, 187.0))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 187.0)])
        self.assertEqual(llm.requests, [])


    # The opening of Giant Bombcast 955, which every stage of the detector
    # called content: a produced spot for a game, with no host reading it, no
    # sponsor phrase, no domain, and no call to action to seed a coarse run.
    PREROLL = [
        FakeSegment(0.25, 6.1, "Aliens Fireteam Elite 2 launches on August 25th on PS5, Xbox and Steam."),
        FakeSegment(6.4, 51.9, "Burn or freeze xenomorphs in their tracks. See ya on LV 558."),
        FakeSegment(84.5, 90.5, "Hey everybody, it's Tuesday. Welcome to the Giant Bombcast."),
        FakeSegment(90.5, 96.8, "I'm your host, and joining me, co-captain of the ship."),
    ]

    def test_a_produced_pre_roll_is_cut_even_though_no_stage_called_it_an_ad(self):
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=-1)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        # The cut runs to where the program begins, not to the last
        # advertising cue: the thirty-two seconds between them are the spot's
        # own music bed, and leaving them is leaving the advertisement in.
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 84.5,
                                  "label": "ad_break", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.9}])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.preroll", stages)





    def test_an_opening_the_detector_claimed_only_part_of_is_still_reviewed(self):
        # Giant Bombcast 955 shipped this way: the detector called 13.0-131.1 an
        # advertisement and left the spot's first thirteen seconds in front of
        # it, so the episode opened on an insurance commercial. A span that
        # starts after the first second does not mean the opening is handled.
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=-1)
        install_fake_ads(llm, detections=[FakeAd(6.4, 51.9)])
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        # One span, from the first second to where the program begins: the
        # recovered opening absorbs the partial detection rather than sitting
        # beside it.
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 84.5,
                                  "label": "ad_break", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.9}])



    def test_one_answered_singleton_does_not_turn_a_dead_backend_into_zero_ads(self):
        llm = FakeLLM(fail_generate=RuntimeError("Metal command buffer failed"))
        install_fake_ads(llm)
        original = llm.generate

        def flaky(system_prompt, user_content, *, response_format=None):
            # One lucky call, then broken again: a Metal fault does not heal
            # because one completion got through, and the opening review that
            # follows detection is asked of the same dead backend.
            failure = llm.fail_generate
            if system_prompt == "archive ad classifier correction":
                llm.fail_generate = None
            try:
                return original(system_prompt, user_content, response_format=response_format)
            finally:
                llm.fail_generate = failure

        llm.generate = flaky
        segments = [FakeSegment(0, 2, "buy this"), FakeSegment(2, 4, "and this"), FakeSegment(4, 6, "content")]
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("3 of 4", str(raised.exception))
