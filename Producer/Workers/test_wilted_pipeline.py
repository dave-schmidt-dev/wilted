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
import logging
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock

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
    # `from wilted import ads` falls back to sys.modules["wilted.ads"], so a
    # double left behind by another test would be silently reused here.
    sys.modules.pop("wilted.ads", None)
    sys.modules.pop("wilted.llm", None)
    return transcribe


@dataclass
class FakeLLM:
    """The previous project's GGUF backend, as far as the worker can see it.

    It loads lazily and refuses to answer until it has: that asymmetry is the
    whole TWiT 1098 regression, so the double reproduces it exactly.
    """

    answer: str = "[]"
    loaded: bool = False
    closed: bool = False
    fail_load: Exception | None = None
    fail_generate: Exception | None = None
    requests: list = field(default_factory=list)

    def load(self):
        if self.fail_load is not None:
            raise self.fail_load
        self.loaded = True

    def generate(self, system_prompt, user_content, *, response_format=None):
        self.requests.append(response_format)
        if not self.loaded:
            raise RuntimeError("Model not loaded. Call load() first.")
        if self.fail_generate is not None:
            raise self.fail_generate
        return self.answer, 1

    def close(self):
        self.closed = True


@dataclass
class FakeAd:
    start_s: float
    end_s: float
    label: str = "sponsor"
    confidence: float = 0.9


def install_fake_ads(llm: FakeLLM, detections=()):
    """Stand in for `wilted.ads` and `wilted.llm` with the real detector's manners.

    The real detector asks the backend once per batch and treats any exception
    as a malformed completion: it swallows it and classifies the batch as
    content. This double asks once per segment and does the same.
    """
    ads = types.ModuleType("wilted.ads")

    def detect_ads(segments, backend):
        answered = False
        for segment in segments:
            try:
                backend.generate("classify", segment.text, response_format={"type": "json_object"})
            except Exception:  # noqa: BLE001 - the real detector is this forgiving
                continue
            answered = True
        return list(detections) if answered else []

    ads.detect_ads = detect_ads
    ads._compute_keep_segments = lambda total, ads_found, pad: []  # noqa: SLF001
    llm_module = types.ModuleType("wilted.llm")
    llm_module.DEFAULT_GGUF_MODEL = "/models/default.gguf"
    llm_module.create_backend = lambda kind, model: llm
    package = sys.modules.get("wilted") or types.ModuleType("wilted")
    package.ads = ads
    package.llm = llm_module
    sys.modules["wilted"] = package
    sys.modules["wilted.ads"] = ads
    sys.modules["wilted.llm"] = llm_module
    return ads


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
            with mock.patch.object(wp, "progress", side_effect=OSError("stderr closed")), \
                    mock.patch.object(handler, "handleError") as handled, redirect_stderr(io.StringIO()):
                logger.warning("the detector is inside an except block right now")
            handled.assert_called_once()
        finally:
            logger.removeHandler(handler)


class AdDetectionTests(unittest.TestCase):
    """The TWiT 1098 regression: a backend that was never loaded classified
    1,345 segments as content in 174 ms and the episode shipped as prepared."""

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.segments = [FakeSegment(0, 2, "buy this"), FakeSegment(2, 4, "content")]
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def test_the_model_is_loaded_before_detection_and_closed_after(self):
        llm = FakeLLM()
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()):
            _path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertTrue(llm.loaded)
        self.assertTrue(llm.closed)
        self.assertEqual((spans, keeps), ([], []))
        # Constrained JSON is how the tuned prompts were accepted; the proxy
        # must not strip the keyword on its way through.
        self.assertEqual(llm.requests, [{"type": "json_object"}] * 2)

    def test_a_backend_that_never_answers_is_a_failure_not_zero_ads(self):
        llm = FakeLLM(fail_generate=RuntimeError("llama_decode returned -1"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised:
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("llama_decode returned -1", str(raised.exception))
        self.assertTrue(llm.closed)

    def test_a_model_that_cannot_load_is_reported_by_name(self):
        llm = FakeLLM(fail_load=FileNotFoundError("GGUF model file not found: /models/default.gguf"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised:
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-model-unavailable")
        self.assertIn("/models/default.gguf", str(raised.exception))
        # A half-constructed backend still holds whatever it allocated.
        self.assertTrue(llm.closed)

    def test_detections_are_reported_and_the_call_count_is_journaled(self):
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(0.0, 2.0)])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=4.0):
            _path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 2.0, "label": "sponsor", "confidence": 0.9}])
        self.assertEqual(keeps, [])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.calls", stages)
        self.assertIn("ads.cut.refused", stages)

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

    def test_one_answered_singleton_does_not_turn_a_dead_backend_into_zero_ads(self):
        llm = FakeLLM(fail_generate=RuntimeError("Metal command buffer failed"))
        install_fake_ads(llm)
        original = llm.generate

        def flaky(system_prompt, user_content, *, response_format=None):
            if user_content == "content":
                llm.fail_generate = None
            return original(system_prompt, user_content, response_format=response_format)

        llm.generate = flaky
        segments = [FakeSegment(0, 2, "buy this"), FakeSegment(2, 4, "and this"), FakeSegment(4, 6, "content")]
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised:
            wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("2 of 3", str(raised.exception))


class PreflightTests(unittest.TestCase):
    """What the cut needs is checked before speech-to-text starts, not after."""

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.tools = tempfile.mkdtemp(prefix="wilted-tools.")
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tools], check=False))
        for tool in wp.CUT_TOOLS:
            path = Path(self.tools) / tool
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.default_model = Path(self.tools) / "default.gguf"
        self.default_model.write_bytes(b"GGUF")
        install_fake_wilted()
        install_fake_ads(FakeLLM())
        sys.modules["wilted.llm"].DEFAULT_GGUF_MODEL = str(self.default_model)
        # `run()` swallows a failed speech-to-text tier, so a `self.fail` in
        # the stub would be caught; record the call and assert on it instead.
        self.stt_calls: list = []
        sys.modules["wilted.transcribe"].transcribe_audio = lambda path: self.stt_calls.append(path) or []

    def test_missing_cut_tools_fail_before_any_work(self):
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent-bin"}), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run({"audioPath": str(self.audio), "removeAds": True})
        self.assertEqual(raised.exception.code, "cut-tools-missing")
        self.assertIn("ffmpeg", str(raised.exception))
        self.assertEqual(self.stt_calls, [], "speech-to-text ran without ffmpeg present")

    def test_a_named_model_that_is_not_on_disk_fails_first(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.preflight_ad_removal({"llmModel": "/models/absent.gguf"})
        self.assertEqual(raised.exception.code, "ads-model-missing")

    def test_the_default_model_is_checked_when_none_is_named(self):
        self.default_model.unlink()
        with mock.patch.dict(os.environ, {"PATH": self.tools}), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run({"audioPath": str(self.audio), "removeAds": True})
        self.assertEqual(raised.exception.code, "ads-model-missing")
        self.assertIn(str(self.default_model), str(raised.exception))
        self.assertEqual(self.stt_calls, [], "speech-to-text ran without a model to detect with")

    def test_present_tools_and_a_present_default_model_pass(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            wp.preflight_ad_removal({})

    def test_a_hub_spec_is_left_for_the_loader_to_resolve(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            wp.preflight_ad_removal({"llmModel": "hf:some/repo/model.gguf"})

    def test_skipping_ad_removal_skips_the_preflight(self):
        install_fake_wilted()
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent-bin"}), redirect_stderr(io.StringIO()):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False, "allowSpeechToText": False})
        self.assertTrue(result["ok"])


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
