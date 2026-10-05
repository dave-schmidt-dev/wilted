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

class AdDetectionMixinC:
    def test_a_model_that_cannot_load_is_reported_by_name(self):
        llm = FakeLLM(fail_load=FileNotFoundError("GGUF model file not found: /models/default.gguf"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-model-unavailable")
        self.assertIn("/models/default.gguf", str(raised.exception))
        # A half-constructed backend still holds whatever it allocated.
        self.assertTrue(llm.closed)

    def test_a_short_mostly_advertising_episode_still_prepares_the_confirmed_cut(self):
        # Six minutes with 53% of it one reviewed sponsor read: the removal
        # is inside both the absolute programme floor and the total ceiling,
        # so the run has to prepare and report exactly the span the review
        # vouched for. This is the case the tighter unconfirmed bound exists
        # to leave alone: a short news-alert episode that really is mostly
        # advertising.
        segments = [FakeSegment(index * 20.0, index * 20.0 + 20.0, f"segment {index}") for index in range(28)]
        llm = FakeLLM(preroll_program_start_id=-1)
        install_fake_ads(llm, detections=[FakeAd(6.72, 250.0, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=459.0):
            path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(
            (path, [(span["startSeconds"], span["endSeconds"]) for span in spans], keeps),
            (self.audio, [(6.72, 250.0)], []),
        )
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertNotIn("ads.detect.span.rejected", stages)
        self.assertNotIn("ads.detect.refused", stages)
        self.assertIn("ads.cut.refused", stages)

    def test_a_bracketed_pod_continuation_is_held_without_losing_programme_audio(self):
        # The reviewer reaches the separate closing read, not the first
        # continuation segment.  That brackets programme discussion between
        # two confirmed reads, so the original cuts must survive unchanged.
        segments = [
            FakeSegment(0.0, 20.0, "opening sponsorship message"),
            FakeSegment(20.0, 30.0, "the programme begins with the news"),
            FakeSegment(30.0, 40.0, "the hosts discuss the first story"),
            FakeSegment(40.0, 50.0, "more programme context follows"),
            FakeSegment(50.0, 60.0, "the discussion continues"),
            FakeSegment(60.0, 80.0, "a separate closing sponsorship message"),
            FakeSegment(80.0, 100.0, "the programme returns after the read"),
        ]
        llm = FakeLLM(adjacent_program_start_id=6)
        install_fake_ads(llm, detections=[
            FakeAd(0.0, 20.0, label="sponsor_read"),
            FakeAd(60.0, 80.0, label="sponsor_read"),
        ])
        stream = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            request = {
                "audioPath": str(self.audio),
                "outputPath": str(Path(directory) / "prepared.mp3"),
            }
            with redirect_stderr(stream), \
                    mock.patch.object(_worker_cue_timing, "probe_duration", return_value=180.0), \
                    mock.patch.object(
                        _worker_ad_removal,
                        "render_keep_segments",
                        side_effect=lambda _source, output, _keeps: output.write_bytes(b"prepared"),
                    ):
                _path, spans, _keeps, _raw, audit = wp.detect_and_cut(
                    request, self.audio, [], segments, with_report=True
                )

        self.assertEqual(
            [(span["startSeconds"], span["endSeconds"]) for span in spans],
            [(0.0, 20.0), (60.0, 80.0)],
        )
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.span.held", stages)
        self.assertEqual(
            audit["heldSpans"],
            [{
                "reason": "pod-continuation-bracket",
                "startSeconds": 20.0,
                "endSeconds": 80.0,
            }],
        )

    def test_an_all_programme_oversized_span_is_not_confirmed_or_cut(self):
        # The first supplied ID means the program starts immediately. It must
        # not confirm an oversized detection or let it bypass the size ceiling.
        segments = [FakeSegment(index * 20.0, index * 20.0 + 20.0, f"segment {index}") for index in range(28)]
        llm = FakeLLM(preroll_program_start_id=0, rescan_evidence_id=-1)
        install_fake_ads(llm, detections=[FakeAd(6.72, 250.0, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=459.0):
            path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual((path, spans, keeps), (self.audio, [], []))
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.span.resize.skipped", stages)
        self.assertIn("ads.detect.span.rejected", stages)
        self.assertNotIn("ads.detect.span.confirmed", stages)

    def test_a_span_where_program_starts_at_first_segment_is_not_confirmed(self):
        llm = FakeLLM(preroll_program_start_id=0, rescan_evidence_id=-1)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertIn("the program starts at the first segment", details["ads.detect.span.resize.skipped"])
        self.assertNotIn(wp.OVERSIZED_SPAN_RESCAN_PROMPT, llm.request_prompts)
        self.assertEqual(self.confirmed, frozenset())
        kept = wp.reject_implausible_ad_spans(resized, 563.17, self.confirmed)
        self.assertEqual(kept, [])

    def test_a_located_boundary_is_honoured_however_large_the_advertisement(self):
        # The review found where the programme resumes, which is the question
        # asked. Discarding that answer because the advertisement it leaves
        # behind is a large share of a short episode overrules a verdict with
        # arithmetic, which is how a correct sponsor read became a failure.
        llm = FakeLLM(preroll_program_start_id=20, preroll_program_id=-1, boundary_starts_program=False)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 400.0)])
        self.assertIn("before program ID 20", details["ads.detect.span.resized"])
        self.assertEqual(self.confirmed, frozenset({(6.72, 400.0)}))

    def test_a_span_no_review_vouched_for_is_still_dropped_for_its_size(self):
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans([FakeAd(6.72, 292.64)], 459.0)
        self.assertEqual(kept, [])
        self.assertIn("no review could vouch for it", stream.getvalue())

    def test_the_total_ceiling_holds_a_vouched_span_and_hands_back_its_companion(self):
        # The reviewed 286s span alone is 62% of this episode, over the 60%
        # ceiling. It is held whole, and the unreviewed companion is handed
        # back with it so no unreviewed span remains in the cut.
        confirmed = frozenset({(6.72, 292.64)})
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(6.72, 292.64), FakeAd(300.0, 310.0)], 459.0, confirmed
            )
        self.assertEqual(kept, [])
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        held = [event for event in events if event["stage"] == "ads.detect.span.held"]
        self.assertEqual(len(held), 1)
        self.assertIn("6.720-292.640", held[0]["detail"])
        self.assertIn("62% of the episode", held[0]["detail"])

    def test_a_short_episodes_vouched_for_spans_are_the_cut_the_ceiling_leaves(self):
        # A news-alert episode that genuinely is mostly advertising: the
        # review vouched for 53% of it, which leaves the programme inside the
        # absolute floor. The unreviewed 9% would push the removal past the
        # total ceiling, so the ceiling keeps the confirmed set exactly.
        total = 459.0
        confirmed = frozenset({(6.72, 250.0)})
        combined = (sum(end - start for start, end in confirmed) + 40.0) / total
        self.assertGreater(combined, wp.MAXIMUM_TOTAL_AD_SHARE)
        self.assertGreaterEqual(1 - combined, wp.MINIMUM_PROGRAMME_SHARE)
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(6.72, 250.0), FakeAd(260.0, 300.0)], total, confirmed
            )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in kept], [(6.72, 250.0)])
        self.assertIn("ads.detect.refused", stream.getvalue())

    def test_the_unconfirmed_bound_fires_inside_the_total_cap(self):
        # Additional to the overall cap, not a replacement for it. The
        # combined removal here sits exactly on the total ceiling, so the
        # total cap leaves it alone; the unreviewed half is over the tighter
        # bound on its own, and that is what keeps everything but the
        # vouched-for span.
        confirmed = frozenset({(0.0, 30.0)})
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = wp.reject_implausible_ad_spans(
                [FakeAd(0.0, 30.0), FakeAd(60.0, 200.0), FakeAd(240.0, 430.0)],
                600.0,
                confirmed,
            )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in kept], [(0.0, 30.0)])
        details = {
            json.loads(line)["stage"]: json.loads(line)["detail"]
            for line in stream.getvalue().splitlines()
        }
        self.assertIn("without review", details["ads.detect.refused"])
        self.assertIn("only the spans a review vouched for", details["ads.detect.refused"])

    def test_a_safe_prefix_retry_that_finds_programme_preserves_the_full_span(self):
        # The retry is the only extra question permitted after positive
        # programme evidence. Another programme answer leaves the detector's
        # original span unvouched for and cannot fall through to a whole-span
        # rescan, even when that rescan would find sponsor evidence.
        llm = FakeLLM(
            preroll_program_start_id=20,
            program_id_answers=[9, 3],
            rescan_evidence_id=4,
        )
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("safe prefix still holds program content at 3",
                      details["ads.detect.span.resize.skipped"])
        self.assertNotIn(wp.OVERSIZED_SPAN_RESCAN_PROMPT, llm.request_prompts)
        self.assertEqual(self.confirmed, frozenset())
        with redirect_stderr(io.StringIO()):
            self.assertEqual(wp.reject_implausible_ad_spans(resized, 563.17, self.confirmed), [])

    def test_the_rescan_reaches_the_model_and_can_confirm_a_span(self):
        # Both verdicts have to be reachable from a rescan pass: positive
        # evidence vouches for the span, and -1 declines to.
        llm = FakeLLM(rescan_evidence_id=2)
        verdict, details = self.rescan(llm, FakeAd(6.72, 456.88))
        self.assertTrue(verdict)
        self.assertIn("evidence at ID 2", details["ads.detect.span.rescan.confirmed"])
        self.assertEqual(len(llm.requests), 1)

    def test_a_rescan_of_a_single_segment_vouches_for_nothing(self):
        # A single cue is not a passage: it carries neither the run a
        # boundary needs nor the recurrence advertising evidence needs, so
        # the rescan refuses to confirm it without asking.
        llm = FakeLLM(rescan_evidence_id=0)
        verdict, details = self.rescan(
            llm, FakeAd(0.0, 19.0), [FakeSegment(0.0, 19.0, "one segment")]
        )
        self.assertFalse(verdict)
        self.assertIn("fewer than two segments", details["ads.detect.span.rescan.rejected"])
        self.assertEqual(llm.requests, [])

    def test_the_cut_claims_the_spots_own_leader(self):
        # The silence between the sign-off and the spot is the spot's leader,
        # and leaving it behind leaves the advertisement in. TechCrunch's is 6.3
        # seconds, The Daily's 4.2.
        leader = [*self.POSTROLL[:19], FakeSegment(766.0, 800.0, "segment 19")]
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, _details = self.postroll(llm, segments=leader)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])

    def test_an_ending_the_detector_already_claimed_is_not_reviewed_again(self):
        llm = FakeLLM(postroll_advertising_start_id=19, preroll_program_id=-1)
        recovered, details = self.postroll(llm, detections=[FakeAd(760.0, 800.0)])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 800.0)])
        self.assertIn("already claimed", details["ads.detect.postroll.skipped"])
        self.assertEqual(llm.requests, [])

    def test_terminal_programme_gap_is_not_given_a_leader_from_the_known_final_ad(self):
        segments = [
            FakeSegment(10100.0, 10200.0, "programme reporting and discussion"),
            FakeSegment(10200.0, 10251.56, "programme wrap-up and sign-off"),
            FakeSegment(10251.56, 10304.12, "club twit subscription promo"),
            FakeSegment(10304.12, 10326.28, "programme discussion continues"),
            FakeSegment(10341.28, 10380.0, "closing sponsor commercial and music bed"),
        ]
        detections = [
            FakeAd(10251.56, 10304.12, label="self_promo"),
            FakeAd(10341.28, 10380.0, label="ad_break"),
        ]
        llm = FakeLLM(postroll_advertising_start_id=4)
        recovered, details = self.postroll(
            llm, detections=detections, total=10380.0, segments=segments
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered],
            [(10251.56, 10304.12), (10341.28, 10380.0)],
        )
        self.assertIn(
            "already-detected ending rather than the unclaimed gap",
            details["ads.detect.postroll.skipped"],
        )

    def test_terminal_gap_probe_cannot_advance_onto_the_known_final_ad(self):
        segments = [
            FakeSegment(10100.0, 10200.0, "programme reporting and discussion"),
            FakeSegment(10200.0, 10251.56, "programme wrap-up and sign-off"),
            FakeSegment(10251.56, 10304.12, "club twit subscription promo"),
            FakeSegment(10304.12, 10341.28, "programme ending mixed with a promo opening"),
            FakeSegment(10341.28, 10380.0, "closing sponsor commercial and music bed"),
        ]
        detections = [
            FakeAd(10251.56, 10304.12, label="self_promo"),
            FakeAd(10341.28, 10380.0, label="ad_break"),
        ]
        llm = FakeLLM(
            postroll_advertising_start_id=3,
            tail_carries_program=True,
        )
        recovered, details = self.postroll(
            llm, detections=detections, total=10380.0, segments=segments
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered],
            [(10251.56, 10304.12), (10341.28, 10380.0)],
        )
        self.assertIn(
            "shortened onto the already-detected ending rather than the unclaimed gap",
            details["ads.detect.postroll.skipped"],
        )

    def test_an_unanswered_closing_review_never_cuts(self):
        llm = FakeLLM(answer="not json")
        recovered, details = self.postroll(llm)
        self.assertEqual(recovered, [])
        self.assertIn("closing review failed", details["ads.detect.postroll.skipped"])

    def test_a_shortened_span_survives_the_size_guard_and_is_cut(self):
        # End to end: the opening review passes because the detection already
        # starts at the first second, the resize shortens it, and the guard
        # that would have dropped it whole now finds it plausible.
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=False)
        install_fake_ads(llm, detections=[FakeAd(0.0, 456.88, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=563.17):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.OVERSIZED)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 180.0,
                                  "label": "sponsor_read", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.9}])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.span.resized", stages)
        self.assertNotIn("ads.detect.span.rejected", stages)

    def test_an_opening_the_detector_already_claimed_is_not_reviewed_again(self):
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=-1)
        install_fake_ads(llm, detections=[FakeAd(0.0, 51.9)])
        with redirect_stderr(io.StringIO()), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 51.9,
                                  "label": "sponsor", "kind": "paid advertising", "kinds": ["paid advertising"], "disposition": "must-cut", "confidence": 0.9}])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_start_id"], [])

    def test_an_unanswered_opening_review_never_cuts(self):
        llm = FakeLLM(fail_generate=None)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        # `answer` is the detector's own "[]", which is not an ID object: a
        # malformed completion leaves the audio alone rather than guessing.
        self.assertEqual(spans, [])
        self.assertIn("opening review failed", stream.getvalue())

    def test_counting_backend_trips_on_a_majority_of_failures_not_all_of_them(self):
        llm = FakeLLM(loaded=True)
        counting = wp.CountingBackend(llm)
        counting.generate("s", "u")
        llm.fail_generate = ValueError("bad completion")
        with self.assertRaises(ValueError):
            counting.generate("s", "u")
        self.assertEqual((counting.calls, counting.failures), (2, 1))
        self.assertFalse(counting.mostly_failed, "an even split is not a broken backend")
        with self.assertRaises(ValueError):
            counting.generate("s", "u")
        self.assertTrue(counting.mostly_failed, "one lucky singleton must not disarm the check")
        self.assertFalse(wp.CountingBackend(llm).mostly_failed, "no calls is not a failure")
