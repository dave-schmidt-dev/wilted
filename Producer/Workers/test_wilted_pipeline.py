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
import time
import types
import unittest
from contextlib import contextmanager, redirect_stderr
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


def install_fake_speech_stack(
    *, events=None, evict_error=None, barrier_error=None, statuses=(), rpc_timeouts=None
):
    """Install the daemon FIFO and shared lock with deterministic behavior."""
    events = events if events is not None else []
    remaining_statuses = iter(statuses or ({"resident_models": 0, "in_flight": 1},))
    last_status = {"resident_models": 0, "in_flight": 1}
    rpc_timeouts = rpc_timeouts if rpc_timeouts is not None else []

    class DaemonUnavailable(RuntimeError):
        pass

    client = types.ModuleType("speech_stack.client")
    client.DaemonUnavailable = DaemonUnavailable

    def evict(task, **params):
        events.append(f"evict:{task}")
        rpc_timeouts.append((f"evict:{task}", params.get("timeout")))
        if evict_error is not None:
            raise evict_error
        return {"evicted": True, "task": task}

    def selftest(action, **params):
        events.append(f"barrier:{action}:{params.get('barrier', '')}")
        rpc_timeouts.append(("selftest", params.get("timeout")))
        if barrier_error is not None:
            raise barrier_error
        return params

    def status(**params):
        nonlocal last_status
        events.append("status")
        rpc_timeouts.append(("status", params.get("timeout")))
        try:
            last_status = next(remaining_statuses)
        except StopIteration:
            pass
        last_status = {"in_flight": 1, **last_status}
        return last_status

    client.evict = evict
    client.selftest = selftest
    client.status = status
    host = types.ModuleType("speech_stack.daemon.host")
    lock_dir = Path(tempfile.gettempdir()) / f"wilted-pipeline-lock-{os.getpid()}"
    lock_dir.mkdir(parents=True, exist_ok=True)
    host.state_dir = lambda: lock_dir

    daemon = types.ModuleType("speech_stack.daemon")
    daemon.host = host
    package = types.ModuleType("speech_stack")
    package.client = client
    package.daemon = daemon
    sys.modules["speech_stack"] = package
    sys.modules["speech_stack.client"] = client
    sys.modules["speech_stack.daemon"] = daemon
    sys.modules["speech_stack.daemon.host"] = host
    return client, events


@contextmanager
def recording_model_lock(events):
    """A lock double whose exit proves every model path releases it."""
    events.append("lock.enter")
    try:
        yield
    finally:
        events.append("lock.exit")


def install_fake_wilted(parse_results=None, parse_error=None, transcriptions=None):
    """Stand in for the previous project's `wilted` package.

    `transcriptions` maps a model name to the segments the daemon returns for
    it, or to an exception it raises.
    """
    transcribe = types.ModuleType("wilted.transcribe")

    def transcribe_audio(audio_path, model_name="mlx-community/parakeet-tdt-1.1b", **_):
        outcome = (transcriptions or {}).get(model_name)
        if isinstance(outcome, Exception):
            raise outcome
        if outcome is None:
            raise RuntimeError(f"no fake transcription for {model_name}")
        return outcome

    transcribe.transcribe_audio = transcribe_audio

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
    install_fake_speech_stack()
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
    boundary_content_start_id: int | None = None
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
        if response_format and response_format.get("field") == "include":
            candidate_id = int(user_content.partition("candidate=")[2])
            content_start_id = self.boundary_content_start_id
            return json.dumps({"include": content_start_id is not None and candidate_id < content_start_id}), 1
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
    if "speech_stack.client" not in sys.modules:
        install_fake_speech_stack()
    ads = types.ModuleType("wilted.ads")
    ads._SPONSOR_OPENING_RE = re.compile(  # noqa: SLF001 - matches the legacy module seam
        r"\b(?:this|the)\s+episode\s+is\s+(?:brought\s+to\s+you\s+by|sponsored\s+by)\b"
        r"|\bthis\s+message\s+is\s+brought\s+to\s+you\s+by\b"
        r"|\bpaid\s+for\s+by\b|\bpaid\s+ad\b",
        re.IGNORECASE,
    )
    ads._EXPLICIT_HOST_READ_OPENING_RE = re.compile(  # noqa: SLF001 - legacy module seam
        r"\b(?:"
        r"(?:this|the)\s+(?:episode|show)(?:\s+of\s+[^.!?]{1,80}?)?\s+(?:is\s+)?brought\s+to\s+you"
        r"(?:\s+today)?\s+by|"
        r"today(?:'s|’s|\s+is\s+our)\s+sponsor(?:\s+is)?|"
        r"our\s+sponsor\s+for\s+this\s+(?:section|segment|episode|show)"
        r")\b",
        re.IGNORECASE,
    )
    ads.AdSegment = lambda start_s, end_s, confidence, label: FakeAd(  # noqa: E731
        start_s, end_s, label, confidence
    )
    ads._refine_ad_start_from_tokens = lambda segment, _pattern: segment.start_s  # noqa: SLF001

    def merge_adjacent(items):
        merged = []
        for item in sorted(items, key=lambda ad: ad.start_s):
            if merged and item.start_s <= merged[-1].end_s + 2.0:
                previous = merged[-1]
                merged[-1] = FakeAd(
                    previous.start_s,
                    max(previous.end_s, item.end_s),
                    previous.label,
                    max(previous.confidence, item.confidence),
                )
            else:
                merged.append(item)
        return merged

    ads._merge_adjacent = merge_adjacent  # noqa: SLF001
    ads._SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT = "find verified content resumption"

    def render_segments_bounded(context_ids, segments, headers=()):
        return "\n".join([*headers, *(f"[{index}] {segments[index].text}" for index in context_ids)])

    ads._render_segments_bounded = render_segments_bounded  # noqa: SLF001
    ads._id_response_format = lambda field, ids: {"field": field, "ids": list(ids)}  # noqa: SLF001
    ads._generate_constrained_response = (  # noqa: SLF001
        lambda backend, system, transcript, response_format: backend.generate(
            system, transcript, response_format=response_format
        )
    )

    def parse_content_response(response, minimum_id, window_max):
        parsed = json.loads(response)
        if set(parsed) != {"content_start_id"}:
            raise ValueError("invalid content response")
        content_id = parsed["content_start_id"]
        if isinstance(content_id, bool) or not isinstance(content_id, int):
            raise ValueError("invalid content id")
        if not minimum_id <= content_id <= window_max:
            raise ValueError("content id outside context")
        return content_id

    ads._parse_preroll_content_response = parse_content_response  # noqa: SLF001
    ads._last_meaningful_ad_end = (  # noqa: SLF001
        lambda content_id, _minimum_id, segments: segments[content_id - 1].end_s
    )

    def probe_boundary(candidate_id, _adjacent_id, _edge, _segments, backend):
        response, _tokens = backend.generate(
            "verify immediate boundary",
            f"candidate={candidate_id}",
            response_format={"field": "include", "candidate": candidate_id},
        )
        parsed = json.loads(response)
        if set(parsed) != {"include"} or not isinstance(parsed["include"], bool):
            raise ValueError("invalid boundary response")
        return parsed["include"]

    ads._probe_boundary_candidate = probe_boundary  # noqa: SLF001

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
        with redirect_stderr(io.StringIO()):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(observed, [(True, True)])

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


class ExplicitSponsorFallbackTests(unittest.TestCase):
    def setUp(self):
        self.audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def detect(self, segments, detections, content_start_id=None):
        if content_start_id is None:
            content_start_id = max(1, len(segments) - 1)
        llm = FakeLLM(boundary_content_start_id=content_start_id)
        self.last_llm = llm
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: list(detections)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=5000.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        return spans, events

    def test_unclaimed_claude_anchor_adds_and_sorts_the_fifth_span(self):
        segments = [
            FakeSegment(
                3813.36,
                3830.0,
                "sponsor i'm really excited this week in tech brought to you this week by claud",
            ),
            FakeSegment(3830.0, 3850.0, "claude dot ai has the full product details"),
            FakeSegment(4119.56, 4139.88, "learn more about claude today"),
            FakeSegment(4139.88, 4150.0, "back to our discussion of artificial intelligence"),
        ]
        existing = [
            FakeAd(900.0, 920.0),
            FakeAd(120.0, 140.0),
            FakeAd(450.0, 470.0),
            FakeAd(700.0, 720.0),
        ]
        spans, events = self.detect(segments, existing)
        self.assertEqual([span["startSeconds"] for span in spans], [120.0, 450.0, 700.0, 900.0, 3813.36])
        self.assertEqual(
            spans[-1],
            {"startSeconds": 3813.36, "endSeconds": 4139.88, "label": "sponsor_read", "confidence": 1.0},
        )
        recovered = next(event for event in events if event["stage"] == "ads.detect.recovered")
        self.assertIn("1 spans", recovered["detail"])
        self.assertIn("3813.360-4139.880", recovered["detail"])
        self.assertEqual(self.last_llm.requests[-1]["field"], "include")

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

    def test_cta_and_domain_without_explicit_anchor_does_not_cut(self):
        spans, events = self.detect(
            [FakeSegment(10.0, 20.0, "visit example dot com to learn more about this story")],
            [],
        )
        self.assertEqual(spans, [])
        self.assertNotIn("ads.detect.recovered", [event["stage"] for event in events])

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

    def test_numeric_and_editorial_slashes_are_not_domain_evidence(self):
        segments = [
            FakeSegment(0.0, 1.0, "this week in tech brought to you this week by claud"),
            FakeSegment(1.0, 2.0, "we are available 24/7 and/or whenever you need us"),
            FakeSegment(2.0, 3.0, "get started with the discussion"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

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

    def test_abutting_detection_does_not_claim_anchor_and_recovery_extends_it(self):
        segments = [
            FakeSegment(100.0, 110.0, "this week in tech brought to you this week by claud"),
            FakeSegment(110.0, 120.0, "visit claude.ai for the details"),
            FakeSegment(120.0, 130.0, "learn more and get started"),
            FakeSegment(130.0, 140.0, "back to the show"),
        ]
        spans, events = self.detect(segments, [FakeAd(90.0, 100.0)], content_start_id=3)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (90.0, 130.0))
        self.assertIn("ads.detect.recovered", [event["stage"] for event in events])

    def test_truncated_overlapping_detection_is_extended_to_verified_content(self):
        segments = [
            FakeSegment(100.0, 110.0, "this week in tech brought to you this week by claud"),
            FakeSegment(110.0, 120.0, "visit claude dot ai"),
            FakeSegment(120.0, 130.0, "learn more about the product"),
            FakeSegment(130.0, 140.0, "back to the show"),
        ]
        spans, _events = self.detect(segments, [FakeAd(99.0, 115.0)], content_start_id=3)
        self.assertEqual((spans[0]["startSeconds"], spans[0]["endSeconds"]), (99.0, 130.0))

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
        install_legacy_recovery_fixture(llm)
        segments = [
            FakeSegment(212.25, 216.0, "our show this week brought to you by superhuman"),
            FakeSegment(216.0, 248.75, "this is the sponsor message"),
            FakeSegment(248.75, 252.0, "and now back to the show"),
        ]
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=300.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(
            spans,
            [{"startSeconds": 212.25, "endSeconds": 248.75, "label": "sponsor", "confidence": 0.97}],
        )
        self.assertEqual(llm.requests, [{"type": "json_object"}])

    def test_positive_seed_without_sponsor_opening_is_editorial_content(self):
        llm = FakeLLM(answer=json.dumps({"ads": [{"confidence": 0.97}]}))
        install_legacy_recovery_fixture(llm)
        segments = [
            FakeSegment(212.25, 216.0, "this week brought a guest to your attention"),
            FakeSegment(216.0, 248.75, "and now back to the show"),
        ]
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=300.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(spans, [])


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

    def test_all_stt_passes_finish_before_eviction_and_ad_model_load(self):
        events = []
        transcribe = sys.modules["wilted.transcribe"]
        install_fake_speech_stack(events=events)

        def transcribe_audio(path, model_name="mlx-community/parakeet-tdt-1.1b", **_):
            event = "aligned" if model_name == "mlx-community/parakeet-tdt-1.1b" else "readable"
            return events.append(event) or [FakeSegment(0, 1, "content")]

        llm = FakeLLM()
        original_load = llm.load

        def load():
            events.append("ads.load")
            original_load()

        llm.load = load
        original_close = llm.close

        def close():
            events.append("ads.close")
            original_close()

        llm.close = close
        ads = install_fake_ads(llm)
        original_detect = ads.detect_ads

        def detect(segments, backend):
            events.append("ads.detect")
            return original_detect(segments, backend)

        ads.detect_ads = detect
        with mock.patch.object(transcribe, "transcribe_audio", transcribe_audio), \
                mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(wp, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "readableTranscript": True,
                "llmModel": str(self.default_model),
            })
        self.assertEqual(
            events,
            [
                "aligned",
                "readable",
                "status",
                "ads.load",
                "ads.detect",
                "ads.close",
            ],
        )

    def test_eviction_barrier_reports_before_and_after_fifo_completion(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": 1}, {"resident_models": 0}))
        stream = io.StringIO()
        with mock.patch.object(wp.time, "sleep"), redirect_stderr(stream):
            lock = wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True)
            with lock:
                events.append("ads.work")
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertEqual(
            events,
            [
                "status",
                "evict:stt",
                "evict:tts",
                "barrier:echo:wilted-gpu-drained",
                "status",
                "ads.work",
            ],
        )
        self.assertIn("ads.model.release", stages)
        self.assertIn("ads.model.drain", stages)
        self.assertIn("ads.model.retry", stages)

    def test_daemon_unavailable_allows_the_locked_ad_model_lifecycle(self):
        events = []
        client, _ = install_fake_speech_stack(events=events)
        client.status = mock.Mock(side_effect=client.DaemonUnavailable("socket absent"))
        stream = io.StringIO()
        with redirect_stderr(stream):
            lock = wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True)
            with lock:
                events.append("ads.work")
        self.assertEqual(events, ["ads.work"])
        details = [json.loads(line)["detail"] for line in stream.getvalue().splitlines()]
        self.assertIn("speech daemon unavailable; canonical GPU lock is exclusive", details)

    def test_permanent_residency_times_out_and_prevents_ad_model_load(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": 1},))
        transcribe = sys.modules["wilted.transcribe"]
        transcribe.transcribe_audio = lambda path, **_: [FakeSegment(0, 1, "content")]
        llm = FakeLLM()
        llm.load = mock.Mock(wraps=llm.load)
        install_fake_ads(llm)
        def clock():
            return 11.0 if "evict:stt" in events else 0.0

        with mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(wp, "probe_duration", return_value=1.0), \
                mock.patch.object(wp.time, "monotonic", side_effect=clock), \
                mock.patch.object(wp.time, "sleep"), redirect_stderr(io.StringIO()), \
                self.assertRaises(wp.WorkerError) as raised:
            wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "readableTranscript": False,
                "llmModel": str(self.default_model),
            })
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("timed out waiting for exclusive GPU model admission", str(raised.exception))
        self.assertEqual(events, ["status", "evict:stt"])
        llm.load.assert_not_called()

    def test_malformed_residency_status_fails_closed_before_model_load(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": "unknown"},))
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised:
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True):
                self.fail("unsafe admission must not yield")
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("invalid speech daemon status", str(raised.exception))
        self.assertEqual(events, ["status"])

    def test_published_transcript_locks_before_load_without_stt_eviction(self):
        events = []
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "content")]})
        install_fake_speech_stack(events=events)
        llm = FakeLLM()
        original_load, original_close = llm.load, llm.close
        llm.load = lambda: events.append("ads.load") or original_load()
        llm.close = lambda: events.append("ads.close") or original_close()
        install_fake_ads(llm)
        stream = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(wp, "probe_duration", return_value=1.0), \
                redirect_stderr(stream):
            result = wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "allowSpeechToText": False,
                "llmModel": str(self.default_model),
                "publishedTranscript": {
                    "body": "WEBVTT",
                    "mediaType": "text/vtt",
                    "url": "https://x.test/a.vtt",
                },
            })
        self.assertTrue(result["ok"])
        self.assertEqual(events, ["status", "ads.load", "ads.close"])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertLess(stages.index("ads.model.wait"), stages.index("ads.model.locked"))
        self.assertLess(stages.index("ads.model.locked"), stages.index("ads.model.load"))

    def test_another_admitted_request_releases_drains_and_retries(self):
        events = []
        install_fake_speech_stack(
            events=events,
            statuses=({"resident_models": 0, "in_flight": 2}, {"resident_models": 0, "in_flight": 1}),
        )
        stream = io.StringIO()
        with redirect_stderr(stream), wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
            events.append("ads.work")
        self.assertEqual(events, ["status", "barrier:echo:wilted-gpu-drained", "status", "ads.work"])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.model.release", stages)
        self.assertIn("ads.model.retry", stages)

    def test_rpc_calls_share_one_decreasing_deadline(self):
        rpc_timeouts = []
        install_fake_speech_stack(
            statuses=({"resident_models": 1, "in_flight": 1}, {"resident_models": 0, "in_flight": 1}),
            rpc_timeouts=rpc_timeouts,
        )
        clock_value = [0.0]

        def clock():
            current = clock_value[0]
            clock_value[0] += 0.1
            return current

        with mock.patch.object(wp.time, "monotonic", side_effect=clock), \
                redirect_stderr(io.StringIO()), \
                wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True):
            pass
        budgets = [timeout for _name, timeout in rpc_timeouts]
        self.assertGreater(len(budgets), 3)
        self.assertEqual(budgets, sorted(budgets, reverse=True))
        self.assertEqual(len(budgets), len(set(budgets)))

    def test_canonical_lock_contention_reports_progress_and_times_out(self):
        install_fake_speech_stack()
        tick = [0.0]

        def clock():
            current = tick[0]
            tick[0] += 1.0
            return current

        stream = io.StringIO()
        blocked = BlockingIOError()
        blocked.errno = wp.errno.EAGAIN
        with mock.patch.object(wp.fcntl, "flock", side_effect=blocked), \
                mock.patch.object(wp.time, "monotonic", side_effect=clock), \
                mock.patch.object(wp.time, "sleep"), redirect_stderr(stream), \
                self.assertRaises(wp.WorkerError) as raised:
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
                self.fail("contended lock must not yield")
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("timed out waiting for exclusive GPU model admission", str(raised.exception))
        waits = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertGreaterEqual(sum("shared GPU inference lock" in event["detail"] for event in waits), 2)

    def test_speech_rpc_wait_reports_live_progress(self):
        stream = io.StringIO()

        def delayed(_timeout):
            time.sleep(0.02)
            return "done"

        with mock.patch.object(wp, "GPU_LOCK_PROGRESS_INTERVAL_S", 0.005), \
                mock.patch.object(wp, "STT_EVICTION_BARRIER_POLL_INTERVAL_S", 0.001), \
                redirect_stderr(stream):
            result = wp._speech_rpc_with_progress(  # noqa: SLF001 - direct invariant regression
                delayed,
                time.monotonic() + 0.2,
                "waiting for test RPC",
            )
        self.assertEqual(result, "done")
        details = [json.loads(line)["detail"] for line in stream.getvalue().splitlines()]
        self.assertTrue(any("waiting for test RPC" in detail for detail in details))

    def test_canonical_lock_is_held_through_gguf_close(self):
        install_fake_speech_stack()
        state = {"held": False, "close_saw_lock": False}

        def fake_flock(_fd, operation):
            if operation == wp.fcntl.LOCK_UN:
                state["held"] = False
            elif operation & wp.fcntl.LOCK_NB:
                if state["held"]:
                    raise BlockingIOError(wp.errno.EAGAIN, "held")
                state["held"] = True

        llm = FakeLLM()
        original_close = llm.close

        def close():
            state["close_saw_lock"] = state["held"]
            original_close()

        llm.close = close
        install_fake_ads(llm)
        with mock.patch.object(wp.fcntl, "flock", side_effect=fake_flock), redirect_stderr(io.StringIO()):
            wp.detect_and_cut(
                {"audioPath": str(self.audio)},
                self.audio,
                [],
                [FakeSegment(0, 1, "content")],
            )
        self.assertTrue(state["close_saw_lock"])
        self.assertFalse(state["held"])

    def test_model_lock_releases_after_load_inference_and_close_errors(self):
        cases = (
            (FakeLLM(fail_load=RuntimeError("load failed")), True),
            (FakeLLM(fail_generate=RuntimeError("inference failed")), True),
            (FakeLLM(), False),
        )
        for llm, raises in cases:
            with self.subTest(raises=raises):
                install_fake_ads(llm)
                if not raises:
                    llm.close = mock.Mock(side_effect=RuntimeError("close failed"))
                events = []
                if raises:
                    with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError):
                        wp.detect_and_cut(
                            {"audioPath": str(self.audio)},
                            self.audio,
                            [],
                            [FakeSegment(0, 1, "content")],
                            model_lock=recording_model_lock(events),
                        )
                else:
                    with redirect_stderr(io.StringIO()):
                        wp.detect_and_cut(
                            {"audioPath": str(self.audio)},
                            self.audio,
                            [],
                            [FakeSegment(0, 1, "content")],
                            model_lock=recording_model_lock(events),
                        )
                self.assertEqual(events, ["lock.enter", "lock.exit"])


class GlossaryTests(unittest.TestCase):
    """The show-notes glossary, with a fixed dictionary so the system word
    list's gaps do not decide what passes."""

    DICTIONARY = frozenset("""
    a the and of is are it this week in tech at big why spending trillion higher than seems
    police hiding their use surveillance cameras flock apple online platform lawsuit
    dismiss concede meta vision pro air tag using use see me plate for mean back center data
    future volt hidden reveal trash rare book train head court landmark trial
    """.split())
    NOTES = (
        "Meta faces a $1.4 trillion lawsuit, and Flock cameras are sparking a revolt.\n\n"
        "- Meta heads to court in a landmark trial\n"
        "- Why Big Tech's AI Spending Is $3 Trillion Higher Than It Seems\n"
        "- Hidden Airtag reveals Amazon is trashing rare books to train AI\n"
        "- Police Are Hiding Their Use of Flock Surveillance Cameras\n"
        "- Go Flock Yourself\n"
        "- Apple is laying off staffers working on the Vision Pro and Siri\n"
        "- NVIDIA to Back Ohio Data Center\n\n"
        "Host: Leo Laporte (https://twit.tv/people/leo-laporte)\n\n"
        "Guests: Sam Abuelsamid and Fr. Robert Ballecer, SJ (https://bsky.app/profile/padresj)\n\n"
        "Sponsors:\n- adaptivesecurity.com (https://www.adaptivesecurity.com/?utm_campaign=2026_NA_Podcast)\n"
        "- claude.ai/technology\n"
    )

    def glossary(self):
        return wp.build_glossary(self.NOTES, "TWiT 1098: Usain Volt - Meta and the Future", self.DICTIONARY)

    def test_names_sites_and_products_are_found_and_headline_words_are_not(self):
        terms = self.glossary()
        for expected in ["Leo Laporte", "Sam Abuelsamid", "Vision Pro", "NVIDIA", "Siri", "adaptivesecurity.com",
                         "claude.ai", "twit.tv", "Usain", "Laporte", "Abuelsamid", "Ballecer", "Airtag", "Amazon"]:
            self.assertIn(expected, terms)
        for unwanted in ["Why", "Spending", "Higher", "Seems", "Police", "Hiding", "Their", "Use", "Surveillance",
                         "Meta's", "Tech's", "AI", "NA", "Podcast", "Host", "Guests", "Sponsors", "Back", "Hidden"]:
            self.assertNotIn(unwanted, terms)
        # "Meta" and "Flock" are ordinary words that earn a casing rule only by
        # being written capitalized three times and never in lower case.
        self.assertIn("Flock", terms)
        self.assertIn("Meta", terms)
        self.assertEqual(terms[0], "Fr Robert Ballecer SJ", "longest phrase first so it wins over its parts")
        self.assertEqual(wp.build_glossary("", "", self.DICTIONARY), [])

    def test_exact_hits_take_the_notes_casing_and_keep_possessives(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte said meta's vision pro and flock cameras"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte said Meta's Vision Pro and Flock cameras")
        self.assertEqual(edits, 4)
        self.assertEqual(cues[0]["text"], "leo laporte said meta's vision pro and flock cameras", "input is not mutated")

    def test_near_misses_are_respelled_but_real_words_are_left_alone(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": (
            "sama boul samad joined us on twit dot t v and adaptive security dot com sponsors us "
            "while nvidia's chips ship and everyone is using an air tag and see me later"
        )}]
        out, _ = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], (
            "Sam Abuelsamid joined us on twit.tv and adaptivesecurity.com sponsors us "
            "while NVIDIA's chips ship and everyone is using an Airtag and see me later"
        ))

    def test_marks_around_a_corrected_name_survive_it(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "That is Sam Abul Samed. \"Meta's\" (nvidia), leo laporte!"}]
        out, _ = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "That is Sam Abuelsamid. \"Meta's\" (NVIDIA), Leo Laporte!")

    def test_the_stage_is_reported_and_never_fatal(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "hello nvidia"}]
        with redirect_stderr(io.StringIO()) as err:
            out = wp.polish_with_notes({"episodeNotes": self.NOTES}, cues)
        self.assertEqual(out[0]["text"], "hello NVIDIA")
        stages = [json.loads(line)["stage"] for line in err.getvalue().splitlines()]
        self.assertEqual(stages, ["transcript.glossary.terms", "transcript.glossary.complete"])
        self.assertEqual(wp.polish_with_notes({}, cues), cues, "no notes, no pass")
        with mock.patch.object(wp, "build_glossary", side_effect=RuntimeError("boom")):
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(wp.polish_with_notes({"episodeNotes": "x"}, cues), cues)
        self.assertIn("transcript.glossary.failed", err.getvalue())

    def test_a_term_at_the_very_start_and_end_of_a_cue_is_matched(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte opened the show for nvidia"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte opened the show for NVIDIA")
        self.assertEqual(edits, 2)

    def test_a_cue_of_only_punctuation_is_left_alone(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "... -- !!!"}]
        out, edits = wp.apply_glossary(cues, self.glossary(), self.DICTIONARY)
        self.assertEqual(out[0]["text"], "... -- !!!")
        self.assertEqual(edits, 0)
        self.assertIs(out[0], cues[0], "an untouched cue is the same object, not a copy")

    def test_an_empty_glossary_returns_the_cues_untouched(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte said hello"}]
        out, edits = wp.apply_glossary(cues, [], self.DICTIONARY)
        self.assertEqual(edits, 0)
        self.assertIs(out, cues, "no glossary is a no-op, not a copy")

    def test_an_unchanged_cue_is_the_identical_object_a_changed_one_is_not(self):
        untouched = {"startSeconds": 0, "endSeconds": 1, "text": "nothing here matches anything"}
        changed = {"startSeconds": 1, "endSeconds": 2, "text": "leo laporte spoke"}
        out, edits = wp.apply_glossary([untouched, changed], self.glossary(), self.DICTIONARY)
        self.assertEqual(edits, 1)
        self.assertIs(out[0], untouched, "apply_glossary must not copy cues it does not edit")
        self.assertIsNot(out[1], changed, "an edited cue is a new dict, so the input is never mutated")
        self.assertEqual(changed["text"], "leo laporte spoke", "input is not mutated")

    def test_a_locked_span_is_not_re_matched_by_a_shorter_term(self):
        cues = [{"startSeconds": 0, "endSeconds": 1, "text": "leo laporte was there"}]
        # "Laporte" alone is a near-miss of nothing inside "Leo Laporte" once
        # the longer term has claimed those words; a second, shorter term must
        # not carve a piece back out of an already-corrected name.
        out, edits = wp.apply_glossary(cues, ["Leo Laporte", "Laporte"], self.DICTIONARY)
        self.assertEqual(out[0]["text"], "Leo Laporte was there")
        self.assertEqual(edits, 1)

    def test_url_hosts_with_hyphens_and_digits_are_captured(self):
        notes = "Sponsors:\n- join-bilt.com\n- web3.com\n- gpt4.dev\n"
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        for expected in ["join-bilt.com", "web3.com", "gpt4.dev"]:
            self.assertIn(expected, terms)

    def test_names_with_unicode_letters_are_recognised(self):
        # A regression check: `_WORD` is `[A-Za-z0-9][A-Za-z0-9'&.-]*`, which
        # does not match a letter like "ö". Before this is fixed, "Söderberg"
        # splits into "S" and "derberg" and the guest's name never becomes a
        # glossary term at all -- the exact failure this feature exists to fix.
        notes = "Guest: Erik Söderberg joins us this week."
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        self.assertIn("Erik Söderberg", terms)

    def test_notes_beyond_the_32kib_cap_still_produce_a_bounded_glossary(self):
        # The 32 KiB cap on stored notes is enforced upstream (Swift); this
        # worker takes whatever `episodeNotes` it is handed, so it must not
        # choke on, or unboundedly grow terms for, a large payload.
        lines = [f"- Guest: Speaker Number{i} joins to discuss Product{i} Corp\n" for i in range(600)]
        notes = "".join(lines)
        self.assertGreater(len(notes.encode("utf-8")), 32 * 1024)
        terms = wp.build_glossary(notes, "", self.DICTIONARY)
        self.assertEqual(len(terms), wp.GLOSSARY_MAXIMUM_TERMS, "the term list is capped, not left to grow with the notes")
        self.assertTrue(all(t.startswith("Speaker Number") or t.startswith("Product") for t in terms))


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

    def test_show_notes_correct_the_transcript_before_it_is_returned(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 2, "leo laporte"), FakeSegment(2, 4, "on twit dot t v")]})
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False, "allowSpeechToText": False,
                "episodeNotes": "Host: Leo Laporte (https://twit.tv/people/leo-laporte)",
                "publishedTranscript": {"body": "WEBVTT", "mediaType": "text/vtt", "url": "https://x.test/a.vtt"},
            })
        self.assertEqual(result["text"], "Leo Laporte on twit.tv")
        self.assertEqual([c["text"] for c in result["cues"]], ["Leo Laporte", "on twit.tv"])

    def test_the_readable_pass_replaces_the_plain_transcript_when_it_heard_as_much(self):
        plain = [FakeSegment(0, 2, "hello there world"), FakeSegment(2, 4, "leo laporte here")]
        readable = [FakeSegment(0, 2, "Hello there, world."), FakeSegment(2, 4, "Leo Laporte here.")]
        install_fake_wilted(transcriptions={"mlx-community/parakeet-tdt-1.1b": plain, wp.READABLE_STT_MODEL: readable})
        with redirect_stderr(io.StringIO()) as err:
            result = wp.run({"audioPath": str(self.audio), "removeAds": False})
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["text"], "Hello there, world. Leo Laporte here.")
        stages = [json.loads(line)["stage"] for line in err.getvalue().splitlines()]
        self.assertIn("transcript.stt.readable.complete", stages)

    def test_a_short_or_failed_readable_pass_keeps_the_plain_transcript(self):
        plain = [FakeSegment(0, 2, "one two three four five six seven eight nine ten")]
        install_fake_wilted(transcriptions={"mlx-community/parakeet-tdt-1.1b": plain,
                                            wp.READABLE_STT_MODEL: [FakeSegment(0, 1, "One, two.")]})
        with redirect_stderr(io.StringIO()) as err:
            result = wp.run({"audioPath": str(self.audio), "removeAds": False})
        self.assertEqual(result["text"], "one two three four five six seven eight nine ten")
        self.assertIn("transcript.stt.readable.rejected", err.getvalue())

        install_fake_wilted(transcriptions={"mlx-community/parakeet-tdt-1.1b": plain,
                                            wp.READABLE_STT_MODEL: RuntimeError("daemon gone")})
        with redirect_stderr(io.StringIO()) as err:
            result = wp.run({"audioPath": str(self.audio), "removeAds": False})
        self.assertEqual(result["text"], "one two three four five six seven eight nine ten")
        self.assertIn("transcript.stt.readable.failed", err.getvalue())

        install_fake_wilted(transcriptions={"mlx-community/parakeet-tdt-1.1b": plain})
        with redirect_stderr(io.StringIO()) as err:
            result = wp.run({"audioPath": str(self.audio), "removeAds": False, "readableTranscript": False})
        self.assertEqual(result["text"], "one two three four five six seven eight nine ten")
        self.assertNotIn("transcript.stt.readable", err.getvalue())

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
