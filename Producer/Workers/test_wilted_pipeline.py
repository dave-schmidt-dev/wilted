#!/usr/bin/env python3
"""Unit tests for the podcast preparation worker.

Deliberately dependency-free: every import the worker makes from the previous
project is lazy and inside a function, so the tests stub those modules and run
under the system interpreter. That keeps this leg in the ordinary gate instead
of behind a virtualenv and a four-gigabyte model.
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import subprocess
import sys
import types
import unittest
from contextlib import redirect_stderr
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKER_PATH = REPO_ROOT / "Producer" / "Workers" / "wilted_pipeline.py"


def load_worker():
    spec = importlib.util.spec_from_file_location("wilted_pipeline", WORKER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["wilted_pipeline"] = module
    spec.loader.exec_module(module)
    return module


wp = load_worker()


@dataclass
class FakeSegment:
    start_s: float
    end_s: float
    text: str


def install_fake_wilted(parse_results=None, parse_error=None):
    """Stand in for the previous project's `wilted` package."""
    transcribe = types.ModuleType("wilted.transcribe")

    def parser(name):
        def parse(body):
            if parse_error is not None:
                raise parse_error
            calls.append((name, body))
            return (parse_results or {}).get(name)
        return parse

    calls: list[tuple[str, str]] = []
    transcribe.parse_vtt = parser("vtt")
    transcribe.parse_srt = parser("srt")
    transcribe.parse_podcast_json = parser("podcast-json")
    transcribe.calls = calls
    package = types.ModuleType("wilted")
    package.transcribe = transcribe
    sys.modules["wilted"] = package
    sys.modules["wilted.transcribe"] = transcribe
    return transcribe


class KeepMapTests(unittest.TestCase):
    def test_accumulates_output_offsets_and_skips_empty_spans(self):
        keeps = wp.build_keep_map([(0, 10), (10, 10), (30, 20), (20, 30)])
        self.assertEqual([(k.start_s, k.end_s, k.output_start_s) for k in keeps],
                         [(0, 10, 0.0), (20, 30, 10.0)])
        self.assertEqual(keeps[1].duration_s, 10)

    def test_no_keeps_means_no_cues(self):
        self.assertEqual(wp.remap_cues([{"startSeconds": 0, "endSeconds": 1, "text": "a"}], []), [])


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


class ProseTests(unittest.TestCase):
    def _install_trafilatura(self, text):
        module = types.ModuleType("trafilatura")
        module.extract = lambda html: text
        sys.modules["trafilatura"] = module

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


class RunTests(unittest.TestCase):
    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")

    def test_published_transcript_is_preferred_and_ads_can_be_skipped(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 2, "hello"), FakeSegment(2, 4, "world")]})
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False, "allowSpeechToText": False,
                "publishedTranscript": {"body": "WEBVTT", "mediaType": "text/vtt",
                                        "url": "https://x.test/a.vtt", "languageCode": "en"},
            })
        self.assertTrue(result["ok"])
        self.assertEqual(result["timing"], "published")
        self.assertEqual(result["text"], "hello world")
        self.assertEqual(result["languageCode"], "en")
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["removedSeconds"], 0.0)
        self.assertEqual(result["audioPath"], str(self.audio))

    def test_no_transcript_of_any_kind_still_returns_a_result(self):
        install_fake_wilted()
        with redirect_stderr(io.StringIO()):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False, "allowSpeechToText": False})
        self.assertTrue(result["ok"])
        self.assertEqual(result["timing"], "none")
        self.assertEqual(result["cues"], [])
        self.assertIsNone(result["text"])

    def test_missing_audio_is_a_structured_failure(self):
        with self.assertRaises(wp.WorkerError) as raised:
            wp.run({"audioPath": "/nonexistent/audio.mp3"})
        self.assertEqual(raised.exception.code, "audio-missing")


class ProtocolTests(unittest.TestCase):
    def test_a_malformed_request_is_answered_not_crashed(self):
        completed = subprocess.run([sys.executable, str(WORKER_PATH)], input="not json",
                                   capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout)["code"], "bad-request")

    def test_a_non_object_request_is_rejected(self):
        completed = subprocess.run([sys.executable, str(WORKER_PATH)], input="[1,2]",
                                   capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertFalse(json.loads(completed.stdout)["ok"])


class CrossLanguageContractTests(unittest.TestCase):
    """The worker and the Swift domain must agree on which types carry timing.

    They are two hand-maintained lists in two languages: the Swift side decides
    what to fetch and send, this side decides what to parse. A silent
    divergence loses published timing for a whole media type.
    """

    def test_timed_media_types_match_the_swift_domain(self):
        source = (REPO_ROOT / "WiltedKit" / "Sources" / "WiltedDomain" / "Models.swift").read_text()
        block = re.search(r"timedMediaTypes:\s*Set<String>\s*=\s*\[(.*?)\]", source, re.S)
        self.assertIsNotNone(block, "timedMediaTypes is no longer where this test looks for it")
        swift_types = set(re.findall(r'"([^"]+)"', block.group(1)))
        self.assertEqual(swift_types, set(wp.TIMED_MEDIA_TYPES))


if __name__ == "__main__":
    unittest.main(verbosity=2)
