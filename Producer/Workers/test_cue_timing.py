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

class KeepMapTests(unittest.TestCase):
    def test_accumulates_output_offsets_and_skips_empty_spans(self):
        keeps = wp.build_keep_map([(0, 10), (10, 10), (30, 20), (20, 30)])
        self.assertEqual([(k.start_s, k.end_s, k.output_start_s) for k in keeps],
                         [(0, 10, 0.0), (20, 30, 10.0)])
        self.assertEqual(keeps[1].duration_s, 10)

    def test_no_keeps_means_no_cues(self):
        self.assertEqual(wp.remap_cues([{"startSeconds": 0, "endSeconds": 1, "text": "a"}], []), [])

    def test_serialized_offsets_remain_contiguous_after_millisecond_rounding(self):
        keeps = wp.build_keep_map([(0.0004, 0.3336), (0.6674, 1.0006), (1.3344, 1.6676)])
        serialized = wp.serialize_keep_map(keeps)
        expected = 0.0
        for interval in serialized:
            self.assertAlmostEqual(interval["outputStartSeconds"], expected, places=6)
            expected += interval["endSeconds"] - interval["startSeconds"]

class RemapTests(unittest.TestCase):
    def setUp(self):
        # 0-10 kept, 10-20 removed, 20-30 kept.
        self.keeps = wp.build_keep_map([(0, 10), (20, 30)])

    def test_drops_cues_inside_a_removed_span(self):
        cues = [{"startSeconds": 12, "endSeconds": 15, "text": "buy this"}]
        self.assertEqual(wp.remap_cues(cues, self.keeps), [])

    def test_shifts_later_cues_onto_the_cut_clock(self):
        cues = [{"startSeconds": 21, "endSeconds": 25, "text": "after"}]
        # 20-30 survives as 10-20, so 21-25 becomes 11-15.
        self.assertEqual(wp.remap_cues(cues, self.keeps),
                         [{"startSeconds": 11.0, "endSeconds": 15.0, "text": "after"}])

    def test_cutting_an_advertisement_does_not_change_who_spoke(self):
        cues = [{"startSeconds": 21, "endSeconds": 25, "text": "after", "speaker": "Angie"}]
        self.assertEqual(wp.remap_cues(cues, self.keeps),
                         [{"startSeconds": 11.0, "endSeconds": 15.0,
                           "text": "after", "speaker": "Angie"}])

    def test_an_unattributed_cue_gains_no_speaker_key_when_remapped(self):
        cues = [{"startSeconds": 21, "endSeconds": 25, "text": "after"}]
        self.assertNotIn("speaker", wp.remap_cues(cues, self.keeps)[0])

    def test_keeps_a_cue_that_straddles_a_boundary(self):
        cues = [{"startSeconds": 9, "endSeconds": 21, "text": "and now a word"}]
        remapped = wp.remap_cues(cues, self.keeps)
        self.assertEqual(len(remapped), 1)
        self.assertEqual(remapped[0]["text"], "and now a word")
        self.assertEqual(remapped[0]["startSeconds"], 9.0)
        self.assertGreaterEqual(remapped[0]["endSeconds"], remapped[0]["startSeconds"])

    def test_output_is_ordered_even_when_the_cut_collapses_cues(self):
        cues = [{"startSeconds": 25, "endSeconds": 26, "text": "second"},
                {"startSeconds": 2, "endSeconds": 3, "text": "first"}]
        self.assertEqual([c["text"] for c in wp.remap_cues(cues, self.keeps)], ["first", "second"])

    def test_a_cue_ending_exactly_at_a_boundary_is_not_resurrected(self):
        cues = [{"startSeconds": 19.9, "endSeconds": 20.0, "text": "last words of the ad"}]
        self.assertEqual(wp.remap_cues(cues, self.keeps), [])

    def test_every_surviving_cue_is_well_formed(self):
        cues = [{"startSeconds": s, "endSeconds": s + 1.5, "text": f"cue {s}"} for s in range(0, 30)]
        remapped = wp.remap_cues(cues, self.keeps)
        self.assertTrue(remapped)
        for cue in remapped:
            self.assertLessEqual(cue["startSeconds"], cue["endSeconds"])
            self.assertGreaterEqual(cue["startSeconds"], 0.0)
            self.assertLessEqual(cue["endSeconds"], 20.0)

class SegmentProjectionTests(unittest.TestCase):
    def test_drops_blank_segments_clamps_time_and_sorts(self):
        cues = wp.segments_to_cues([
            FakeSegment(5.0, 6.0, "second"),
            FakeSegment(-1.0, 1.0, "  first  "),
            FakeSegment(2.0, 3.0, "   "),
            FakeSegment(9.0, 8.0, "inverted"),
        ])
        self.assertEqual([c["text"] for c in cues], ["first", "second", "inverted"])
        self.assertEqual(cues[0]["startSeconds"], 0.0)
        self.assertEqual(cues[2]["endSeconds"], 9.0)

    def test_segments_are_put_in_time_order_before_anything_reads_them(self):
        # The detector reads this list by position: which segments fall in a
        # classification window, where a coarse run begins, and which segment
        # the opening review calls first all assume time order.
        ordered = wp.in_time_order([
            FakeSegment(5.0, 6.5, "third"),
            FakeSegment(1.0, 2.0, "first"),
            FakeSegment(5.0, 5.5, "second"),
        ])
        self.assertEqual([s.text for s in ordered], ["first", "second", "third"])

    def test_ordering_ties_break_on_the_shorter_segment(self):
        # Two segments starting together is what a stitched chunk boundary
        # produces; the shorter one is the one that ends inside the other.
        ordered = wp.in_time_order([FakeSegment(3.0, 9.0, "long"), FakeSegment(3.0, 4.0, "short")])
        self.assertEqual([s.text for s in ordered], ["short", "long"])

    def test_an_already_ordered_transcript_is_unchanged(self):
        segments = [FakeSegment(0.0, 1.0, "a"), FakeSegment(1.0, 2.0, "b")]
        self.assertEqual([s.text for s in wp.in_time_order(segments)], ["a", "b"])

    def test_text_joins_in_reading_order(self):
        self.assertEqual(wp.cues_to_text([{"text": "one"}, {"text": "two"}]), "one two")

class PublishedTranscriptTests(unittest.TestCase):
    def test_dispatches_on_media_type(self):
        transcribe = install_fake_wilted({"vtt": [FakeSegment(0, 1, "hi")]})
        result = wp.parse_published_transcript("WEBVTT", "text/vtt", "https://x.test/a.vtt")
        self.assertEqual(len(result), 1)
        self.assertEqual(transcribe.calls[0][0], "vtt")

    def test_falls_back_to_the_extension_when_the_type_is_wrong(self):
        transcribe = install_fake_wilted({"srt": [FakeSegment(0, 1, "hi")]})
        result = wp.parse_published_transcript("1\n", "application/octet-stream", "https://x.test/a.SRT")
        self.assertEqual(len(result), 1)
        self.assertEqual(transcribe.calls[0][0], "srt")

    def test_returns_none_when_nothing_identifies_the_format(self):
        install_fake_wilted()
        with redirect_stderr(io.StringIO()):
            self.assertIsNone(wp.parse_published_transcript("x", "text/html", "https://x.test/page"))

    def test_an_unparseable_transcript_is_not_a_failed_episode(self):
        install_fake_wilted(parse_error=ValueError("bad cue"))
        errors = io.StringIO()
        with redirect_stderr(errors):
            self.assertIsNone(wp.parse_published_transcript("junk", "text/vtt", "https://x.test/a.vtt"))
        self.assertIn("transcript.published.unparseable", errors.getvalue())

    def test_an_empty_parse_is_treated_as_no_transcript(self):
        install_fake_wilted({"vtt": []})
        self.assertIsNone(wp.parse_published_transcript("WEBVTT", "text/vtt", "https://x.test/a.vtt"))

    def _vtt(self, *texts):
        segments = [FakeSegment(float(i), float(i + 1), t) for i, t in enumerate(texts)]
        install_fake_wilted({"vtt": segments})
        with redirect_stderr(io.StringIO()):
            return wp.parse_published_transcript("WEBVTT", "text/vtt", "https://x.test/a.vtt")

    def test_keeps_the_voice_span_name_as_the_speaker(self):
        result = self._vtt("<v Angie>Welcome to the show.")
        self.assertEqual(result[0].text, "Welcome to the show.")
        self.assertEqual(result[0].speaker, "Angie")

    def test_keeps_the_name_from_a_classed_voice_span(self):
        result = self._vtt("<v.loud.first Angie Jones>Hello there.")
        self.assertEqual(result[0].text, "Hello there.")
        self.assertEqual(result[0].speaker, "Angie Jones")

    def test_decodes_entities_in_the_speaker_name(self):
        result = self._vtt("<v Ben &amp; Jerry>We make ice cream.")
        self.assertEqual(result[0].speaker, "Ben & Jerry")

    def test_closed_voice_spans_carry_the_speaker_too(self):
        result = self._vtt("<v Chris>Thanks for having me.</v>")
        self.assertEqual(result[0].text, "Thanks for having me.")
        self.assertEqual(result[0].speaker, "Chris")

    def test_a_cue_without_a_voice_span_has_no_speaker(self):
        result = self._vtt("Just some narration.")
        self.assertIsNone(result[0].speaker)

    def test_a_voice_span_that_does_not_open_the_cue_is_not_the_speaker(self):
        # A voice span mid-cue is a change of speaker the contract cannot
        # represent, so the cue keeps whoever opened it -- here, nobody.
        result = self._vtt("She said <v Angie>hello</v> and left.")
        self.assertIsNone(result[0].speaker)
        self.assertEqual(result[0].text, "She said hello and left.")

    def test_an_overlong_name_is_dropped_rather_than_truncated(self):
        result = self._vtt("<v %s>Words.</v>" % ("N" * 200))
        self.assertIsNone(result[0].speaker)
        self.assertEqual(result[0].text, "Words.")

    def test_a_cue_that_is_only_a_voice_tag_takes_its_speaker_with_it(self):
        result = self._vtt("<v Angie>", "<v Chris>Actual words.")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].speaker, "Chris")

    def test_speakers_survive_projection_onto_the_cue_contract(self):
        segments = self._vtt("<v Angie>First.", "<v Chris>Second.", "Third.")
        cues = wp.segments_to_cues(segments)
        self.assertEqual([c.get("speaker") for c in cues], ["Angie", "Chris", None])
        # An unattributed cue omits the key rather than carrying a null: the
        # Swift side decodes an absent key as "nobody said who", and a null
        # would be a second spelling of the same thing.
        self.assertNotIn("speaker", cues[2])

    def test_the_speaker_is_absent_from_the_flattened_text(self):
        segments = self._vtt("<v Angie>First.", "<v Chris>Second.")
        text = wp.cues_to_text(wp.segments_to_cues(segments))
        self.assertEqual(text, "First. Second.")
        self.assertNotIn("Angie", text)

    def test_an_unclosed_voice_span_does_not_reach_the_reader(self):
        # The shape Changelog publishes: the span opens at the cue and runs to
        # the end of it, so there is never a closing tag to pair with.
        result = self._vtt(
            "<v Narrator>Welcome to the Practical AI Podcast.",
            "<v Chris>Glad to be here.",
            "<v Angie>Likewise.",
        )
        self.assertEqual(
            [s.text for s in result],
            ["Welcome to the Practical AI Podcast.", "Glad to be here.", "Likewise."],
        )

    def test_closed_spans_styling_and_inline_timestamps_are_removed(self):
        result = self._vtt(
            "<v Chris>Hello</v>",
            "<b>bold</b> and <i>italic</i> and <c.loud>loud</c>",
            "one <00:01:23.456> two",
        )
        self.assertEqual(
            [s.text for s in result],
            ["Hello", "bold and italic and loud", "one two"],
        )

    def test_entities_are_decoded_after_markup_is_stripped(self):
        # "&lt;b&gt;" is a speaker saying "<b>", not styling. Unescaping first
        # would turn it into markup and then delete it.
        result = self._vtt("Ben &amp; Jerry&#39;s", "the &lt;b&gt; tag")
        self.assertEqual([s.text for s in result], ["Ben & Jerry's", "the <b> tag"])

    def test_a_cue_holding_only_markup_is_dropped(self):
        # The Swift cue contract rejects empty text, so an emptied cue must not
        # be forwarded.
        result = self._vtt("<v Chris>", "real words")
        self.assertEqual([s.text for s in result], ["real words"])

    def test_a_transcript_of_nothing_but_markup_is_no_transcript(self):
        self.assertIsNone(self._vtt("<v Chris>", "<v Angie>"))

    def test_stripping_collapses_the_whitespace_it_leaves_behind(self):
        result = self._vtt("well  <b>  </b>  then")
        self.assertEqual([s.text for s in result], ["well then"])

    def test_srt_cue_markup_is_stripped_too(self):
        install_fake_wilted({"srt": [FakeSegment(0, 1, "<i>whispering</i>")]})
        with redirect_stderr(io.StringIO()):
            result = wp.parse_published_transcript("1\n", "application/x-subrip", "https://x.test/a.srt")
        self.assertEqual([s.text for s in result], ["whispering"])

    def test_a_json_transcript_keeps_its_angle_brackets(self):
        # A Podcasting 2.0 body is plain text: "<" is a character somebody
        # typed, and stripping it would delete their words.
        install_fake_wilted({"podcast-json": [FakeSegment(0, 1, "the <html> element")]})
        result = wp.parse_published_transcript("{}", "application/json", "https://x.test/a.json")
        self.assertEqual([s.text for s in result], ["the <html> element"])

    def test_stripping_is_reported(self):
        segments = [FakeSegment(0, 1, "<v Chris>Hello"), FakeSegment(1, 2, "plain")]
        install_fake_wilted({"vtt": segments})
        errors = io.StringIO()
        with redirect_stderr(errors):
            wp.parse_published_transcript("WEBVTT", "text/vtt", "https://x.test/a.vtt")
        self.assertIn("transcript.published.markup-stripped", errors.getvalue())
        self.assertIn("1 cues", errors.getvalue())

    def test_a_clean_transcript_reports_nothing(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "plain words")]})
        errors = io.StringIO()
        with redirect_stderr(errors):
            wp.parse_published_transcript("WEBVTT", "text/vtt", "https://x.test/a.vtt")
        self.assertNotIn("markup-stripped", errors.getvalue())

class ProseTests(unittest.TestCase):
    def _install_trafilatura(self, text):
        install_fake_trafilatura(text)

    def test_show_notes_are_rejected_by_the_word_floor(self):
        self._install_trafilatura("too short")
        self.assertIsNone(wp.extract_prose("<html></html>"))

    def test_a_real_prose_transcript_is_accepted(self):
        self._install_trafilatura(" ".join(["word"] * wp.MINIMUM_PROSE_WORDS))
        self.assertIsNotNone(wp.extract_prose("<html></html>"))

    def test_an_extractor_failure_is_not_a_crash(self):
        module = types.ModuleType("trafilatura")

        def boom(html):
            raise RuntimeError("no parser")

        module.extract = boom
        sys.modules["trafilatura"] = module
        self.assertIsNone(wp.extract_prose("<html></html>"))

class ProgressTests(unittest.TestCase):
    def test_emits_one_clamped_ndjson_record_per_call(self):
        stream = io.StringIO()
        with redirect_stderr(stream):
            wp.progress("stage.one", "detail", 1.7)
            wp.progress("stage.two")
        lines = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(lines[0], {"stage": "stage.one", "detail": "detail", "fraction": 1.0})
        self.assertNotIn("fraction", lines[1])

    def test_previous_project_warnings_are_relayed_then_counted(self):
        handler = wp.ForwardedWarnings(limit=2)
        logger = logging.getLogger("wilted.test-relay")
        logger.addHandler(handler)
        logger.propagate = False
        stream = io.StringIO()
        try:
            with redirect_stderr(stream):
                logger.info("not relayed: below the threshold")
                for index in range(5):
                    logger.warning("batch %d failed", index)
                handler.summarize()
        finally:
            logger.removeHandler(handler)
        lines = [json.loads(line) for line in stream.getvalue().splitlines()]
        # Numbered stages: the journal keeps one row per stage, so a shared
        # name would collapse twenty relayed warnings into one surviving row.
        self.assertEqual([line["stage"] for line in lines], ["log.warning.1", "log.warning.2", "log.suppressed"])
        self.assertEqual(lines[0]["detail"], "wilted.test-relay: batch 0 failed")
        self.assertIn("3 further warnings", lines[2]["detail"])

    def test_a_relay_failure_never_unwinds_the_logging_caller(self):
        handler = wp.ForwardedWarnings(limit=5)
        logger = logging.getLogger("wilted.test-relay-fault")
        logger.addHandler(handler)
        logger.propagate = False
        try:
            with mock.patch.object(_worker_reporting, "progress", side_effect=OSError("stderr closed")), \
                    mock.patch.object(handler, "handleError") as handled, redirect_stderr(io.StringIO()):
                logger.warning("the detector is inside an except block right now")
            handled.assert_called_once()
        finally:
            logger.removeHandler(handler)
