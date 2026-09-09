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

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKER_PATH = REPO_ROOT / "Producer" / "Workers" / "wilted_pipeline.py"


def load_ad_corpus():
    """Load the corpus scorer the same way the worker is loaded.

    `sys.modules` has to hold the module before `exec_module` runs, because
    `@dataclass` resolves its fields by looking the defining module up there.
    """
    path = REPO_ROOT / "Producer" / "Workers" / "ad_corpus.py"
    spec = importlib.util.spec_from_file_location("ad_corpus", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["ad_corpus"] = module
    spec.loader.exec_module(module)
    return module


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


def install_fake_trafilatura(text):
    """Stand in for the prose extractor.

    `extract_prose` imports `trafilatura` at call time, so whatever double was
    installed last stays in `sys.modules` for every later test. A test that
    reaches the prose tier must therefore install its own, or it inherits an
    unrelated case's answer.
    """
    module = types.ModuleType("trafilatura")
    module.extract = lambda html: text
    sys.modules["trafilatura"] = module
    return module


def prose_transcript(phrase):
    """Prose long enough to clear the word floor, carrying a locating phrase."""
    return " ".join([phrase] * (wp.MINIMUM_PROSE_WORDS // len(phrase.split()) + 1))


@dataclass
class FakeLLM:
    """The previous project's GGUF backend, as far as the worker can see it.

    It loads lazily and refuses to answer until it has: that asymmetry is the
    whole TWiT 1098 regression, so the double reproduces it exactly.
    """

    answer: str = "[]"
    classifier_answer: str = '{"ads":[]}'
    loaded: bool = False
    closed: bool = False
    fail_load: Exception | None = None
    fail_generate: Exception | None = None
    boundary_content_start_id: int | None = None
    left_boundary_include: bool | None = None
    left_boundary_answer: str | None = None
    preroll_program_start_id: int | None = None
    preroll_program_id: int | None = None
    boundary_starts_program: bool | None = None
    postroll_advertising_start_id: int | None = None
    tail_carries_program: bool | None = None
    commercial_ad_ids: list[int] | None = None
    commercial_programme_ids: list[int] | None = None
    # The closing review asks the same confirmation twice when the first answer
    # moves the boundary, so the double has to be able to answer it differently.
    program_id_answers: list = field(default_factory=list)
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
        if system_prompt in {"archive ad classifier", "archive ad classifier correction"}:
            return self.classifier_answer, 1
        # The boundary probe asks for free JSON like the coarse pass does, so the
        # system prompt is what tells them apart here as well as in the log.
        if "starts_program" in system_prompt:
            if self.boundary_starts_program is None:
                return self.answer, 1
            return json.dumps({"starts_program": self.boundary_starts_program}), 1
        if "carries_program" in system_prompt:
            if self.tail_carries_program is None:
                return self.answer, 1
            return json.dumps({"carries_program": self.tail_carries_program}), 1
        field_name = (response_format or {}).get("field")
        schema = (response_format or {}).get("schema", {})
        properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
        for commercial_field, configured in (
            ("ad_ids", self.commercial_ad_ids),
            ("programme_ids", self.commercial_programme_ids),
        ):
            if commercial_field not in properties:
                continue
            permitted = properties[commercial_field]["items"]["enum"]
            if commercial_field == "programme_ids":
                proposed = user_content.partition("Proposed commercial IDs: ")[2].partition("\n")[0]
                proposed_ids = [int(value.strip()) for value in proposed.split(",") if value.strip()]
                programme = list(configured) if configured is not None else []
                return json.dumps({
                    commercial_field: [segment_id for segment_id in programme if segment_id in proposed_ids],
                    "programme_before": (
                        any(segment_id < proposed_ids[0] for segment_id in programme)
                        if configured is not None else True
                    ),
                    "programme_after": (
                        any(segment_id > proposed_ids[-1] for segment_id in programme)
                        if configured is not None else True
                    ),
                }), 1
            if configured is not None:
                return json.dumps({commercial_field: configured}), 1
            # Ordinary legacy tests do not exercise the new recovery.  When a
            # focused test does, make the conservative default visible: only
            # the outer supplied cues are programme, never an inferred cut.
            return json.dumps({commercial_field: []}), 1
        if field_name == "program_id" and self.program_id_answers:
            return json.dumps({"program_id": self.program_id_answers.pop(0)}), 1
        for name, answer in (("program_start_id", self.preroll_program_start_id),
                             ("advertising_start_id", self.postroll_advertising_start_id),
                             ("program_id", self.preroll_program_id)):
            if field_name == name:
                return (json.dumps({name: answer}) if answer is not None else self.answer), 1
        if response_format and (
            response_format.get("field") == "include" or "include" in properties
        ):
            candidate_id = int(user_content.partition("candidate=")[2])
            if "edge=left" in user_content:
                if self.left_boundary_answer is not None:
                    return self.left_boundary_answer, 1
                if self.left_boundary_include is not None:
                    return json.dumps({"include": self.left_boundary_include}), 1
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
    class FakeAdsModule(types.ModuleType):
        def __setattr__(self, name, value):
            if name == "detect_ads" and callable(value) and not getattr(value, "_covers_classifier", False):
                raw_detector = value

                def detector_with_classifier_coverage(segments, backend):
                    ids = list(range(len(segments)))
                    rendered = "\n".join(
                        f"[ID {segment_id}] [{segment.start_s:.3f}s - {segment.end_s:.3f}s] {segment.text}"
                        for segment_id, segment in enumerate(segments)
                    )
                    for prompt in (self._AD_DETECT_SYSTEM_PROMPT, self._AD_DETECT_CORRECTION_PROMPT):
                        try:
                            response, _ = backend.generate(
                                prompt, rendered, response_format=self._AD_DETECT_RESPONSE_FORMAT
                            )
                            self._parse_ad_response(response, ids)
                            break
                        except Exception:  # noqa: BLE001 - archive retries malformed classifier responses
                            continue
                    return raw_detector(segments, backend)

                detector_with_classifier_coverage._covers_classifier = True
                value = detector_with_classifier_coverage
            super().__setattr__(name, value)

    ads = FakeAdsModule("wilted.ads")
    ads._AD_DETECT_SYSTEM_PROMPT = "archive ad classifier"
    ads._AD_DETECT_CORRECTION_PROMPT = "archive ad classifier correction"
    ads._AD_DETECT_RESPONSE_FORMAT = {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {"ads": {"type": "array"}},
            "required": ["ads"],
            "additionalProperties": False,
        },
    }

    def parse_ad_response(response, expected_ids):
        parsed = json.loads(response)
        if not isinstance(parsed, dict) or set(parsed) != {"ads"} or not isinstance(parsed["ads"], list):
            raise ValueError("invalid ads response")
        positions = {segment_id: index for index, segment_id in enumerate(expected_ids)}
        labels = {}
        for item in parsed["ads"]:
            if (not isinstance(item, list) or len(item) != 2 or isinstance(item[0], bool)
                    or not isinstance(item[0], int) or item[0] not in positions
                    or item[0] in labels or item[1] not in {
                        "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"
                    }):
                raise ValueError("invalid ad entry")
            labels[item[0]] = item[1]
        if list(labels) != sorted(labels, key=positions.__getitem__):
            raise ValueError("ads are out of order")
        return [(segment_id, segment_id in labels, labels.get(segment_id)) for segment_id in expected_ids]

    ads._parse_ad_response = parse_ad_response
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
    ads._SPARSE_PROMO_CUES = (  # noqa: SLF001 - mirrors the legacy module seam
        re.compile(r"\b(?:brought to you by|paid for by|sponsor(?:ed|ship)?)\b", re.IGNORECASE),
        re.compile(r"\b[a-z0-9-]+\.(?:com|net|org|io)\b|\bdot[ -]?com\b", re.IGNORECASE),
        re.compile(r"\b(?:(?:promo|offer|discount) code|use code)\b", re.IGNORECASE),
        re.compile(
            r"\$\s*\d|\b\d+(?:\.\d+)?\s*(?:%|percent)\s+off\b"
            r"|\b(?:price|priced|pricing|discount|free trial)\b",
            re.IGNORECASE,
        ),
        re.compile(r"\blimited[- ]time sale\b", re.IGNORECASE),
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
    attach_archive_render_helpers(ads, lambda index, _segment: f"[{index}] ")
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

    def probe_boundary(candidate_id, _adjacent_id, edge, _segments, backend):
        response, _tokens = backend.generate(
            "verify immediate boundary",
            f"edge={edge};candidate={candidate_id}",
            response_format={"field": "include", "candidate": candidate_id},
        )
        try:
            parsed = json.loads(response)
            if set(parsed) != {"include"} or not isinstance(parsed["include"], bool):
                raise ValueError("invalid boundary response")
            return parsed["include"]
        except (TypeError, ValueError):
            return None

    ads._probe_boundary_candidate = probe_boundary  # noqa: SLF001
    attach_archive_overlap_resolver(ads)

    def detect_ads(segments, backend):
        return list(detections)

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


ARCHIVE_TRUNCATION_MARKER = " \u2026[TRUNCATED]\u2026 "


def attach_archive_render_helpers(ads, segment_prefix):
    """Give a fake archive module the render helpers the worker's install needs.

    The worker builds its replacement renderer out of the archive's own prefix,
    truncation and cap, so a fake that omits them would silently skip the
    install and leave the budget arithmetic untested. The truncation is the
    archive's, copied rather than imported for the same reason the rest of this
    module fakes `wilted.ads`: the gate never loads the archive.
    """
    ads._TRUNCATION_MARKER = ARCHIVE_TRUNCATION_MARKER  # noqa: SLF001
    ads._MAX_CLASSIFICATION_BATCH_CHARS = 12_000  # noqa: SLF001
    ads._segment_prefix = segment_prefix  # noqa: SLF001

    def truncate_head_tail(text, max_chars):
        if len(text) <= max_chars:
            return text
        if max_chars <= len(ARCHIVE_TRUNCATION_MARKER):
            return ARCHIVE_TRUNCATION_MARKER[:max_chars]
        remaining = max_chars - len(ARCHIVE_TRUNCATION_MARKER)
        tail_chars = remaining // 2
        return (
            text[: (remaining + 1) // 2]
            + ARCHIVE_TRUNCATION_MARKER
            + (text[-tail_chars:] if tail_chars else "")
        )

    ads._truncate_head_tail = truncate_head_tail  # noqa: SLF001


def attach_archive_overlap_resolver(ads):
    """Give a fake archive its content-on-tie overlap resolver."""
    @dataclass(frozen=True)
    class CoarseRun:
        start_id: int
        end_id: int
        confidence: float
        label: str

    def resolve_overlaps(raw_classifications, segments):
        votes = [[] for _ in segments]
        for chunk in raw_classifications:
            for segment_id, is_ad, label in chunk:
                votes[segment_id].append((is_ad, label))
        decisions = []
        for segment_votes in votes:
            positive = [(is_ad, label) for is_ad, label in segment_votes if is_ad]
            ratio = len(positive) / len(segment_votes) if segment_votes else 0.0
            is_ad = bool(segment_votes) and len(positive) > len(segment_votes) - len(positive)
            labels = [label for _is_ad, label in positive if label is not None]
            dominant = max(sorted(set(labels)), key=labels.count) if labels else "ad_break"
            decisions.append((is_ad, ratio, dominant))
        runs = []
        index = 0
        while index < len(segments):
            if not decisions[index][0]:
                index += 1
                continue
            start_id, confidences, labels = index, [], []
            while index < len(segments) and decisions[index][0]:
                confidences.append(decisions[index][1])
                labels.extend(
                    label for is_ad, label in votes[index] if is_ad and label is not None
                )
                index += 1
            runs.append(
                CoarseRun(
                    start_id,
                    index - 1,
                    sum(confidences) / len(confidences),
                    max(sorted(set(labels)), key=labels.count),
                )
            )
        return runs

    ads._resolve_overlaps = resolve_overlaps  # noqa: SLF001 - archive seam under test
    ads._verify_sparse_content_start = (  # noqa: SLF001 - archive seam under test
        lambda coarse_run, _confirmed_start_id, _segments, _backend: coarse_run.end_id + 1
    )


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
        ads = install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(wp, "probe_duration", return_value=200.0):
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
                mock.patch.object(wp, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(observed, [(True, True)])

    def test_a_backend_that_never_answers_is_a_failure_not_zero_ads(self):
        llm = FakeLLM(fail_generate=RuntimeError("llama_decode returned -1"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(wp, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("llama_decode returned -1", str(raised.exception))
        self.assertTrue(llm.closed)

    def test_a_model_that_cannot_load_is_reported_by_name(self):
        llm = FakeLLM(fail_load=FileNotFoundError("GGUF model file not found: /models/default.gguf"))
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(wp, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(raised.exception.code, "ads-model-unavailable")
        self.assertIn("/models/default.gguf", str(raised.exception))
        # A half-constructed backend still holds whatever it allocated.
        self.assertTrue(llm.closed)

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
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=200.0):
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
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(logger.level, logging.ERROR)
        self.assertEqual([h for h in logger.handlers if isinstance(h, wp.DiscardedRuns)], [])

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

    def test_a_span_covering_most_of_the_episode_is_dropped_and_said_out_loud(self):
        # TechCrunch Daily, 9:23 long, came back 1:52 with "1 ad removed
        # (7:30)". The one span ran 0:07 to 7:37 and held two real host reads
        # at either end with every news item of the episode between them: the
        # archived detector brackets an ad that goes out and comes back as one
        # pod, bounded at ten minutes, which is the whole of a short show.
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(6.72, 456.88, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=563.17):
            path, spans, keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        # Nothing cut, and the audio handed back is the audio handed in:
        # preparation writes over the download, so an over-cut is permanent.
        self.assertEqual((path, spans, keeps), (self.audio, [], []))
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        rejected = [event for event in events if event["stage"] == "ads.detect.span.rejected"]
        self.assertEqual(len(rejected), 1)
        self.assertIn("80% of the episode", rejected[0]["detail"])

    def test_an_ordinary_ad_break_is_left_alone_by_the_size_guard(self):
        llm = FakeLLM()
        install_fake_ads(llm, detections=[FakeAd(6.72, 187.0, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=563.17):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual([span["startSeconds"] for span in spans], [6.72])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertNotIn("ads.detect.span.rejected", stages)

    def test_spans_that_are_individually_plausible_can_still_be_refused_together(self):
        # Each of these is under the single-span limit and the three together
        # take two thirds of the episode, which no episode survives being.
        llm = FakeLLM()
        install_fake_ads(llm, detections=[
            FakeAd(0.0, 240.0), FakeAd(250.0, 400.0), FakeAd(410.0, 400.0 + 90.0),
        ])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=600.0):
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

    def resize(self, llm, ad, total=563.17):
        ads = install_fake_ads(llm)
        llm.load()  # `detect_and_cut` does this; a direct call has to say so.
        stream = io.StringIO()
        with redirect_stderr(stream):
            resized = wp.resize_oversized_ad_spans(ads, llm, self.OVERSIZED, [ad], total)
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

    def test_a_shortened_span_holding_program_content_is_left_alone(self):
        # The second question is not the first asked again: it is handed only
        # the shortened span, so a boundary in the wrong place is caught by
        # finding the programme still inside it.
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=3, boundary_starts_program=False)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("holds program content at 3", details["ads.detect.span.resize.skipped"])

    def test_a_span_the_review_calls_advertising_throughout_is_not_shortened(self):
        llm = FakeLLM(preroll_program_start_id=0)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("advertising throughout", details["ads.detect.span.resize.skipped"])

    def test_a_shortening_that_is_still_implausible_is_refused(self):
        # Recovering four minutes of a nine minute episode is not a recovery.
        llm = FakeLLM(preroll_program_start_id=20, preroll_program_id=-1, boundary_starts_program=False)
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("still resumes 70% into the episode", details["ads.detect.span.resize.skipped"])

    def test_an_unanswered_resize_review_never_shortens_a_span(self):
        llm = FakeLLM(answer="not json")
        resized, details = self.resize(llm, FakeAd(6.72, 456.88))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 456.88)])
        self.assertIn("resize review failed", details["ads.detect.span.resize.skipped"])

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

    def test_a_produced_spot_after_the_sign_off_is_cut_to_the_end_of_the_file(self):
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm)
        # To the probed duration, not to the last cue: what lies between them is
        # the spot's own music bed.
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in recovered],
                         [(760.0, 810.0, "ad_break")])
        self.assertIn("after program ID 19", details["ads.detect.postroll"])

    def test_the_cut_claims_the_spots_own_leader(self):
        # The silence between the sign-off and the spot is the spot's leader,
        # and leaving it behind leaves the advertisement in. TechCrunch's is 6.3
        # seconds, The Daily's 4.2.
        leader = [*self.POSTROLL[:19], FakeSegment(766.0, 800.0, "segment 19")]
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, _details = self.postroll(llm, segments=leader)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])

    def test_a_silence_too_long_to_be_a_leader_is_left_where_it_is(self):
        # A minute of silence is more likely untranscribed program audio than a
        # spot's leader, so the claim stops fifteen seconds short of the spot
        # rather than running back to the sign-off.
        gap = [*self.POSTROLL[:19], FakeSegment(790.0, 800.0, "segment 19")]
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, _details = self.postroll(llm, segments=gap)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(775.0, 810.0)])

    def test_an_ending_the_detector_already_claimed_is_not_reviewed_again(self):
        llm = FakeLLM(postroll_advertising_start_id=19, preroll_program_id=-1)
        recovered, details = self.postroll(llm, detections=[FakeAd(760.0, 800.0)])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 800.0)])
        self.assertIn("already claimed", details["ads.detect.postroll.skipped"])
        self.assertEqual(llm.requests, [])

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

    def test_a_boundary_segment_still_carrying_the_program_starts_the_cut_after_it(self):
        # The sign-off and the spot's first words share a segment. Taking it
        # would take the show's last sentence with it.
        llm = FakeLLM(postroll_advertising_start_id=18, tail_carries_program=True,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(760.0, 810.0)])
        self.assertIn("still running inside segment 18", details["ads.detect.boundary.shortened"])

    def test_an_ending_too_short_to_be_a_spot_is_left_alone(self):
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        recovered, details = self.postroll(llm, total=765.0)
        self.assertEqual(recovered, [])
        self.assertIn("too short", details["ads.detect.postroll.skipped"])

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

    def test_an_unanswered_closing_review_never_cuts(self):
        llm = FakeLLM(answer="not json")
        recovered, details = self.postroll(llm)
        self.assertEqual(recovered, [])
        self.assertIn("closing review failed", details["ads.detect.postroll.skipped"])

    def test_a_plausible_span_is_never_sent_for_review(self):
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=False)
        resized, _details = self.resize(llm, FakeAd(6.72, 187.0))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(6.72, 187.0)])
        self.assertEqual(llm.requests, [])

    def test_a_shortened_span_survives_the_size_guard_and_is_cut(self):
        # End to end: the opening review passes because the detection already
        # starts at the first second, the resize shortens it, and the guard
        # that would have dropped it whole now finds it plausible.
        llm = FakeLLM(preroll_program_start_id=9, preroll_program_id=-1, boundary_starts_program=False)
        install_fake_ads(llm, detections=[FakeAd(0.0, 456.88, label="sponsor_read")])
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=563.17):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.OVERSIZED)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 180.0,
                                  "label": "sponsor_read", "confidence": 0.9}])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.span.resized", stages)
        self.assertNotIn("ads.detect.span.rejected", stages)

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
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        # The cut runs to where the program begins, not to the last
        # advertising cue: the thirty-two seconds between them are the spot's
        # own music bed, and leaving them is leaving the advertisement in.
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 84.5,
                                  "label": "ad_break", "confidence": 1.0}])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.detect.preroll", stages)

    def test_an_opening_that_still_holds_program_content_is_left_alone(self):
        # The second question is the guard against cutting a cold open: it is
        # handed only the passage the first answer nominated, and finding the
        # hosts inside it withdraws the whole span.
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=1)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        skipped = [json.loads(line) for line in stream.getvalue().splitlines()
                   if json.loads(line)["stage"] == "ads.detect.preroll.skipped"]
        self.assertIn("program content at 1", skipped[0]["detail"])

    def test_a_show_that_opens_on_itself_is_never_asked_twice(self):
        llm = FakeLLM(preroll_program_start_id=0)
        install_fake_ads(llm)
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_id"], [])

    def test_a_pre_roll_too_short_to_be_an_advertisement_is_left_alone(self):
        # A positive answer one segment in is more likely the model splitting
        # a sentence than a spot worth cutting.
        llm = FakeLLM(preroll_program_start_id=1, preroll_program_id=-1)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [])
        self.assertIn("only 6.4s long", stream.getvalue())

    def test_an_opening_the_detector_already_claimed_is_not_reviewed_again(self):
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=-1)
        install_fake_ads(llm, detections=[FakeAd(0.0, 51.9)])
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 51.9,
                                  "label": "sponsor", "confidence": 0.9}])
        self.assertEqual([r for r in llm.requests if r.get("field") == "program_start_id"], [])

    def test_an_opening_the_detector_claimed_only_part_of_is_still_reviewed(self):
        # Giant Bombcast 955 shipped this way: the detector called 13.0-131.1 an
        # advertisement and left the spot's first thirteen seconds in front of
        # it, so the episode opened on an insurance commercial. A span that
        # starts after the first second does not mean the opening is handled.
        llm = FakeLLM(preroll_program_start_id=2, preroll_program_id=-1)
        install_fake_ads(llm, detections=[FakeAd(6.4, 51.9)])
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=200.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.PREROLL)
        # One span, from the first second to where the program begins: the
        # recovered opening absorbs the partial detection rather than sitting
        # beside it.
        self.assertEqual(spans, [{"startSeconds": 0.0, "endSeconds": 84.5,
                                  "label": "ad_break", "confidence": 1.0}])

    def test_an_unanswered_opening_review_never_cuts(self):
        llm = FakeLLM(fail_generate=None)
        install_fake_ads(llm)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=200.0):
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
                mock.patch.object(wp, "probe_duration", return_value=200.0):
            wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(raised.exception.code, "ads-backend-failed")
        self.assertIn("3 of 4", str(raised.exception))


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


class ProportionalRenderBudgetTests(unittest.TestCase):
    """The classifier must see a whole sponsor read whenever the batch fits."""

    # Shaped like a real classification window: a long host read beside the
    # short conversational cues that surround it. Under the archive's equal
    # split the short cues hold budget they cannot spend and the read loses its
    # middle, which is how the Practical AI Framer read reached the model with
    # its call to action cut out.
    HOST_READ = (
        "our sponsor framer is the pro website builder for creators teams and "
        "businesses that want to look professional without hiring a designer "
        "and you can start free today at framer dot com slash practical ai for "
        "thirty percent off your first year of a pro plan"
    )
    CUES = ["right", "yeah exactly", HOST_READ, "mm hmm", "that is wild", "okay so"]

    def setUp(self):
        self.ads = install_fake_ads(FakeLLM())
        wp.install_proportional_render_budget(self.ads)
        self.segments = [
            FakeSegment(float(index) * 10, float(index + 1) * 10, text)
            for index, text in enumerate(self.CUES)
        ]
        self.ids = list(range(len(self.CUES)))

    def render(self, max_chars, ids=None, headers=None):
        return self.ads._render_segments_bounded(
            self.ids if ids is None else ids, self.segments, headers, max_chars
        )

    @staticmethod
    def flat_budgets(lengths, text_budget):
        """The equal split this replaces, for contrast."""
        share, remainder = divmod(text_budget, len(lengths))
        return [share + (position < remainder) for position in range(len(lengths))]

    def fixed_chars(self, ids, headers=()):
        prefixes = [self.ads._segment_prefix(i, self.segments[i]) for i in ids]
        line_count = len(headers) + len(ids)
        return sum(map(len, headers)) + sum(map(len, prefixes)) + max(0, line_count - 1)

    def fits_cap(self):
        # Shaped like a real window: the whole batch fits, and one equal share
        # does not cover the host read. Both halves matter -- the first is why
        # nothing should be truncated, the second is why the archive was.
        return self.fixed_chars(self.ids) + 400

    def test_a_batch_that_fits_renders_every_cue_in_full(self):
        rendered = self.render(self.fits_cap())
        self.assertNotIn(self.ads._TRUNCATION_MARKER, rendered)
        for text in self.CUES:
            self.assertIn(text, rendered)

    def test_the_equal_split_would_have_truncated_the_read_that_fits(self):
        # The defect, stated as arithmetic: the batch is well under the cap and
        # the archive truncates anyway, because the short cues are handed a
        # share of the budget they will never use.
        budget = self.fits_cap() - self.fixed_chars(self.ids)
        lengths = [len(text) for text in self.CUES]
        self.assertLess(sum(lengths), budget, "this batch fits under the cap in full")
        flat = self.flat_budgets(lengths, budget)
        self.assertLess(flat[2], lengths[2], "the equal split truncates the host read")
        proportional = wp._proportional_render_budgets(lengths, budget)
        self.assertEqual(proportional, lengths, "every cue is given exactly what it needs")

    def test_over_budget_batches_stay_under_the_cap_and_keep_the_short_cues(self):
        cap = self.fixed_chars(self.ids) + 120
        rendered = self.render(cap)
        self.assertLessEqual(len(rendered), cap)
        self.assertIn(self.ads._TRUNCATION_MARKER, rendered)
        lines = rendered.split("\n")
        self.assertEqual(len(lines), len(self.CUES))
        for index, text in enumerate(self.CUES):
            if index == 2:
                continue
            self.assertIn(text, lines[index], "a short cue is never truncated to pay for a long one")
        self.assertIn(self.ads._TRUNCATION_MARKER, lines[2])

    def test_uniform_cues_render_exactly_as_the_equal_split_did(self):
        # The fallback has to be the behaviour it replaces, or this is a
        # rewrite of the archive's renderer rather than a budget fix.
        lengths = [400, 400, 400, 400]
        self.assertEqual(
            wp._proportional_render_budgets(lengths, 802), self.flat_budgets(lengths, 802)
        )

    def test_every_allocation_spends_no_more_than_the_budget(self):
        for lengths, budget in (
            ([5, 5, 5], 9),
            ([1, 1, 900], 100),
            ([0, 0, 0], 7),
            ([300], 12),
            ([], 50),
            ([2, 3, 4, 500, 600], 61),
        ):
            with self.subTest(lengths=lengths, budget=budget):
                budgets = wp._proportional_render_budgets(lengths, budget)
                self.assertEqual(len(budgets), len(lengths))
                self.assertLessEqual(sum(budgets), budget)
                for allocated, length in zip(budgets, lengths):
                    self.assertGreaterEqual(allocated, 0)
                if sum(lengths) <= budget:
                    self.assertEqual(budgets, lengths, "a batch that fits is never truncated")

    def test_prefixes_order_and_headers_are_unchanged(self):
        headers = ["window 0", "classify each ID"]
        rendered = self.render(self.fits_cap() + sum(map(len, headers)) + 2, headers=headers)
        lines = rendered.split("\n")
        self.assertEqual(lines[: len(headers)], headers)
        for index, line in enumerate(lines[len(headers) :]):
            self.assertTrue(line.startswith(self.ads._segment_prefix(index, self.segments[index])))

    def test_required_ids_that_cannot_fit_are_still_a_contract_failure(self):
        with self.assertRaises(ValueError):
            self.render(self.fixed_chars(self.ids) - 1)

    def test_repeated_install_replaces_the_renderer_once(self):
        once = self.ads._render_segments_bounded
        wp.install_proportional_render_budget(self.ads)
        self.assertIs(self.ads._render_segments_bounded, once)

    def test_a_missing_archive_helper_is_a_contract_failure(self):
        ads = install_fake_ads(FakeLLM())
        del ads._truncate_head_tail
        with self.assertRaises(AttributeError):
            wp.install_proportional_render_budget(ads)


class ContextAwareOverlapVoteTests(unittest.TestCase):
    """Only a better-context positive run overrides the archive's tie rule."""

    def setUp(self):
        self.ads = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(self.ads)
        self.segments = [
            FakeSegment(float(index), float(index + 1), f"cue {index}")
            for index in range(5)
        ]

    def resolve(self, raw_classifications):
        return self.ads._resolve_overlaps(raw_classifications, self.segments)  # noqa: SLF001

    @staticmethod
    def run_shape(runs):
        return [
            (run.start_id, run.end_id, run.confidence, run.label)
            for run in runs
        ]

    def test_contextual_tie_recovers_the_label_and_context_only_confidence(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        runs = self.resolve(
            [
                [
                    (0, False, None),
                    (1, True, "self_promo"),
                    (2, True, "self_promo"),
                    (3, True, "self_promo"),
                    (4, False, None),
                ],
                [(2, False, None), (3, False, None), (4, False, None)],
            ]
        )
        self.assertEqual(self.run_shape(runs), [(1, 3, 1.0, "self_promo")])
        self.assertGreaterEqual(runs[0].confidence, 0.8)

    def test_an_ordinary_tie_remains_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertEqual(
            self.resolve([[(1, True, "self_promo")], [(1, False, None)]]),
            [],
        )

    def test_runs_touching_either_source_window_edge_remain_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        cases = (
            [
                [(0, True, "self_promo"), (1, True, "self_promo"), (2, False, None)],
                [(0, False, None), (1, False, None)],
            ],
            [
                [(0, False, None), (1, True, "self_promo"), (2, True, "self_promo")],
                [(1, False, None), (2, False, None)],
            ],
        )
        for classifications in cases:
            with self.subTest(classifications=classifications):
                self.assertEqual(self.resolve(classifications), [])

    def test_content_window_starting_outside_the_run_remains_content(self):
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertEqual(
            self.resolve(
                [
                    [
                        (0, False, None),
                        (1, True, "self_promo"),
                        (2, True, "self_promo"),
                        (3, False, None),
                    ],
                    [
                        (0, False, None),
                        (1, False, None),
                        (2, False, None),
                        (3, False, None),
                    ],
                ]
            ),
            [],
        )

    def test_missing_resolver_raises_and_reinstallation_is_idempotent(self):
        with self.assertRaises(AttributeError):
            wp.install_context_aware_overlap_resolution(types.ModuleType("wilted.ads"))
        missing_sparse_verifier = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(missing_sparse_verifier)
        del missing_sparse_verifier._verify_sparse_content_start  # noqa: SLF001
        with self.assertRaises(AttributeError):
            wp.install_context_aware_overlap_resolution(missing_sparse_verifier)
        wp.install_context_aware_overlap_resolution(self.ads)
        installed = self.ads._resolve_overlaps  # noqa: SLF001
        installed_sparse_verifier = self.ads._verify_sparse_content_start  # noqa: SLF001
        wp.install_context_aware_overlap_resolution(self.ads)
        self.assertIs(self.ads._resolve_overlaps, installed)  # noqa: SLF001
        self.assertIs(
            self.ads._verify_sparse_content_start,  # noqa: SLF001
            installed_sparse_verifier,
        )

    def test_detection_installs_the_resolver_before_the_archive_detector_runs(self):
        llm = FakeLLM(loaded=True)
        ads = install_fake_ads(llm)
        observed = []

        def detector(segments, backend):
            observed.append(
                getattr(
                    ads._resolve_overlaps,  # noqa: SLF001
                    wp._CONTEXT_AWARE_OVERLAP_MARKER,
                    False,
                )
            )
            backend.generate(
                ads._AD_DETECT_SYSTEM_PROMPT,  # noqa: SLF001
                "\n".join(
                    f"[ID {index}] [{segment.start_s:.2f}s - {segment.end_s:.2f}s] {segment.text}"
                    for index, segment in enumerate(segments)
                ),
                response_format=ads._AD_DETECT_RESPONSE_FORMAT,  # noqa: SLF001
            )
            return []

        ads.detect_ads = detector
        with redirect_stderr(io.StringIO()):
            wp.analyze_ad_detections(ads, llm, self.segments, 5.0)
        self.assertEqual(observed, [True])


class ContextRecoveredBoundaryTests(unittest.TestCase):
    """Context provenance suppresses only the archive's sparse right expansion."""

    def setUp(self):
        self.ads = types.ModuleType("wilted.ads")
        attach_archive_overlap_resolver(self.ads)
        self.segments = [
            FakeSegment(float(index), float(index + 1), f"cue {index}")
            for index in range(194)
        ]
        self.sparse_calls = []

        def sparse_content_start(coarse_run, confirmed_start_id, _segments, _backend):
            self.sparse_calls.append((coarse_run.start_id, coarse_run.end_id, confirmed_start_id))
            return 193

        self.ads._verify_sparse_content_start = sparse_content_start  # noqa: SLF001

        def verify_boundaries(coarse_run, segments, backend):
            verified_start = coarse_run.start_id
            for _ in range(2):
                candidate_id = verified_start - 1
                if candidate_id < 0 or candidate_id != 182:
                    break
                verified_start = candidate_id
            verified_end = coarse_run.end_id
            if coarse_run.end_id - coarse_run.start_id + 1 <= 2:
                content_start_id = self.ads._verify_sparse_content_start(  # noqa: SLF001
                    coarse_run, verified_start, segments, backend
                )
                verified_end = content_start_id - 1
            return verified_start, verified_end, coarse_run.confidence, coarse_run.label

        self.ads._verify_ad_boundaries = verify_boundaries  # noqa: SLF001
        wp.install_context_aware_overlap_resolution(self.ads)

    @staticmethod
    def contextual_votes():
        return [
            [
                (182, False, None),
                (183, True, "self_promo"),
                (184, True, "self_promo"),
                (185, False, None),
            ],
            [(segment_id, False, None) for segment_id in range(183, 194)],
        ]

    @staticmethod
    def ordinary_sparse_votes():
        return [[(183, True, "self_promo"), (184, True, "self_promo")]]

    def detect(self, raw_classifications):
        runs = self.ads._resolve_overlaps(raw_classifications, self.segments)  # noqa: SLF001
        return [
            self.ads._verify_ad_boundaries(run, self.segments, object())  # noqa: SLF001
            for run in runs
        ]

    def test_context_recovery_keeps_the_coarse_right_edge_after_left_probe(self):
        self.assertEqual(
            self.detect(self.contextual_votes()),
            [(182, 184, 1.0, "self_promo")],
        )
        self.assertEqual(self.sparse_calls, [])

    def test_next_ordinary_sparse_run_still_uses_right_boundary_expansion(self):
        self.detect(self.contextual_votes())
        self.sparse_calls.clear()
        self.assertEqual(
            self.detect(self.ordinary_sparse_votes()),
            [(182, 192, 1.0, "self_promo")],
        )
        self.assertEqual(self.sparse_calls, [(183, 184, 182)])


class ExplicitSponsorRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def detect(self, segments, detections, content_start_id=None, duration=5000.0, **llm_kwargs):
        if content_start_id is None:
            content_start_id = max(1, len(segments) - 1)
        llm = FakeLLM(boundary_content_start_id=content_start_id, **llm_kwargs)
        self.last_llm = llm
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: list(detections)
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=duration):
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

    def test_cue_by_cue_review_recovers_a_bounded_explicit_read(self):
        segments = [
            FakeSegment(0.0, 10.0, "we were discussing the episode topic"),
            FakeSegment(10.0, 20.0, "the interview continues"),
            FakeSegment(20.0, 30.0, "this episode is brought to you by acme"),
            FakeSegment(30.0, 40.0, "visit acme dot com to get started today"),
            FakeSegment(40.0, 50.0, "now back to the episode discussion"),
            FakeSegment(50.0, 60.0, "the interview continues"),
        ]
        spans, _events = self.detect(
            segments, [], content_start_id=4, duration=500.0,
        )
        self.assertEqual(
            spans,
            [{"startSeconds": 20.0, "endSeconds": 40.0,
              "label": "sponsor_read", "confidence": 1.0}],
        )

    def test_cue_by_cue_review_preserves_an_interior_programme_cue(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before the read"),
            FakeSegment(10.0, 20.0, "another programme cue before the read"),
            FakeSegment(20.0, 30.0, "this episode is brought to you by acme"),
            FakeSegment(30.0, 40.0, "the guest answers the editorial question"),
            FakeSegment(40.0, 50.0, "visit acme dot com to get started today"),
            FakeSegment(50.0, 60.0, "more programme after the read"),
        ]
        spans, events = self.detect(
            segments, [], content_start_id=3, duration=500.0,
        )
        self.assertEqual(spans, [])
        self.assertIn("found programme before evidence", " ".join(event["detail"] for event in events))

    def test_transcript_start_anchor_also_preserves_an_interior_programme_cue(self):
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by acme"),
            FakeSegment(10.0, 20.0, "the guest answers the editorial question"),
            FakeSegment(20.0, 30.0, "visit acme dot com to get started today"),
            FakeSegment(30.0, 40.0, "more programme after the read"),
        ]
        spans, events = self.detect(
            segments, [], content_start_id=1, duration=500.0,
        )
        self.assertEqual(spans, [])
        self.assertIn("found programme before evidence", " ".join(event["detail"] for event in events))

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

    def test_the_exact_granola_missing_leading_word_variant_recovers_on_raw_timing(self):
        # The single Parakeet 1.1B pass omitted only the leading word. This
        # narrow compatibility anchor still takes every boundary from its raw
        # cues and still needs CTA/domain evidence plus verified content return.
        segments = [
            FakeSegment(4066.16, 4076.0, "  for the show comes from granola"),
            FakeSegment(4076.0, 4095.0, "visit granola dot com for the details"),
            FakeSegment(4095.0, 4122.76, "learn more and get started today"),
            FakeSegment(4122.76, 4132.0, "back to the gadget discussion"),
        ]
        spans, events = self.detect(segments, [], content_start_id=3)
        self.assertEqual(
            spans,
            [{"startSeconds": 4066.16, "endSeconds": 4122.76,
              "label": "sponsor_read", "confidence": 1.0}],
        )
        nominated = next(event for event in events if event["stage"] == "ads.detect.recovery.nominated")
        self.assertIn("raw anchor ID 0", nominated["detail"])
        self.assertIn("4066.160s", nominated["detail"])

    def test_raw_anchor_ids_are_unique_and_deterministic(self):
        segments = [FakeSegment(4066.16, 4076.0, "for the show comes from granola")]
        ads = install_fake_ads(FakeLLM())
        pattern = wp.explicit_sponsor_opening_pattern(ads)
        nominated = [
            (anchor_id, segments[anchor_id].start_s)
            for anchor_id in wp.explicit_sponsor_anchor_ids(segments, pattern)
        ]
        repeated = [
            (anchor_id, segments[anchor_id].start_s)
            for anchor_id in wp.explicit_sponsor_anchor_ids(segments, pattern)
        ]
        self.assertEqual(nominated, [(0, 4066.16)])
        self.assertEqual(repeated, nominated)

    def test_the_granola_variant_without_cta_and_domain_does_not_cut(self):
        segments = [
            FakeSegment(4066.16, 4076.0, "for the show comes from granola"),
            FakeSegment(4076.0, 4086.0, "the hosts continue their discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=1)
        self.assertEqual(spans, [])

    def test_the_granola_variant_requires_a_domain_not_only_name_recurrence(self):
        segments = [
            FakeSegment(100.0, 110.0, "for the show comes from granola"),
            FakeSegment(110.0, 120.0, "granola helps you work and granola keeps notes"),
            FakeSegment(120.0, 130.0, "try granola today and learn more"),
            FakeSegment(130.0, 140.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=3)
        self.assertEqual(spans, [])

    def test_the_missing_word_variant_rejects_offer_code_only_corroboration(self):
        segments = [
            FakeSegment(100.0, 110.0, "for this show comes from acme"),
            FakeSegment(110.0, 120.0, "use promo code acme and learn more today"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(spans, [])

    def test_the_generic_missing_leading_word_variant_cuts_with_full_corroboration(self):
        segments = [
            FakeSegment(100.0, 110.0, "for the show comes from acme"),
            FakeSegment(110.0, 120.0, "visit acme dot com to learn more"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, _events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(
            spans,
            [{"startSeconds": 100.0, "endSeconds": 120.0,
              "label": "sponsor_read", "confidence": 1.0}],
        )

    def test_editorial_non_anchor_phrasing_does_not_nominate(self):
        segments = [
            FakeSegment(100.0, 110.0, "the idea for the show comes from acme research"),
            FakeSegment(110.0, 120.0, "visit acme dot com to learn more"),
            FakeSegment(120.0, 130.0, "back to the gadget discussion"),
        ]
        spans, events = self.detect(segments, [], content_start_id=2)
        self.assertEqual(spans, [])
        self.assertNotIn("ads.detect.recovery.nominated", [event["stage"] for event in events])

    def test_post_cut_audit_fails_if_a_proposed_explicit_anchor_is_dropped(self):
        segments = [
            FakeSegment(0.0, 10.0, "support for the show comes from granola"),
            FakeSegment(10.0, 20.0, "visit granola dot com for the details"),
            FakeSegment(20.0, 30.0, "learn more and get started today"),
            FakeSegment(30.0, 40.0, "back to the gadget discussion"),
        ]
        with self.assertRaises(wp.WorkerError) as raised:
            self.detect(segments, [], content_start_id=3, duration=50.0)
        self.assertEqual(raised.exception.code, "ads-recovery-audit-failed")

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

    def test_a_sponsor_whose_address_is_ordinary_words_is_recovered_by_its_own_name(self):
        # Giant Bombcast 955 shipped with this ninety-second read intact. The
        # detector found the anchor and the recovery declined it: the address
        # is videogame.town, which an unpunctuated transcript writes as three
        # ordinary words, so every address pattern in the gate found nothing.
        # The sponsor's name came back thirteen times, which is what a read is.
        segments = [
            FakeSegment(3455.16, 3458.28, "this episode is brought to you by video game town"),
            FakeSegment(3458.28, 3470.52, "video game town is an independent media site with fascinating articles"),
            FakeSegment(3470.52, 3483.32, "video game town proudly presents the best in gaming coverage"),
            FakeSegment(3483.32, 3499.68, "video game town is run by two friends grant and jared"),
            FakeSegment(3499.68, 3517.76, "so check them out at video game town wherever you get your podcasts"),
            FakeSegment(3527.0, 3540.0, "holy moly don't get discombobulated folks"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(
            spans,
            [{"startSeconds": 3455.16, "endSeconds": 3517.76,
              "label": "sponsor_read", "confidence": 1.0}],
        )

    def test_a_recurring_name_without_a_call_to_action_does_not_cut(self):
        # Recurrence replaces the address, not the instruction. A company
        # discussed at length is still a company being discussed.
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by video game town"),
            FakeSegment(10.0, 20.0, "video game town keeps coming up in the news this week"),
            FakeSegment(20.0, 30.0, "video game town hired three people"),
            FakeSegment(30.0, 40.0, "video game town is still a small operation"),
            FakeSegment(40.0, 50.0, "anyway that was the news"),
        ]
        spans, events = self.detect(segments, [])
        self.assertEqual(spans, [])
        self.assertIn("ads.detect.recovery.skipped", [event["stage"] for event in events])

    def test_a_name_that_only_recurs_minutes_later_is_not_a_read(self):
        # Ten minutes is long enough for a topic to be named this often
        # honestly, so recurrence only counts while it is dense.
        segments = [
            FakeSegment(0.0, 10.0, "this episode is brought to you by video game town"),
            FakeSegment(120.0, 130.0, "video game town came up again"),
            FakeSegment(240.0, 250.0, "video game town once more"),
            FakeSegment(360.0, 370.0, "video game town a third time"),
            FakeSegment(380.0, 390.0, "go check it out"),
            FakeSegment(400.0, 410.0, "back to the show"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

    def test_the_anchors_own_naming_is_not_recurrence(self):
        # "brought to you by Video Game Town Video Game Town is an independent"
        # is one naming run into the next sentence by a transcript with no
        # punctuation. Counting it would give every anchor a free mention.
        anchor = "this episode is brought to you by video game town video game town is an"
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        pattern = ads._EXPLICIT_HOST_READ_OPENING_RE
        counts = {}
        wp.count_sponsor_name_mentions(
            wp.sponsor_name_recurrence_text(anchor, pattern),
            wp.explicit_sponsor_name_phrases(anchor, pattern),
            counts,
        )
        self.assertEqual(counts.get("video game town", 0), 0)

    def test_evidence_patterns_cover_how_a_host_read_actually_reads(self):
        # Every one of these was a miss: `.town` is not in a 2005 top-level
        # domain list, and "check them out" is not "check it out".
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE.search("check them out at videogame.town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_DOT_DOMAIN_RE.search("that is videogame dot town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_CTA_RE.search("so check them out at videogame.town"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_CTA_RE.search("and be sure to subscribe wherever you listen"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_SPOKEN_PATH_RE.search("directly support at patreon slash videogametown"))
        self.assertIsNotNone(wp.EXPLICIT_SPONSOR_OFFER_CODE_RE.search("use code wilted for ten percent off"))
        # A figure of speech is not an address, and a person is not a sponsor.
        self.assertIsNone(wp.EXPLICIT_SPONSOR_SPOKEN_PATH_RE.search("he is a writer slash producer"))
        self.assertIsNone(wp.EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE.search("we talked about that yesterday"))

    def test_a_partner_named_mid_sentence_is_recovered(self):
        # Practical AI's Framer read, as the aligned transcript actually carries
        # it. Nothing announces the read: it opens inside a sentence about being
        # a business owner and names the sponsor as "our partner". Every window
        # covering it classified all four cues as content with the vanity URL and
        # the discount in plain view, so the anchor is the only thing left.
        segments = [
            FakeSegment(1117.52, 1137.70, "that's why i appreciate so much what our partner framer is doing framer is the"),
            FakeSegment(1137.70, 1157.80, "pro website builder for creators teams and businesses that want a professional site"),
            FakeSegment(1157.80, 1166.30, "you can learn more about framer"),
            FakeSegment(1166.90, 1186.92, "get started building for free today at framer dot com slash practical ai for thirty percent off"),
            FakeSegment(1186.92, 1194.80, "so that is super cool i'm going to borrow those techniques myself"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(
            spans,
            [{"startSeconds": 1117.52, "endSeconds": 1186.92,
              "label": "sponsor_read", "confidence": 1.0}],
        )

    def test_a_business_partner_named_in_conversation_is_not_a_read(self):
        # "Our partner" is ordinary speech as well as sponsor language, which is
        # why anchoring on it is only safe while the recovery still demands its
        # two independent signals. A company discussed at length is a company
        # being discussed.
        segments = [
            FakeSegment(0.0, 10.0, "we built that integration with our partner northwind logistics last year"),
            FakeSegment(10.0, 20.0, "northwind logistics had run into exactly the same problem we did"),
            FakeSegment(20.0, 30.0, "northwind logistics eventually solved it in house"),
            FakeSegment(30.0, 40.0, "anyway back to the architecture question"),
        ]
        spans, _events = self.detect(segments, [])
        self.assertEqual(spans, [])

    def test_the_partner_anchor_names_the_sponsor_and_needs_one(self):
        ads = install_fake_ads(FakeLLM())
        wp.install_legacy_sponsor_opening_compatibility(ads)
        pattern = wp.explicit_sponsor_opening_pattern(ads)
        self.assertIn(
            "framer",
            wp.explicit_sponsor_name_phrases(
                "what our partner framer is doing framer is the", pattern
            ),
        )
        # An anchor with nothing after it names nobody, so it can raise no
        # recurrence evidence and cannot carry a recovery on its own.
        self.assertEqual(wp.explicit_sponsor_name_phrases("thanks to our partner", pattern), [])

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

    def consecutive_preroll(self, *, left_include=None, left_answer=None, anchor_start=20.4):
        segments = [
            FakeSegment(0.24, 20.4, "produced conversational first sponsor spot"),
            FakeSegment(anchor_start, 32.88, "support for the show comes from acme at acme dot com"),
            FakeSegment(33.52, 42.16, "the sponsor describes its service"),
            FakeSegment(42.72, 62.96, "visit today to learn more about the service"),
            FakeSegment(62.96, 66.08, "get started at acme dot com"),
            FakeSegment(68.48, 80.0, "the hosts begin the episode discussion"),
        ]
        llm = FakeLLM(
            boundary_content_start_id=5,
            left_boundary_include=left_include,
            left_boundary_answer=left_answer,
        )
        self.last_llm = llm
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: []
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(wp, "probe_duration", return_value=5000.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        return spans, [json.loads(line) for line in stream.getvalue().splitlines()]

    def test_consecutive_opening_spots_join_the_verified_anchor_to_transcript_start(self):
        spans, events = self.consecutive_preroll(left_include=True)
        self.assertEqual(
            spans,
            [{"startSeconds": 0.0, "endSeconds": 66.08,
              "label": "sponsor_read", "confidence": 1.0}],
        )
        extended = next(
            event for event in events
            if event["stage"] == "ads.detect.recovery.preroll.extended"
        )
        self.assertIn("anchor ID 1", extended["detail"])
        self.assertIn("prefix ID 0", extended["detail"])

    def test_a_false_left_probe_keeps_the_explicit_anchor_boundary(self):
        spans, events = self.consecutive_preroll(left_include=False)
        self.assertEqual(spans[0]["startSeconds"], 20.4)
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=false", left["detail"])

    def test_an_unanswered_left_probe_keeps_the_explicit_anchor_boundary(self):
        spans, events = self.consecutive_preroll(left_answer="not json")
        self.assertEqual(spans[0]["startSeconds"], 20.4)
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=unanswered", left["detail"])

    def test_a_failed_left_probe_keeps_the_explicit_anchor_boundary(self):
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        ads._probe_boundary_candidate = mock.Mock(side_effect=RuntimeError("probe failed"))
        segments = [
            FakeSegment(0.24, 20.4, "produced conversational first sponsor spot"),
            FakeSegment(20.4, 32.88, "support for the show comes from acme"),
        ]
        stream = io.StringIO()
        with redirect_stderr(stream):
            start_s = wp.consecutive_preroll_start(ads, llm, segments, 1)
        self.assertEqual(start_s, 20.4)
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        left = next(event for event in events if event["stage"] == "ads.detect.recovery.preroll.left")
        self.assertIn("include=unanswered", left["detail"])

    def test_a_non_opening_anchor_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 10.0, "editorial opening"),
            FakeSegment(10.0, 20.0, "produced promotion"),
            FakeSegment(20.0, 30.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 2), 20.0)
        self.assertEqual(llm.requests, [])

    def test_an_anchor_after_the_first_minute_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 50.0, "produced promotion"),
            FakeSegment(60.01, 70.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 1), 60.01)
        self.assertEqual(llm.requests, [])

    def test_a_left_gap_greater_than_fifteen_seconds_cannot_extend_to_transcript_start(self):
        llm = FakeLLM(left_boundary_include=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(0.0, 10.0, "produced promotion"),
            FakeSegment(25.01, 35.0, "support for the show comes from acme"),
        ]
        self.assertEqual(wp.consecutive_preroll_start(ads, llm, segments, 1), 25.01)
        self.assertEqual(llm.requests, [])


class CommercialEvidenceRecoveryTests(unittest.TestCase):
    def analyze(self, segments, *, ad_ids, programme_ids):
        llm = FakeLLM(commercial_ad_ids=ad_ids, commercial_programme_ids=programme_ids)
        llm.load()
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend: []
        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(ads, llm, segments, 500.0)
        return analysis, llm

    def test_adjacent_cta_and_destination_recover_an_unanchored_read(self):
        segments = [
            FakeSegment(0.0, 10.0, "the programme discusses its topic"),
            FakeSegment(10.0, 20.0, "visit acme dot com for the offer"),
            FakeSegment(20.0, 30.0, "get started today with acme"),
            FakeSegment(30.0, 40.0, "the programme interview resumes"),
        ]
        analysis, _llm = self.analyze(segments, ad_ids=[1, 2], programme_ids=[0, 3])
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(10.0, 30.0, "sponsor_read")],
        )

    def test_destination_split_across_cues_still_nominates_the_exact_window(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit acme dot"),
            FakeSegment(20.0, 30.0, "com for thirty percent off"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        self.assertEqual(wp.commercial_evidence_seed_ids(segments, []), ((1, 2),))

    def test_call_to_action_split_across_cues_still_nominates_the_exact_window(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "acme dot com can help you get"),
            FakeSegment(20.0, 30.0, "started today"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        self.assertEqual(wp.commercial_evidence_seed_ids(segments, []), ((1, 2),))

    def test_complete_oversized_cue_is_rejected_instead_of_truncated_for_review(self):
        interior = "the guest explains the editorial result"
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(
                10.0,
                20.0,
                "visit acme dot com " + ("offer " * 1100) + interior
                + ("details " * 900) + " get started today",
            ),
            FakeSegment(20.0, 30.0, "programme after"),
        ]
        analysis, llm = self.analyze(segments, ad_ids=[1], programme_ids=[0, 2])
        self.assertEqual(analysis.detections, ())
        self.assertFalse(
            any(request.get("schema", {}).get("properties", {}).get("ad_ids")
                for request in llm.requests)
        )

    def test_long_host_read_is_not_lost_to_the_context_id_bound(self):
        segments = [FakeSegment(0.0, 2.0, "the programme discusses its topic")]
        segments.extend(
            FakeSegment(
                float(segment_id * 2),
                float(segment_id * 2 + 2),
                "visit acme dot com and get started today with the sponsor",
            )
            for segment_id in range(1, 31)
        )
        segments.append(FakeSegment(62.0, 64.0, "the programme interview resumes"))
        analysis, _llm = self.analyze(
            segments,
            ad_ids=list(range(1, 31)),
            programme_ids=[0, 31],
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s, ad.label) for ad in analysis.detections],
            [(2.0, 62.0, "sponsor_read")],
        )

    def test_noncontiguous_or_programme_intersecting_nominations_preserve_audio(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme before"),
            FakeSegment(10.0, 20.0, "visit acme dot com"),
            FakeSegment(20.0, 30.0, "get started today"),
            FakeSegment(30.0, 40.0, "programme after"),
        ]
        noncontiguous, _ = self.analyze(segments, ad_ids=[1, 3], programme_ids=[0, 3])
        self.assertEqual(noncontiguous.detections, ())
        intersecting, _ = self.analyze(segments, ad_ids=[1, 2], programme_ids=[0, 2, 3])
        self.assertEqual(intersecting.detections, ())

    def test_missing_programme_context_does_not_reach_commercial_inference(self):
        segments = [
            FakeSegment(0.0, 10.0, "visit acme dot com"),
            FakeSegment(10.0, 20.0, "get started today"),
            FakeSegment(20.0, 30.0, "programme resumes"),
        ]
        analysis, llm = self.analyze(segments, ad_ids=[0, 1], programme_ids=[2])
        self.assertEqual(analysis.detections, ())
        self.assertFalse(any(request.get("schema", {}).get("properties", {}).get("ad_ids") for request in llm.requests))

    def test_overlapping_and_excess_evidence_seeds_are_bounded_before_inference(self):
        segments = [FakeSegment(0.0, 1.0, "programme context")]
        for index in range(1, 18):
            text = "visit acme dot com get started today" if index % 2 else "get started today at acme dot com"
            segments.append(FakeSegment(float(index), float(index + 1), text))
        segments.append(FakeSegment(18.0, 19.0, "programme context"))
        seeds = wp.commercial_evidence_seed_ids(segments, [])
        self.assertLessEqual(len(seeds), wp.COMMERCIAL_RECOVERY_MAX_CANDIDATES)
        self.assertTrue(all(right[-1] < left[0] for left, right in zip(seeds, seeds[1:])))


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
        with redirect_stderr(io.StringIO()), mock.patch.object(wp, "probe_duration", return_value=300.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        self.assertEqual(
            spans,
            [{"startSeconds": 212.25, "endSeconds": 248.75, "label": "sponsor", "confidence": 0.97}],
        )
        self.assertEqual(llm.requests, [ads._AD_DETECT_RESPONSE_FORMAT, {"type": "json_object"}])

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

    def test_the_single_aligned_stt_pass_finishes_before_eviction_and_ad_model_load(self):
        events = []
        transcribe = sys.modules["wilted.transcribe"]
        install_fake_speech_stack(events=events)

        def transcribe_audio(path, model_name="mlx-community/parakeet-tdt-1.1b", **_):
            self.assertEqual(model_name, "mlx-community/parakeet-tdt-1.1b")
            return events.append("aligned") or [FakeSegment(0, 1, "content")]

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
                "llmModel": str(self.default_model),
            })
        self.assertEqual(
            events,
            [
                "aligned",
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
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(wp, "probe_duration", return_value=200.0):
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
                mock.patch.object(wp, "GPU_LOCK_ACQUISITION_TIMEOUT_S", 10.0), \
                mock.patch.object(wp.time, "monotonic", side_effect=clock), \
                mock.patch.object(wp.time, "sleep"), redirect_stderr(stream), \
                self.assertRaises(wp.WorkerError) as raised:
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
                self.fail("contended lock must not yield")
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("timed out waiting for exclusive GPU model admission", str(raised.exception))
        waits = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertGreaterEqual(sum("shared GPU inference lock" in event["detail"] for event in waits), 2)

    def test_a_peer_holding_the_lock_past_the_eviction_budget_still_admits(self):
        # One ten-second budget used to cover both the wait for the lock and
        # every daemon call after it, so a peer that held the GPU for longer
        # than that made admission impossible rather than merely slow. Three
        # episodes downloaded together lost two preparations to exactly that.
        rpc_timeouts = []
        install_fake_speech_stack(
            statuses=({"resident_models": 0, "in_flight": 1},), rpc_timeouts=rpc_timeouts
        )
        contended = BlockingIOError()
        contended.errno = wp.errno.EAGAIN
        attempts = []

        def flock(_fd, _flags):
            attempts.append(True)
            if len(attempts) <= 40:
                raise contended

        tick = [0.0]

        def clock():
            current = tick[0]
            tick[0] += 1.0
            return current

        events = []
        with mock.patch.object(wp.fcntl, "flock", side_effect=flock), \
                mock.patch.object(wp.time, "monotonic", side_effect=clock), \
                mock.patch.object(wp.time, "sleep"), redirect_stderr(io.StringIO()):
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
                events.append("ads.work")
        self.assertEqual(events, ["ads.work"])
        self.assertGreater(tick[0], wp.STT_EVICTION_BARRIER_TIMEOUT_S)
        # The barrier budget starts when the lock is first held, so the status
        # call that follows a long wait is not already out of time.
        self.assertGreater(rpc_timeouts[0][1], wp.STT_EVICTION_BARRIER_TIMEOUT_S / 2)

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
        with mock.patch.object(wp.fcntl, "flock", side_effect=fake_flock), redirect_stderr(io.StringIO()), \
                mock.patch.object(wp, "probe_duration", return_value=200.0):
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
                    with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError), \
                            mock.patch.object(wp, "probe_duration", return_value=200.0):
                        wp.detect_and_cut(
                            {"audioPath": str(self.audio)},
                            self.audio,
                            [],
                            [FakeSegment(0, 1, "content")],
                            model_lock=recording_model_lock(events),
                        )
                else:
                    with redirect_stderr(io.StringIO()), \
                            mock.patch.object(wp, "probe_duration", return_value=200.0):
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

    def test_best_available_uses_published_then_stt_then_prose(self):
        published = {"body": "WEBVTT", "mediaType": "text/vtt", "url": "https://x.test/a.vtt"}
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published words")]})
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False,
                "transcriptPolicy": "bestAvailable", "publishedTranscript": published,
                "episodePage": "<article>" + "prose words " * 80 + "</article>",
            })
        self.assertEqual(result["timing"], "published")
        self.assertEqual(result["text"], "published words")

        install_fake_wilted({"vtt": []}, transcriptions={
            wp.ALIGNED_STT_MODEL: [FakeSegment(0, 1, "aligned words")]
        })
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False, "readableTranscript": False,
                "transcriptPolicy": "bestAvailable", "publishedTranscript": published,
                "episodePage": "<article>" + "prose words " * 80 + "</article>",
            })
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["text"], "aligned words")

    def test_always_transcribe_ignores_published_and_falls_back_to_prose(self):
        stt_calls = []
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published words")]})
        install_fake_trafilatura(prose_transcript("fallback prose words"))
        sys.modules["wilted.transcribe"].transcribe_audio = (
            lambda path, **kwargs: stt_calls.append((path, kwargs)) or (_ for _ in ()).throw(RuntimeError("stt failed"))
        )
        with redirect_stderr(io.StringIO()) as stream:
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False,
                "transcriptPolicy": "alwaysTranscribe",
                "publishedTranscript": {"body": "WEBVTT", "mediaType": "text/vtt", "url": "https://x.test/a.vtt"},
                "episodePage": "<article>fallback prose words</article>",
            })
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertEqual(len(stt_calls), 1)
        self.assertNotIn("transcript.published.parse", stages)
        self.assertEqual(result["timing"], "none")
        self.assertIn("fallback prose words", result["text"])

    def test_no_local_stt_never_transcribes_and_uses_published_then_prose(self):
        install_fake_wilted({"vtt": []})
        install_fake_trafilatura(prose_transcript("page prose words"))
        transcribe = mock.Mock(side_effect=AssertionError("noLocalSTT started transcription"))
        sys.modules["wilted.transcribe"].transcribe_audio = transcribe
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False,
                "transcriptPolicy": "noLocalSTT", "allowSpeechToText": True,
                "publishedTranscript": {"body": "WEBVTT", "mediaType": "text/vtt", "url": "https://x.test/a.vtt"},
                "episodePage": "<article>page prose words</article>",
            })
        transcribe.assert_not_called()
        self.assertEqual(result["timing"], "none")
        self.assertIn("page prose words", result["text"])

    PUBLISHED = {"body": "WEBVTT", "mediaType": "text/vtt", "url": "https://x.test/a.vtt"}

    def test_a_published_transcript_that_matches_its_audio_is_kept_and_measured(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published"), FakeSegment(3590, 3595, "words")]})
        with redirect_stderr(io.StringIO()) as stream, mock.patch.object(
            wp, "probe_duration", return_value=3600.0
        ):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False,
                             "allowSpeechToText": False, "publishedTranscript": self.PUBLISHED})
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        aligned = next(r for r in records if r["stage"] == "transcript.published.aligned")
        self.assertEqual(result["timing"], "published")
        # The measurement is recorded on the way past, not only on rejection:
        # one accepted episode says nothing about where the threshold belongs,
        # so every preparation leaves behind the evidence to revisit it.
        self.assertIn("gap 5.0s", aligned["detail"])
        self.assertIn("tolerance 45.0s", aligned["detail"])

    def test_a_published_transcript_far_shorter_than_its_audio_is_replaced_by_transcription(self):
        # The failure this exists for: a host that inserts advertising at
        # request time serves a longer file than the one the publisher
        # transcribed. Every timestamp after the insertion is then wrong, and
        # the ad cut aims at conversation instead of at the advertisement.
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published"), FakeSegment(3590, 3595, "words")]},
                            transcriptions={wp.ALIGNED_STT_MODEL: [FakeSegment(0, 1, "aligned words")]})
        with redirect_stderr(io.StringIO()) as stream, mock.patch.object(
            wp, "probe_duration", return_value=3700.0
        ):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False,
                             "readableTranscript": False, "publishedTranscript": self.PUBLISHED})
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        stages = [r["stage"] for r in records]
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["text"], "aligned words")
        self.assertNotIn("transcript.published.accepted", stages)
        misaligned = next(r for r in records if r["stage"] == "transcript.published.misaligned")
        self.assertIn("audio 3700.0s", misaligned["detail"])
        self.assertIn("transcript ends 3595.0s", misaligned["detail"])

    def test_the_tolerance_scales_with_the_length_of_the_episode(self):
        # Three hours at half a percent is 54 seconds, which is more than the
        # 45-second floor: a long show is allowed a proportionally longer tail
        # of untranscribed music before its transcript is doubted.
        for transcript_end, expected in ((10_750.0, "published"), (10_730.0, "aligned")):
            with self.subTest(transcript_end=transcript_end):
                install_fake_wilted(
                    {"vtt": [FakeSegment(transcript_end - 5, transcript_end, "words")]},
                    transcriptions={wp.ALIGNED_STT_MODEL: [FakeSegment(0, 1, "aligned words")]},
                )
                with redirect_stderr(io.StringIO()), mock.patch.object(
                    wp, "probe_duration", return_value=10_800.0
                ):
                    result = wp.run({"audioPath": str(self.audio), "removeAds": False,
                                     "readableTranscript": False, "publishedTranscript": self.PUBLISHED})
                self.assertEqual(result["timing"], expected)

    def test_a_transcript_whose_audio_cannot_be_probed_is_still_used(self):
        # The guard is a check on the transcript, not a gate on the episode.
        # Losing a good transcript because ffprobe was unavailable trades a
        # possible misalignment for a certain loss.
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published words")]})
        with redirect_stderr(io.StringIO()) as stream, mock.patch.object(
            wp, "probe_duration", side_effect=OSError("ffprobe missing")
        ):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False,
                             "allowSpeechToText": False, "publishedTranscript": self.PUBLISHED})
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertEqual(result["timing"], "published")
        self.assertIn("transcript.published.unverified", stages)

    def test_a_misaligned_transcript_never_reaches_the_ad_detector(self):
        # Cutting from a transcript that describes a different rendering is
        # the destructive half of this defect: with no transcription allowed
        # the episode keeps its audio rather than losing conversation to it.
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published"), FakeSegment(3590, 3595, "words")]})
        detect = mock.patch.object(wp, "detect_and_cut", side_effect=AssertionError("a misaligned transcript drove the cut"))
        with detect as detector, redirect_stderr(io.StringIO()), mock.patch.object(
            wp, "preflight_ad_removal"
        ), mock.patch.object(wp, "probe_duration", return_value=3700.0):
            result = wp.run({"audioPath": str(self.audio), "removeAds": True,
                             "transcriptPolicy": "noLocalSTT", "publishedTranscript": self.PUBLISHED})
        detector.assert_not_called()
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["timing"], "none")

    def test_untimed_prose_never_drives_ad_removal(self):
        install_fake_wilted()
        install_fake_trafilatura(prose_transcript("untimed prose words"))
        detect = mock.patch.object(wp, "detect_and_cut", side_effect=AssertionError("prose drove ad removal"))
        with detect as detector, redirect_stderr(io.StringIO()), mock.patch.object(
            wp, "preflight_ad_removal"
        ):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": True,
                "transcriptPolicy": "noLocalSTT",
                "episodePage": "<article>untimed prose words</article>",
            })
        detector.assert_not_called()
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["timing"], "none")

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

    def test_the_aligned_pass_is_both_detector_and_delivered_transcript_input(self):
        aligned = [FakeSegment(0, 2, "hello there world"), FakeSegment(2, 4, "leo laporte here")]
        calls = []
        install_fake_wilted(transcriptions={"mlx-community/parakeet-tdt-1.1b": aligned})
        transcribe = sys.modules["wilted.transcribe"]
        original = transcribe.transcribe_audio

        def recording_transcribe(*args, **kwargs):
            calls.append(kwargs["model_name"])
            return original(*args, **kwargs)

        with redirect_stderr(io.StringIO()) as err:
            with mock.patch.object(transcribe, "transcribe_audio", recording_transcribe):
                result = wp.run({
                    "audioPath": str(self.audio), "removeAds": False,
                    "readableTranscript": True, "readableTranscriptModel": "ignored-model",
                })
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["text"], "hello there world leo laporte here")
        self.assertEqual(calls, ["mlx-community/parakeet-tdt-1.1b"])
        stages = [json.loads(line)["stage"] for line in err.getvalue().splitlines()]
        self.assertFalse(any(stage.startswith("transcript.stt.readable") for stage in stages))

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


class OutcomeContractTests(unittest.TestCase):
    """Protocol-v2 removal is aligned-only and reports its effective outcome."""

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")

    def test_v2_removal_rejects_no_local_stt_before_any_model_work(self):
        transcribe = mock.Mock(side_effect=AssertionError("STT must not start"))
        install_fake_wilted()
        sys.modules["wilted.transcribe"].transcribe_audio = transcribe
        with mock.patch.object(wp, "preflight_ad_removal") as preflight, self.assertRaises(wp.WorkerError) as raised:
            wp.run({"protocolVersion": 2, "audioPath": str(self.audio), "outputPath": "/tmp/cut.mp3",
                    "removeAds": True, "transcriptPolicy": "noLocalSTT"})
        self.assertEqual(raised.exception.code, "aligned-stt-required")
        preflight.assert_not_called()
        transcribe.assert_not_called()

    def test_v2_removal_rejects_an_output_path_that_aliases_input(self):
        with self.assertRaises(wp.WorkerError) as raised:
            wp.run({"protocolVersion": 2, "audioPath": str(self.audio), "outputPath": str(self.audio),
                    "removeAds": True, "transcriptPolicy": "bestAvailable"})
        self.assertEqual(raised.exception.code, "cut-output-alias")

    def test_v2_no_ads_uses_the_required_aligned_pass_and_emits_a_report(self):
        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: [FakeSegment(0, 1, "programme")]})
        install_fake_ads(FakeLLM())
        with mock.patch.object(wp, "preflight_ad_removal"), \
                mock.patch.object(wp, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(wp, "probe_duration", return_value=10.0), redirect_stderr(io.StringIO()):
            result = wp.run({"protocolVersion": 2, "audioPath": str(self.audio), "outputPath": "/tmp/cut.mp3",
                             "removeAds": True, "alignedTranscriptModel": wp.ALIGNED_STT_MODEL})
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["report"]["outcome"], "noAds")
        self.assertEqual(result["report"]["rawNominations"], [])
        # "Examined every window and found nothing" has to be distinguishable
        # from "never reached the model", and only the audit does that.
        audit = result["report"]["audit"]
        self.assertGreater(audit["modelRequests"], 0)
        self.assertEqual(audit["unresolvedIds"], [])
        self.assertEqual(audit["experimentalRequests"], 0)
        self.assertIsNone(audit["incompleteError"])

    def test_aligned_timing_allows_only_the_declared_short_tail(self):
        accepted = wp.validate_aligned_segments([FakeSegment(0, 12.5, "cached")], 10.0)
        self.assertEqual(len(accepted), 1)
        with self.assertRaises(wp.WorkerError) as raised:
            wp.validate_aligned_segments([FakeSegment(0, 13.1, "drift")], 10.0)
        self.assertEqual(raised.exception.code, "aligned-timing-invalid")

    def test_effective_removed_intervals_are_the_exact_keep_complement(self):
        keeps = wp.build_keep_map([(0, 3), (4, 4.2), (7, 10)])
        self.assertEqual(wp.effective_removed_intervals(keeps, 10), [(3, 4), (4.2, 7)])

    def test_aligned_timing_rejects_segments_that_are_not_in_time_order(self):
        # The check used to sort its input first, which made it unable to fail.
        with self.assertRaises(wp.WorkerError) as raised:
            wp.validate_aligned_segments([FakeSegment(5, 6, "later"), FakeSegment(0, 1, "earlier")], 10.0)
        self.assertEqual(raised.exception.code, "aligned-timing-invalid")
        with self.assertRaises(wp.WorkerError) as beyond:
            wp.validate_aligned_segments([FakeSegment(10.5, 11.0, "past the end")], 10.0)
        self.assertEqual(beyond.exception.code, "aligned-timing-invalid")

    def test_cut_map_preserves_a_short_interstitial_between_two_advertisements(self):
        # The archive helper pads each nomination by half a second and merges
        # across the second between them, taking the interstitial with them.
        merged, keeps = wp.build_effective_cut_map(
            [FakeSegment(10, 20, "ad"), FakeSegment(21, 30, "ad")], 60.0
        )
        self.assertEqual(merged, [(10, 20), (21, 30)])
        self.assertEqual([(k.start_s, k.end_s) for k in keeps], [(0, 10), (20, 21), (30, 60)])
        self.assertEqual([k.output_start_s for k in keeps], [0, 10, 11])

    def test_cut_map_unions_overlapping_nominations_without_padding_them(self):
        merged, keeps = wp.build_effective_cut_map(
            [FakeSegment(15, 25, "ad"), FakeSegment(10, 20, "ad")], 60.0
        )
        self.assertEqual(merged, [(10, 25)])
        self.assertEqual([(k.start_s, k.end_s) for k in keeps], [(0, 10), (25, 60)])

    def test_cut_map_clamps_the_declared_tail_and_refuses_anything_past_it(self):
        _, keeps = wp.build_effective_cut_map([FakeSegment(50, 61, "closing ad")], 60.0)
        self.assertEqual([(k.start_s, k.end_s) for k in keeps], [(0, 50)])
        for detection, reason in ((FakeSegment(55, 70, "way past"), "outside"),
                                  (FakeSegment(61, 62, "starts past the end"), "outside"),
                                  (FakeSegment(9, 9, "empty"), "invalid")):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.build_effective_cut_map([detection], 60.0)
            self.assertEqual(raised.exception.code, "cut-unsafe", reason)

    def test_serialized_ad_segments_are_the_complement_of_the_serialized_keeps(self):
        _, keeps = wp.build_effective_cut_map(
            [FakeSegment(10, 20, "ad"), FakeSegment(21, 30, "ad")], 60.0
        )
        serialized = wp.serialize_keep_map(keeps)
        removed = [(round(a, 3), round(b, 3)) for a, b in wp.effective_removed_intervals(keeps, 60.0)]
        boundaries = []
        cursor = 0.0
        for keep in serialized:
            if keep["startSeconds"] > cursor:
                boundaries.append((cursor, keep["startSeconds"]))
            cursor = keep["endSeconds"]
        if cursor < 60.0:
            boundaries.append((cursor, 60.0))
        self.assertEqual(removed, boundaries)

    def test_a_wedged_render_reports_progress_and_then_fails_on_its_bound(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(wp.WorkerError) as raised:
            wp._run_render_with_progress(["sleep", "30"], timeout_s=0.4)
        self.assertEqual(raised.exception.code, "cut-render-timeout")
        self.assertIn("ads.cut.render.progress", stderr.getvalue())

    def test_a_failing_render_reports_the_encoder_stderr(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised:
            wp._run_render_with_progress(
                ["sh", "-c", "echo 'no such filter' >&2; exit 3"], timeout_s=10.0
            )
        self.assertEqual(raised.exception.code, "cut-render-failed")
        self.assertIn("no such filter", str(raised.exception))

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
    def test_accurate_render_matches_the_declared_keep_map_for_mp3_and_aac(self):
        scratch = REPO_ROOT / ".verify-tmp" / f"render-{os.getpid()}"
        scratch.mkdir(parents=True, exist_ok=True)
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        keeps = wp.build_keep_map([(0.0, 3.0), (7.5, 12.0)])
        for suffix in (".mp3", ".m4a"):
            source = scratch / f"source{suffix}"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                 "-i", "sine=frequency=440:duration=12", str(source)],
                check=True, capture_output=True,
            )
            output = scratch / f"cut{suffix}"
            with redirect_stderr(io.StringIO()):
                wp.render_keep_segments(source, output, keeps)
            measured = wp.probe_duration(output)
            self.assertAlmostEqual(measured, 7.5, delta=wp.RENDER_DURATION_TOLERANCE_S,
                                   msg=f"{suffix} rendered {measured:.3f}s")
            self.assertGreater(output.stat().st_size, 0)


class AlignedSTTCacheTests(unittest.TestCase):
    """The detector transcript is reusable only for its exact model and bytes."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wilted-aligned-cache-")
        self.addCleanup(self.temporary.cleanup)
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.request = {
            "audioPath": str(self.audio), "workDir": self.temporary.name,
            "removeAds": False, "readableTranscript": False,
            "sourceHash": "sha256:source-one", "alignedTranscriptModel": "detector-v1",
        }

    def cache_path(self, request=None):
        request = request or self.request
        return wp._aligned_cache_path(  # noqa: SLF001 - exercises cache identity directly
            wp._aligned_cache_directory(request), request["sourceHash"], request["alignedTranscriptModel"]
        )

    def run_pipeline(self, request=None):
        with mock.patch.object(wp, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            return wp.run(request or self.request)

    def test_reuses_a_detector_compatible_transcript_with_the_explicit_model(self):
        calls = []
        install_fake_wilted()
        transcribe = sys.modules["wilted.transcribe"]

        def transcribe_audio(_path, model_name, **_):
            calls.append(model_name)
            return [FakeSegment(0, 1, "detector words")]

        transcribe.transcribe_audio = transcribe_audio
        self.run_pipeline()
        self.assertEqual(calls, ["detector-v1"])
        cached = json.loads(self.cache_path().read_text())
        self.assertEqual(cached["model"], "detector-v1")
        self.assertEqual(cached["sourceHash"], "sha256:source-one")

        # A new daemon double has no valid answer. A cache hit must therefore
        # be what makes this retry succeed, and it must rebuild `.text`,
        # `.start_s`, and `.end_s` for the detector rather than return JSON.
        install_fake_wilted()
        install_fake_ads(FakeLLM())
        with mock.patch.object(wp, "detect_and_cut") as detector:
            self.request["removeAds"] = True
            with mock.patch.object(wp, "preflight_ad_removal"), \
                    mock.patch.object(wp, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()):
                # The detector is not reached because this stub prevents the
                # production cut path; its input is still observable below.
                detector.return_value = (self.audio, [], [])
                self.run_pipeline()
        segment = detector.call_args.args[3][0]
        self.assertEqual((segment.text, segment.start_s, segment.end_s), ("detector words", 0.0, 1.0))

    def test_changed_hash_or_model_forces_fresh_stt(self):
        calls = []
        install_fake_wilted()
        transcribe = sys.modules["wilted.transcribe"]
        transcribe.transcribe_audio = lambda _path, model_name, **_: calls.append(model_name) or [FakeSegment(0, 1, model_name)]
        self.run_pipeline()

        changed_model = {**self.request, "alignedTranscriptModel": "detector-v2"}
        self.run_pipeline(changed_model)
        changed_hash = {**self.request, "sourceHash": "sha256:source-two"}
        self.run_pipeline(changed_hash)
        self.assertEqual(calls, ["detector-v1", "detector-v2", "detector-v1"])

    def test_cache_preserves_ordered_overlapping_and_empty_detector_results(self):
        overlapping = [FakeSegment(0, 2, "speaker one"), FakeSegment(1.5, 3, "speaker two")]
        wp._store_cached_aligned_segments(  # noqa: SLF001 - validates detector cache fidelity
            self.request, self.request["sourceHash"], self.request["alignedTranscriptModel"], overlapping
        )
        loaded = wp._load_cached_aligned_segments(  # noqa: SLF001
            self.request, self.request["sourceHash"], self.request["alignedTranscriptModel"]
        )
        self.assertEqual([(item.start_s, item.end_s) for item in loaded], [(0.0, 2.0), (1.5, 3.0)])

        empty_request = {**self.request, "sourceHash": "sha256:empty"}
        wp._store_cached_aligned_segments(  # noqa: SLF001
            empty_request, empty_request["sourceHash"], empty_request["alignedTranscriptModel"], []
        )
        self.assertEqual(wp._load_cached_aligned_segments(  # noqa: SLF001
            empty_request, empty_request["sourceHash"], empty_request["alignedTranscriptModel"]
        ), [])

    def test_malformed_mismatched_and_invalid_entries_are_deleted_before_fresh_stt(self):
        cases = {
            "malformed": "{not json",
            "mismatched": json.dumps({"schemaVersion": 1, "sourceHash": "sha256:other", "model": "detector-v1", "segments": []}),
            "invalid-cue": json.dumps({"schemaVersion": 1, "sourceHash": "sha256:source-one", "model": "detector-v1",
                                        "segments": [{"text": "", "start_s": 1, "end_s": 1}]}),
        }
        for name, body in cases.items():
            with self.subTest(name=name):
                calls = []
                install_fake_wilted()
                sys.modules["wilted.transcribe"].transcribe_audio = (
                    lambda _path, model_name, **_: calls.append(model_name) or [FakeSegment(0, 1, "fresh")]
                )
                path = self.cache_path()
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(body)
                self.run_pipeline()
                self.assertEqual(calls, ["detector-v1"])
                self.assertEqual(json.loads(path.read_text())["segments"][0]["text"], "fresh")

    def test_hit_refreshes_recency_and_pruning_keeps_only_valid_recent_entries(self):
        directory = wp._aligned_cache_directory(self.request)
        segment = [FakeSegment(0, 1, "cached")]
        requests = []
        for index in range(wp.ALIGNED_STT_CACHE_MAXIMUM_ENTRIES):
            request = {**self.request, "sourceHash": f"sha256:{index}"}
            requests.append(request)
            wp._store_cached_aligned_segments(request, request["sourceHash"], request["alignedTranscriptModel"], segment)
            os.utime(self.cache_path(request), (index + 1, index + 1))
        # Make the original least-recent entry a hit before adding one more.
        self.assertIsNotNone(wp._load_cached_aligned_segments(requests[0], "sha256:0", "detector-v1"))
        (directory / ".interrupted.tmp").write_text("partial")
        (directory / "corrupt.json").write_text("not json")
        newest = {**self.request, "sourceHash": "sha256:new"}
        wp._store_cached_aligned_segments(newest, newest["sourceHash"], newest["alignedTranscriptModel"], segment)

        files = list(directory.iterdir())
        self.assertFalse((directory / ".interrupted.tmp").exists())
        self.assertFalse((directory / "corrupt.json").exists())
        valid = [path for path in files if path.suffix == ".json"]
        self.assertEqual(len(valid), wp.ALIGNED_STT_CACHE_MAXIMUM_ENTRIES)
        self.assertTrue(self.cache_path(requests[0]).exists(), "a cache hit refreshes LRU recency")

    def test_detector_failure_keeps_the_completed_cache_without_returning_success(self):
        install_fake_wilted()
        wp._store_cached_aligned_segments(
            self.request, self.request["sourceHash"], self.request["alignedTranscriptModel"],
            [FakeSegment(0, 1, "cached")],
        )
        self.request["removeAds"] = True
        install_fake_ads(FakeLLM())
        with mock.patch.object(wp, "preflight_ad_removal"), \
                mock.patch.object(wp, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(wp, "detect_and_cut", side_effect=wp.WorkerError("ads-down", "detector unavailable")), \
                mock.patch.object(wp, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run(self.request)
        self.assertEqual(raised.exception.code, "ads-down")
        self.assertTrue(self.cache_path().exists())

    def test_out_of_order_transcription_is_still_cached(self):
        # Chunked speech-to-text stitches 120-second windows and emits a few
        # segments that start before the one ahead of them. The cache rejected
        # every transcript it was ever offered, so every episode paid for
        # speech-to-text twice and the journal only ever said `cache.failed`.
        install_fake_wilted()
        sys.modules["wilted.transcribe"].transcribe_audio = lambda _path, model_name, **_: [
            FakeSegment(2.0, 3.0, "second"), FakeSegment(0.0, 1.0, "first"),
        ]
        self.run_pipeline()
        cached = json.loads(self.cache_path().read_text())
        self.assertEqual([entry["text"] for entry in cached["segments"]], ["first", "second"])

    def test_published_transcripts_never_create_the_aligned_detector_cache(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "published")]})
        published = {**self.request, "publishedTranscript": {
            "body": "WEBVTT", "mediaType": "text/vtt", "url": "https://example.test/a.vtt",
        }}
        self.run_pipeline(published)
        self.assertFalse(self.cache_path(published).exists())



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


class AdCorpusScoringTests(unittest.TestCase):
    """The scorer that measures the detector against hand-labelled episodes.

    These stay dependency-free like the rest of this suite: the scorer is pure,
    so the tests hand it spans directly rather than reaching for the library
    database or the model.
    """

    def setUp(self):
        self.corpus = load_ad_corpus()

    def case(self, *expected, duration=3600.0):
        return {"id": "case", "show": "Show", "expected": list(expected),
                "audioDurationSeconds": duration}

    def expect(self, label, start, end):
        return {"label": label, "start": start, "end": end, "why": "test"}

    def score(self, case, cuts):
        spans = [self.corpus.Span(start, end) for start, end in cuts]
        return self.corpus.score_case(case, spans)

    def test_removing_programme_content_fails_the_case(self):
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)), [(0.0, 50.0)])
        self.assertFalse(verdict.passed)
        self.assertIn("20.0s of programme", verdict.reason)

    def test_a_boundary_landing_a_hair_inside_the_programme_is_forgiven(self):
        # A cut lands on a transcript segment edge and the truth was read off
        # those same edges, so sub-second slop is rounding, not a defect.
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)), [(0.0, 30.9)])
        self.assertTrue(verdict.passed)

    def test_an_advertisement_left_whole_fails_the_case(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(100.0, 200.0)])
        self.assertFalse(verdict.passed)
        self.assertIn("left 32.0s of advertising", verdict.reason)

    def test_an_advertisement_missing_only_its_last_breath_still_passes(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(0.0, 31.0)])
        self.assertTrue(verdict.passed)

    def test_a_second_missed_at_each_end_is_rounding_and_three_seconds_is_not(self):
        # Both boundaries land on cue edges and both can round, so the slack is
        # per edge. Past it the listener is hearing advertising, which is the
        # thing being measured.
        case = self.case(self.expect("must-cut", 0.0, 32.0))
        self.assertTrue(self.score(case, [(1.0, 31.0)]).passed)
        self.assertFalse(self.score(case, [(1.5, 30.5)]).passed)

    def test_a_label_running_past_the_end_of_the_audio_is_scored_where_it_exists(self):
        # Waveform's closing break is labelled 2.5s beyond the end of its own
        # file: the transcript's last cue outruns the probed duration. Counting
        # seconds the file does not contain as advertising left playing would
        # measure the transcript rather than the cut.
        case = self.case(self.expect("must-cut", 90.0, 105.0), duration=100.0)
        self.assertTrue(self.score(case, [(90.0, 100.0)]).passed)

    def test_an_advertisement_barely_clipped_does_not_count_as_removed(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(0.0, 8.0)])
        self.assertFalse(verdict.passed)

    def test_an_acceptable_cut_passes_whether_it_is_taken_or_left(self):
        expected = self.expect("acceptable-cut", 0.0, 26.0)
        self.assertTrue(self.score(self.case(expected), [(0.0, 26.0)]).passed)
        self.assertTrue(self.score(self.case(expected), []).passed)

    def test_an_unknown_label_is_refused_rather_than_silently_passed(self):
        with self.assertRaises(ValueError):
            self.score(self.case(self.expect("probably-fine", 0.0, 10.0)), [])

    def test_overlapping_cuts_score_exactly_as_their_union_does(self):
        # The detector nominates a span and a recovery pass widens it; two
        # cuts covering one advertisement is the normal shape of a result.
        # Summing them reported a ten-second spot as sixteen seconds removed.
        case = self.case(
            self.expect("must-cut", 0.0, 10.0),
            self.expect("must-keep", 10.0, 600.0),
        )
        overlapping = self.score(case, [(0.0, 6.0), (3.0, 10.0), (3.0, 10.0), (12.0, 20.0)])
        union = self.score(case, [(0.0, 10.0), (12.0, 20.0)])
        self.assertEqual([span.overlap_seconds for span in overlapping.spans],
                         [span.overlap_seconds for span in union.spans])
        self.assertEqual(overlapping.keep_loss_seconds, union.keep_loss_seconds)
        self.assertEqual(overlapping.unknown_cut_seconds, union.unknown_cut_seconds)
        self.assertEqual(overlapping.passed, union.passed)

    def test_duplicate_cuts_cannot_report_more_of_a_spot_than_there_is(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 10.0)),
                             [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)])
        self.assertEqual(verdict.spans[0].overlap_seconds, 10.0)
        self.assertIn("100%", verdict.spans[0].note)

    def test_duplicate_cuts_cannot_hide_programme_loss_either(self):
        # The same arithmetic in the direction that matters more: without the
        # union this reports sixty seconds lost from a thirty-second span,
        # which is a number the episode cannot produce.
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)),
                             [(30.0, 60.0), (30.0, 60.0)])
        self.assertEqual(verdict.keep_loss_seconds, 30.0)

    def test_a_second_lost_from_every_break_fails_even_though_each_is_forgiven(self):
        # Per-span tolerance is for rounding and forgives it once. Ten spans
        # each losing nine tenths of a second is a sentence gone from every
        # break in the episode, and every one of them passes on its own.
        expected = [self.expect("must-keep", 100.0 * n, 100.0 * n + 50.0) for n in range(1, 11)]
        cuts = [(100.0 * n, 100.0 * n + 0.9) for n in range(1, 11)]
        verdict = self.score(self.case(*expected), cuts)
        self.assertTrue(all(span.passed for span in verdict.spans))
        self.assertFalse(verdict.passed)
        self.assertIn("9.0s of programme across the episode", verdict.reason)

    def test_an_episode_losing_less_than_the_budget_still_passes(self):
        expected = [self.expect("must-keep", 100.0 * n, 100.0 * n + 50.0) for n in range(1, 4)]
        cuts = [(100.0 * n, 100.0 * n + 0.9) for n in range(1, 4)]
        self.assertTrue(self.score(self.case(*expected), cuts).passed)

    def test_an_interval_the_arithmetic_cannot_read_is_named_not_absorbed(self):
        case = self.case(self.expect("must-cut", 0.0, 10.0))
        for cuts, expected in (
            ([(0.0, 10.0), (50.0, 40.0)], "ends at or before it starts"),
            ([(-5.0, 10.0)], "starts before the audio does"),
            ([(4000.0, 4100.0)], "starts after the 3600.0s episode ends"),
            ([(0.0, float("inf"))], "end is not a finite number"),
            ([(float("nan"), 10.0)], "start is not a finite number"),
        ):
            verdict = self.score(case, cuts)
            self.assertFalse(verdict.passed, cuts)
            self.assertIn(expected, verdict.reason)
            # Nothing is scored around it: a malformed cut makes every number
            # after it meaningless, and a clean report off one is the failure.
            self.assertEqual(verdict.spans, [])

    def test_a_cut_ending_past_the_probed_duration_is_still_a_cut(self):
        # The closing review cuts to the end of the file, and the probe and the
        # transcript disagree by a couple of seconds on a real episode. That
        # overhang is normal, not a malformed interval.
        verdict = self.score(self.case(self.expect("must-cut", 3550.0, 3605.0)), [(3550.0, 3605.0)])
        self.assertTrue(verdict.passed)
        self.assertEqual(verdict.unknown_cut_seconds, 0.0)

    def test_cutting_where_nothing_is_labelled_is_reported_rather_than_scored(self):
        case = self.case(self.expect("must-cut", 0.0, 10.0), duration=1000.0)
        verdict = self.score(case, [(0.0, 10.0), (500.0, 560.0)])
        # It passes -- the labels say nothing about 500-560s and the harness
        # will not invent a verdict -- but it says how much went unmeasured.
        self.assertTrue(verdict.passed)
        self.assertEqual(verdict.unknown_cut_seconds, 60.0)
        self.assertAlmostEqual(verdict.labelled_coverage, 0.01)
        self.assertFalse(verdict.coverage_complete)

    def test_a_case_whose_labels_reach_every_cut_is_complete(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 10.0), duration=1000.0),
                             [(0.0, 10.0)])
        self.assertTrue(verdict.coverage_complete)
        self.assertEqual(verdict.unknown_cut_seconds, 0.0)


class AdCorpusManifestTests(unittest.TestCase):
    """The ground truth itself, and what it currently says about the detector."""

    def setUp(self):
        self.corpus = load_ad_corpus()
        self.manifest = self.corpus.load_manifest()

    def find(self, case_id):
        for case in self.manifest["cases"]:
            if case["id"] == case_id:
                return case
        self.fail(f"{case_id} is no longer in the corpus")

    def frozen(self, case):
        return [
            self.corpus.Span(entry["start"], entry["end"]) for entry in case["recorded"]
        ]

    def test_every_labelled_span_is_well_formed_and_inside_its_episode(self):
        for case in self.manifest["cases"]:
            # The labels are read off transcript cue boundaries, and the size
            # guards divide by the audio duration, so the manifest carries both
            # and neither may go missing. The bound is asymmetric because the
            # two numbers drift apart for different reasons. A cue end can
            # round a second or two past the end of the file, so the transcript
            # is allowed barely any headroom over the audio. Audio past the
            # last cue is untranscribed lead-out -- Practical AI closes on five
            # seconds of music the model emits no cue for -- and that can be
            # long without meaning anything is wrong. Both bounds are far below
            # the minutes that separate two different episodes, which is the
            # mistake this is here to catch.
            transcript = case["transcriptEndSeconds"]
            audio = case["audioDurationSeconds"]
            self.assertLessEqual(
                transcript, audio + 5.0,
                f"{case['id']}: the transcript runs past the end of the audio",
            )
            self.assertLessEqual(
                audio - transcript, 60.0,
                f"{case['id']}: the transcript and the audio disagree about the episode length",
            )
            for expected in case["expected"]:
                self.assertIn(expected["label"], self.manifest["labels"], case["id"])
                self.assertLess(expected["start"], expected["end"], case["id"])
                # A label may reach the end of the audio even where no cue
                # does, which is how the untranscribed lead-out gets labelled
                # at all; it may not reach past both.
                self.assertLessEqual(
                    expected["end"], max(transcript, audio) + 1.0, case["id"]
                )
                self.assertTrue(expected["why"].strip(), case["id"])

    def test_waveform_still_leaves_all_three_reported_advertisements_whole(self):
        # A characterisation test, not an aspiration: it records the defect as
        # measured on 2026-09-05 so that fixing the detector breaks this test
        # loudly and forces the record to be updated with the new truth.
        case = self.find("waveform-two-preroll-sponsor-reads")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the leading-edge miss appears to be fixed; update this test")
        missed = [span for span in verdict.spans if span.label == "must-cut" and not span.passed]
        self.assertEqual(
            [(s.span.start, s.span.end) for s in missed],
            # 4122.76-4162.76 is the Amazon Prime spot, labelled on 2026-09-07
            # after the review named it an evaluation gap. The saved run misses
            # it too; it was simply not being scored before.
            [(0.24, 32.88), (33.52, 66.08), (4066.16, 4122.76), (4122.76, 4162.76)],
        )
        # The three spans it does get right have to survive any fix.
        kept = [span for span in verdict.spans if span.label == "must-cut" and span.passed]
        self.assertEqual(len(kept), 3)

    def test_pop_culture_happy_hour_still_loses_the_episode_premise(self):
        case = self.find("pchh-preroll-swallowed-the-premise")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the overreach appears to be fixed; update this test")
        lost = [span for span in verdict.spans if span.label == "must-keep" and not span.passed]
        self.assertEqual(len(lost), 1)
        self.assertAlmostEqual(lost[0].overlap_seconds, 20.32, places=2)

    def test_practical_ai_still_leaves_both_host_reads_whole(self):
        # The same shape as the Waveform characterisation: it records what the
        # 2026-09-08 run actually did, so a detector fix breaks this loudly.
        # Both misses are host reads that open without a break of any kind,
        # which is the condition this case exists to measure.
        case = self.find("practical-ai-two-host-reads-left-whole")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the host reads appear to be caught; update this test")
        missed = [span for span in verdict.spans if span.label == "must-cut" and not span.passed]
        self.assertEqual(
            [(s.span.start, s.span.end) for s in missed],
            [(1117.52, 1186.92), (1898.84, 1959.36)],
        )
        # Nothing was cut outside the closing credit, so the failure is purely
        # what was left in. If a fix starts losing programme here, the aggregate
        # budget below is what will say so.
        self.assertEqual(verdict.keep_loss_seconds, 0.0)
        self.assertTrue(verdict.coverage_complete, verdict.unknown_cut_seconds)

    def test_every_case_says_who_labelled_it_and_against_which_input(self):
        # A label with no provenance is an assertion, and this corpus is the
        # thing a detector fix is accepted against. Owner and analyst being one
        # person is a real limit of it, so the manifest has to say so rather
        # than leave the reader to assume independence.
        for case in self.manifest["cases"]:
            provenance = case.get("provenance")
            self.assertIsInstance(provenance, dict, case["id"])
            for key in ("labelledBy", "labelledOn", "inputIdentity", "labelSource"):
                self.assertTrue(str(provenance.get(key, "")).strip(), f"{case['id']}: {key}")
            self.assertIn(case["sttModel"], provenance["inputIdentity"], case["id"])

    def test_labelled_spans_within_a_case_never_overlap_each_other(self):
        # The aggregate programme-loss budget adds up per-span losses, so two
        # `must-keep` labels covering the same second would count it twice.
        for case in self.manifest["cases"]:
            spans = sorted((e["start"], e["end"]) for e in case["expected"])
            for (_, first_end), (second_start, _) in zip(spans, spans[1:]):
                self.assertLessEqual(first_end, second_start, case["id"])

    def test_reviewed_incidents_with_no_case_are_inventoried_rather_than_invented(self):
        # Thirteen historical failures were reviewed and two of them have
        # fixtures. The rest are not silently absent: where the input or the
        # label is gone, the manifest records what is missing and what would
        # close it, because a corpus that lists only what it happens to hold
        # reads as a corpus that covers everything.
        gaps = self.manifest.get("gaps")
        self.assertIsInstance(gaps, list)
        self.assertTrue(gaps)
        case_ids = {case["id"] for case in self.manifest["cases"]}
        for gap in gaps:
            for key in ("id", "show", "kind", "reported", "missing", "closes"):
                self.assertTrue(str(gap.get(key, "")).strip(), f"{gap.get('id')}: {key}")
            self.assertNotIn(gap["id"], case_ids)
            # `runtime` and `policy` gaps have no labelled audio that could
            # express them; saying which kind each is stops the inventory
            # reading as a list of unfixed detector defects.
            self.assertIn(gap["kind"], {"judgement", "runtime", "policy"})
        self.assertEqual(len(gaps), len({gap["id"] for gap in gaps}))

    def test_no_gap_claims_an_input_a_case_already_carries(self):
        # A gap whose input is present is not a gap, it is an unwritten case.
        hashes = {case["sourceHash"] for case in self.manifest["cases"]}
        for gap in self.manifest["gaps"]:
            for source_hash in hashes:
                self.assertNotIn(source_hash, gap["missing"], gap["id"])

    def test_the_detector_reports_the_same_confidence_for_every_span_it_finds(self):
        # Both recorded runs come back at 1.0 throughout, including the spans
        # that were wrong in each direction, which is why nothing in the app
        # can currently use confidence to decide anything.
        confidences = {
            entry["confidence"]
            for case in self.manifest["cases"] for entry in case["recorded"]
        }
        self.assertEqual(confidences, {1.0})


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

    def test_a_confirmation_that_finds_program_content_leaves_detections_unchanged(self):
        llm = FakeLLM(preroll_program_start_id=5, preroll_program_id=2)
        result, details = self.preroll(llm, self.segments(), self.existing())
        self.assertEqual([(ad.start_s, ad.end_s, ad.label) for ad in result],
                          [(150.0, 180.0, "sponsor_read")])
        self.assertIn("program content at 2", details["ads.detect.preroll.skipped"])

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

class AuditedDetectorAdapterTests(unittest.TestCase):
    """Exercise retry coverage without loading the archived model or detector."""

    def setUp(self):
        self.segments = [
            FakeSegment(0.0, 10.0, "first segment"),
            FakeSegment(10.0, 20.0, "second segment"),
            FakeSegment(20.0, 30.0, "third segment"),
        ]
        self.patches = [
            mock.patch.object(wp, name, lambda _ads, _backend, _segments, detections, *_args: detections)
            for name in (
                "recover_unclaimed_explicit_sponsor_reads",
                "recover_commercial_evidence_reads",
                "recover_transcript_start_preroll",
                "recover_transcript_end_postroll",
                "resize_oversized_ad_spans",
            )
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def ads(self, detector):
        ads = types.ModuleType("wilted.ads")
        ads._AD_DETECT_SYSTEM_PROMPT = "classify"
        ads._AD_DETECT_CORRECTION_PROMPT = "correct"
        ads._AD_DETECT_RESPONSE_FORMAT = {
            "type": "json_object",
            "schema": {
                "type": "object",
                "properties": {"ads": {"type": "array"}},
                "required": ["ads"],
                "additionalProperties": False,
            },
        }

        def parse_ad_response(response, expected_ids):
            parsed = json.loads(response)
            if not isinstance(parsed, dict) or set(parsed) != {"ads"} or not isinstance(parsed["ads"], list):
                raise ValueError("invalid response")
            positions = {segment_id: index for index, segment_id in enumerate(expected_ids)}
            labels = {}
            for item in parsed["ads"]:
                if (not isinstance(item, list) or len(item) != 2 or isinstance(item[0], bool)
                        or not isinstance(item[0], int) or item[0] not in positions
                        or item[0] in labels or item[1] not in {
                            "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"
                        }):
                    raise ValueError("invalid ad entry")
                labels[item[0]] = item[1]
            if list(labels) != sorted(labels, key=positions.__getitem__):
                raise ValueError("out-of-order response")
            return [(segment_id, segment_id in labels, labels.get(segment_id)) for segment_id in expected_ids]

        ads._parse_ad_response = parse_ad_response
        ads._SPONSOR_OPENING_RE = re.compile("sponsor")
        ads._EXPLICIT_HOST_READ_OPENING_RE = re.compile("sponsor")
        ads._SPARSE_PROMO_CUES = ()
        attach_archive_render_helpers(
            ads,
            lambda index, segment: f"[ID {index}] [{segment.start_s:.2f}s - {segment.end_s:.2f}s] ",
        )
        attach_archive_overlap_resolver(ads)
        ads.detect_ads = detector
        # Kept so a test can ask what the worker installed on the module the
        # detector was actually handed.
        self.last_ads = ads
        return ads

    @staticmethod
    def rendered(ids, *, truncated=False):
        lines = [f"[ID {segment_id}] [{segment_id}.0s - {segment_id + 1}.0s] cue" for segment_id in ids]
        if truncated:
            lines.append(" …[TRUNCATED]… ")
        return "\n".join(lines)

    @staticmethod
    def classifier(backend, ids, *, result=None, truncated=False):
        response, _tokens = backend.generate(
            "classify",
            AuditedDetectorAdapterTests.rendered(ids, truncated=truncated),
            response_format=backend._classification_response_format,
        )
        if result is not None:
            return result(response)
        response, _tokens = backend.generate(
            "correct",
            AuditedDetectorAdapterTests.rendered(ids, truncated=truncated),
            response_format=backend._classification_response_format,
        )
        return response

    def analysis(self, detector, responses, *, auto_cover=True, **kwargs):
        class Backend:
            def __init__(inner):
                inner.responses = iter(responses)
                inner.calls = []

            def generate(inner, prompt, content, *, response_format=None):
                inner.calls.append((prompt, content))
                if prompt == "classify" and content == AuditedDetectorAdapterTests.rendered([0, 1, 2]):
                    return '{"ads":[]}', 1
                return next(inner.responses), 1

        backend = Backend()
        def detector_with_coverage(segments, auditing_backend):
            result = detector(segments, auditing_backend)
            if auto_cover:
                auditing_backend.generate(
                    "classify", self.rendered([0, 1, 2]),
                    response_format=auditing_backend._classification_response_format,
                )
            return result

        return wp.analyze_ad_detections(
            self.ads(detector_with_coverage), backend, self.segments, 100.0, **kwargs
        ), backend

    def test_the_render_budget_is_installed_before_the_classifier_runs(self):
        # An install that runs after `detect_ads` would fix nothing: the
        # classification requests are rendered inside it.
        marked = []

        def detector(_segments, _backend):
            marked.append(
                getattr(
                    self.last_ads._render_segments_bounded, wp._PROPORTIONAL_RENDER_MARKER, False
                )
            )
            return []

        self.analysis(detector, [])
        self.assertEqual(marked, [True])

    def test_overlap_resolver_is_installed_before_the_archive_detector_runs(self):
        observed = []

        def detector(segments, _backend):
            resolver = self.last_ads._resolve_overlaps  # noqa: SLF001
            observed.append(getattr(resolver, wp._CONTEXT_AWARE_OVERLAP_MARKER, False))
            runs = resolver(
                [
                    [(0, False, None), (1, True, "self_promo"), (2, False, None)],
                    [(1, False, None), (2, False, None)],
                ],
                segments,
            )
            observed.append([(run.start_id, run.end_id, run.label) for run in runs])
            return []

        self.analysis(detector, [])
        self.assertEqual(observed, [True, [(1, 1, "self_promo")]])

    def test_exhausted_singleton_is_unresolved_not_a_clean_no_ads_result(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ["not json", "still not json"])
        self.assertEqual(raised.exception.code, "ads-classification-unresolved")

    def test_corrected_and_split_classification_has_resolved_coverage(self):
        def detector(_segments, backend):
            first = self.classifier(backend, [0, 1])
            self.assertEqual(first, "still not json")
            left, _ = backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            right, _ = backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            self.assertEqual(left, '{"ads":[]}')
            self.assertEqual(right, '{"ads":[[1,"sponsor_read"]]}')
            return [FakeAd(10.0, 20.0)]

        analysis, _backend = self.analysis(
            detector,
            ["not json", "still not json", '{"ads":[]}', '{"ads":[[1,"sponsor_read"]]}'],
        )
        self.assertEqual(analysis.audit.unresolved_ids, ())
        self.assertEqual(len(analysis.detections), 1)

    def test_the_recovery_passes_run_in_the_order_the_worker_defines(self):
        # The order is the contract, not an implementation detail: the start
        # and end recoveries nominate spans that the resize pass then bounds,
        # so resizing first would bound spans that do not exist yet. It lives
        # here rather than in the corpus tests because both the live path and
        # the replay reach it only through this entry -- which is the point of
        # there being one entry.
        order = []
        for name in ("recover_unclaimed_explicit_sponsor_reads", "recover_commercial_evidence_reads",
                     "recover_transcript_start_preroll",
                     "recover_transcript_end_postroll", "resize_oversized_ad_spans"):
            def record(*args, _name=name, **_kwargs):
                order.append(_name)
                return args[3]
            patcher = mock.patch.object(wp, name, record)
            patcher.start()
            self.addCleanup(patcher.stop)

        def detector(_segments, backend):
            order.append("detect_ads")
            return []

        self.analysis(detector, [])
        self.assertEqual(order, [
            "detect_ads",
            "recover_unclaimed_explicit_sponsor_reads",
            "recover_commercial_evidence_reads",
            "recover_transcript_start_preroll",
            "recover_transcript_end_postroll",
            "resize_oversized_ad_spans",
        ])

    def test_corrective_response_has_resolved_coverage(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            return []

        analysis, _backend = self.analysis(detector, ["not json", '{"ads":[]}'])
        self.assertEqual(analysis.audit.unresolved_ids, ())

    def test_an_independently_failed_window_remains_unresolved(self):
        def detector(_segments, backend):
            self.classifier(backend, [0])
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ["bad", "bad", '{"ads":[]}'])
        self.assertEqual(raised.exception.code, "ads-classification-unresolved")
        self.assertIn("0", str(raised.exception))

    def test_observed_diagnostics_do_not_claim_archive_filter_state(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([0], truncated=True), response_format=backend._classification_response_format)
            backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            return []

        analysis, _backend = self.analysis(
            detector,
            ['{"ads":[[0,"sponsor_read"]]}', '{"ads":[]}'],
        )
        candidates = {candidate.kind: candidate for candidate in analysis.audit.candidates}
        self.assertEqual(
            set(candidates),
            {"positive-missing-final-span", "request-disagreement", "visible-truncation"},
        )
        self.assertNotIn("sparse", " ".join(candidate.detail for candidate in candidates.values()).lower())

    def test_adaptation_is_disabled_by_default_and_budgeted_when_explicit(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        analysis, backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])
        self.assertEqual(len(backend.calls), 2)
        self.assertEqual(analysis.audit.speculative_cuts, ())
        candidate = analysis.audit.candidates[0]

        experimental, experimental_backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}', '{"ad_ids":[1]}', '{"programme_ids":[0,2]}'],
            experimental_candidates=[candidate],
            experimental_max_additional_model_calls=2,
        )
        self.assertEqual(experimental.audit.speculative_cuts[0]["ids"], (1,))
        self.assertEqual(experimental.audit.experimental_requests, 2)
        self.assertEqual(len(experimental_backend.calls), 4)

    def test_incomplete_adaptation_returns_no_speculative_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        report, _unused_backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}'],
            experimental_candidates=[wp.AuditCandidate("unobserved", (1,), "missing evidence")],
            experimental_max_additional_model_calls=1,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIsNotNone(report.audit.incomplete_error)

    def test_adaptation_over_budget_returns_no_speculative_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        baseline, _backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])

        report, _backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}'],
            experimental_candidates=[baseline.audit.candidates[0]],
            experimental_max_additional_model_calls=1,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIn("budget", report.audit.incomplete_error)
        self.assertEqual(len(_backend.calls), 2, "budget refusal must occur before experimental inference")

    def test_unknown_classifier_shape_and_schema_fail_closed(self):
        def unknown_prompt(_segments, backend):
            try:
                backend.generate("new classification format", self.rendered([0]))
            except wp.WorkerError:
                pass
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(unknown_prompt, [])
        self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")

        def wrong_schema(_segments, backend):
            try:
                backend.generate("classify", self.rendered([0]), response_format={"type": "json_object"})
            except wp.WorkerError:
                pass
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(wrong_schema, [])
        self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")

    def test_unrelated_boundary_prompt_is_allowed_but_cannot_replace_classifier_coverage(self):
        def detector(_segments, backend):
            response, _ = backend.generate(
                "BOUNDARY review",
                self.rendered([0]),
                response_format={"field": "program_id", "ids": [0]},
            )
            self.assertEqual(response, '{"program_id":0}')
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ['{"program_id":0}'], auto_cover=False)
        self.assertEqual(raised.exception.code, "ads-classification-incomplete")

    def test_partial_valid_coverage_fails_with_missing_global_ids(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([0]), response_format=backend._classification_response_format)
            return []

        with self.assertRaises(wp.WorkerError) as raised:
            self.analysis(detector, ['{"ads":[]}'], auto_cover=False)
        self.assertEqual(raised.exception.code, "ads-classification-incomplete")
        self.assertIn("1, 2", str(raised.exception))

    def test_invalid_experimental_answer_returns_no_arbitrary_cut(self):
        def detector(_segments, backend):
            backend.generate("classify", self.rendered([1]), response_format=backend._classification_response_format)
            return []

        baseline, _backend = self.analysis(detector, ['{"ads":[[1,"sponsor_read"]]}'])
        report, _backend = self.analysis(
            detector,
            ['{"ads":[[1,"sponsor_read"]]}', '{"ad_ids":[99]}'],
            experimental_candidates=[baseline.audit.candidates[0]],
            experimental_max_additional_model_calls=2,
        )
        self.assertEqual(report.audit.speculative_cuts, ())
        self.assertIn("incomplete", report.audit.incomplete_error)
        self.assertEqual(report.audit.experimental_requests, 1)

    def test_experimental_nonfinite_duration_and_oversized_context_fail_before_calls(self):
        class Backend:
            calls = 0

            def generate(self, *_args, **_kwargs):
                self.calls += 1
                raise AssertionError("unsafe experimental input reached inference")

        candidate = wp.AuditCandidate("visible-truncation", (1,), "bounded evidence")
        audit = wp.AdAnalysisAudit(candidates=(candidate,))
        backend = Backend()
        result = wp._experimental_speculative_cuts(audit, backend, self.segments, float("inf"), [candidate], 2)
        self.assertEqual((backend.calls, result.speculative_cuts), (0, ()))

        segments = [FakeSegment(float(i), float(i + 1), f"cue {i}") for i in range(70)]
        candidate = wp.AuditCandidate("visible-truncation", tuple(range(1, 65)), "bounded evidence")
        audit = wp.AdAnalysisAudit(candidates=(candidate,))
        backend = Backend()
        result = wp._experimental_speculative_cuts(audit, backend, segments, 1000.0, [candidate], 2)
        self.assertEqual((backend.calls, result.speculative_cuts), (0, ()))
        self.assertIn("context ID budget", result.incomplete_error)

    def test_duplicate_and_out_of_range_rendered_ids_fail_closed(self):
        for ids in ([0, 0], [99]):
            with self.subTest(ids=ids):
                def detector(_segments, backend, ids=ids):
                    try:
                        backend.generate("classify", self.rendered(ids), response_format=backend._classification_response_format)
                    except wp.WorkerError:
                        pass
                    return []

                with self.assertRaises(wp.WorkerError) as raised:
                    self.analysis(detector, [])
                self.assertEqual(raised.exception.code, "ads-audit-contract-unavailable")


class AdCorpusReplayWiringTests(unittest.TestCase):
    """The replay path, with the model stubbed out.

    Replay is the tool a detector fix will be measured with, and it only runs
    for real behind a four-gigabyte model, so nothing else in the gate reaches
    it. These tests stand in for `wilted.llm` and check that a replay hands the
    shared analysis entry what a real preparation hands it -- the same segment
    type, the same duration, inside the same capability -- and that a refusal
    from it lands against the case that provoked it.

    The judgement itself, and the order of the recovery passes around it, are
    `analyze_ad_detections`' contract and are tested where they live. That is
    the point of the change these tests describe: the replay used to assemble
    that sequence itself, so it could drift from the app one edit at a time,
    and it had -- it was missing the coverage refusals and the dropped-anchor
    audit, and could score a run the app would have refused outright.
    """

    def setUp(self):
        self.corpus = load_ad_corpus()
        self.calls = []
        self.addCleanup(self.restore_modules, dict(sys.modules))

    def restore_modules(self, snapshot):
        for name in [n for n in sys.modules if n.startswith("wilted.") or n == "wilted"]:
            if name not in snapshot:
                del sys.modules[name]

    def cache_for(self, case, *, segments=None):
        """A cache directory holding exactly this case's entry.

        Keyed by `sourceHash` the way the real one is, so `cached_segments`
        finds it by the same match. Built rather than borrowed: the local
        aligned-STT cache is mutable state that another machine does not have,
        and a wiring test that skips itself there proves nothing in the gate.
        """
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        count = case["segmentCount"] if segments is None else segments
        step = float(case["audioDurationSeconds"]) / count
        (root / "entry.json").write_text(json.dumps({
            "sourceHash": case["sourceHash"],
            "segments": [
                {"text": f"cue {index}", "start_s": index * step, "end_s": (index + 1) * step}
                for index in range(count)
            ],
        }))
        return root

    def install_stubs(self, detections=(), analyze=None):
        class Ad:
            def __init__(self, start_s, end_s, confidence=1.0, label="ad_break"):
                self.start_s, self.end_s = start_s, end_s
                self.confidence, self.label = confidence, label

        calls = self.calls
        ads = types.ModuleType("wilted.ads")
        ads.AdSegment = Ad
        # The classifier contract `AuditingBackend` refuses to run without.
        # Only the live path builds one before handing it over, but the stub
        # has to satisfy it for the parity test below to reach the same call.
        ads._AD_DETECT_SYSTEM_PROMPT = "classify"
        ads._AD_DETECT_CORRECTION_PROMPT = "correct"
        ads._AD_DETECT_RESPONSE_FORMAT = {"type": "json_object"}
        ads._parse_ad_response = lambda response, expected_ids: []

        class Backend:
            def load(inner):
                calls.append(("load",))

            def close(inner):
                calls.append(("close",))

        llm = types.ModuleType("wilted.llm")
        llm.DEFAULT_GGUF_MODEL = "/models/stand-in.gguf"
        llm.create_backend = lambda kind, model: (
            calls.append(("create_backend", kind, model)) or Backend()
        )
        # The archive will not build a model outside this, and the worker claims
        # it in `main` rather than in any pass, so a replay importing the passes
        # directly gets no capability unless it claims one itself.
        @contextmanager
        def capability_scope(*, owner_id, data_dir):
            calls.append(("capability", owner_id, str(data_dir)))
            try:
                yield object()
            finally:
                calls.append(("capability_released",))

        capability = types.ModuleType("wilted.execution_capability")
        capability.execution_capability_scope = capability_scope

        package = types.ModuleType("wilted")
        package.ads, package.llm = ads, llm
        package.execution_capability = capability
        sys.modules.update({"wilted": package, "wilted.ads": ads, "wilted.llm": llm,
                            "wilted.execution_capability": capability})
        self.use_archive(self.fake_archive())

        def recorder(ads_module, backend, segments, total, **kwargs):
            calls.append(("analyze", segments, total, backend, ads_module))
            if analyze is not None:
                return analyze()
            return wp.AdAnalysis(tuple(Ad(*span) for span in detections), wp.AdAnalysisAudit())

        self.patch("analyze_ad_detections", recorder)
        self.patch("prepare_ad_model_lock", lambda *_a, **_k: None)

    def fake_archive(self):
        """A directory shaped like the archive, for the existence check to find.

        `sys.modules` already holds the stub package, so the import itself would
        succeed anywhere; the check that runs before it is what needs a path.
        """
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        (Path(root) / "wilted").mkdir()
        (Path(root) / "wilted" / "ads.py").write_text("")
        return root

    def use_archive(self, path):
        patcher = mock.patch.dict(os.environ, {"WILTED_PIPELINE_PYTHONPATH": str(path)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_archive_is_resolved_the_way_the_app_resolves_it(self):
        # Swift hands the worker a PYTHONPATH from this variable with this
        # fallback. A replay resolving it any other way would be measuring a
        # different detector than the one the app runs.
        self.use_archive("/tmp/somewhere-else/src")
        self.assertEqual(self.corpus.archive_sources(), Path("/tmp/somewhere-else/src"))
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.corpus.archive_sources(), self.corpus.DEFAULT_ARCHIVE_SOURCES)
        self.assertTrue(str(self.corpus.DEFAULT_ARCHIVE_SOURCES).endswith("wilted-old/src"))

    def test_a_missing_archive_is_named_rather_than_left_as_an_import_error(self):
        # Nothing in the worker puts the archive on the path -- Swift does it
        # from outside -- so a replay run from a shell finds it or explains why.
        case = self.waveform()
        cache = self.cache_for(case)
        self.install_stubs()
        empty = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, empty, True)
        self.use_archive(empty)
        with self.assertRaises(RuntimeError) as caught:
            self.corpus.replay_spans(case, cache=cache)
        self.assertIn(empty, str(caught.exception))
        self.assertIn("WILTED_PIPELINE_PYTHONPATH", str(caught.exception))

    def patch(self, name, replacement):
        """`mock.patch.object` in the form the system interpreter supports.

        This leg runs under whatever `python3` is first on PATH, which on this
        host is 3.9 outside the gate, so `TestCase.enterContext` is not
        available.
        """
        patcher = mock.patch.object(wp, name, replacement)
        patcher.start()
        self.addCleanup(patcher.stop)

    def waveform(self):
        for case in self.corpus.load_manifest()["cases"]:
            if case["id"] == "waveform-two-preroll-sponsor-reads":
                return case
        self.fail("the Waveform case is no longer in the corpus")

    def replay(self, case, detections=(), analyze=None, cache=None):
        cache = cache if cache is not None else self.cache_for(case)
        self.install_stubs(detections, analyze)
        return self.corpus.replay_spans(case, cache=cache)

    def analyzed(self):
        return next(call for call in self.calls if call[0] == "analyze")

    def test_a_replay_reproduces_the_worker_call_for_call(self):
        case = self.waveform()
        spans, audit = self.replay(case, detections=[(100.0, 200.0)])
        names = [call[0] for call in self.calls]
        self.assertEqual(names, [
            "capability", "create_backend", "load", "analyze", "close", "capability_released",
        ])
        self.assertEqual([(span.start, span.end) for span in spans], [(100.0, 200.0)])
        # The same evidence a live analysis publishes, so a corpus verdict can
        # be trusted or distrusted on the same grounds as a preparation.
        self.assertIn("modelRequests", audit)

    def test_a_replay_and_a_preparation_make_the_same_analysis_call(self):
        # The whole point of the shared entry: if these two ever diverge, the
        # corpus is measuring a detector the app does not run, which is the
        # defect this replaced. Driven through `detect_and_cut` rather than
        # asserted by reading the two, because the divergence that happened
        # before was invisible to anyone reading either one on its own -- both
        # looked right, and the replay was quietly missing the coverage
        # refusals and the dropped-anchor audit.
        case = self.waveform()
        self.replay(case)
        replay_call = self.analyzed()

        self.calls.clear()
        segments = list(replay_call[1])
        with mock.patch.object(wp, "probe_duration", lambda _path: replay_call[2]), \
                mock.patch.object(wp, "prepare_ad_model_lock", lambda *_a, **_k: None), \
                redirect_stderr(io.StringIO()):
            wp.detect_and_cut({}, Path("/nowhere/in.m4a"), [], segments)
        live_call = self.analyzed()

        self.assertEqual(live_call[4], replay_call[4], "a different detector module")
        self.assertEqual([(s.start_s, s.end_s, s.text) for s in live_call[1]],
                         [(s.start_s, s.end_s, s.text) for s in replay_call[1]])
        self.assertEqual(live_call[2], replay_call[2])

    def test_a_replay_never_transcribes_anything_a_second_time(self):
        # One Parakeet pass supplies both detection and the displayed
        # transcript, and the corpus exists to measure that exact input. A
        # replay that transcribed again would be scoring a different episode
        # while reporting the case's source hash -- and on a machine where the
        # daemon is not running it would fail rather than measure anything.
        case = self.waveform()

        def refuse(*_args, **_kwargs):
            self.fail("the replay reached speech-to-text")

        with mock.patch.object(wp, "transcribe_with_daemon", refuse):
            spans, _ = self.replay(case, detections=[(1.0, 2.0)])
        self.assertEqual([(span.start, span.end) for span in spans], [(1.0, 2.0)])

    def test_a_refusal_is_recorded_against_its_case_rather_than_ending_the_run(self):
        # `ads-classification-unresolved` means the classifier never resolved
        # some cues. Scoring what it did return would be scoring a guess, and
        # crashing the harness would lose every other case's verdict.
        case = self.waveform()
        cache = self.cache_for(case)

        def refuse():
            raise wp.WorkerError("ads-classification-unresolved",
                                 "classifier exhausted normal and corrective retries for global IDs: 7")

        self.install_stubs(analyze=refuse)
        with self.assertRaises(self.corpus.ReplayRefused) as caught:
            self.corpus.replay_spans(case, cache=cache)
        self.assertEqual(caught.exception.code, "ads-classification-unresolved")

        with redirect_stderr(io.StringIO()):
            results = self.corpus.run("replay", library=Path("/nowhere"), cache=cache,
                                      strict=True)
        refused = next(r for r in results if r.case_id == case["id"])
        self.assertFalse(refused.passed)
        self.assertFalse(refused.skipped)
        self.assertIn("ads-classification-unresolved", refused.reason)
        self.assertEqual(refused.spans, [])

    def test_the_model_is_built_inside_a_claimed_execution_capability(self):
        # The archive gates multi-gigabyte model construction on this, and the
        # worker claims it in `main`. A replay calls the analysis entry
        # directly, so without its own claim `create_backend` raises before any
        # measurement.
        case = self.waveform()
        cache = self.cache_for(case)
        self.replay(case, cache=cache)
        claimed = next(call for call in self.calls if call[0] == "capability")
        self.assertEqual(claimed[1], "wilted-ad-corpus-replay")
        self.assertEqual(claimed[2], str(cache.parent))
        self.assertLess(self.calls.index(claimed),
                        [call[0] for call in self.calls].index("create_backend"))
        self.assertEqual(self.calls[-1][0], "capability_released")

    def test_the_detector_is_handed_the_type_the_worker_hands_it(self):
        # Duck typing makes the archive's own `TranscriptSegment` look
        # interchangeable here. It is not the call the app makes.
        case = self.waveform()
        self.replay(case)
        _, segments, _, _, _ = self.analyzed()
        self.assertEqual(len(segments), case["segmentCount"])
        self.assertEqual(type(segments[0]).__name__, "CachedAlignedSegment")

    def test_the_size_guards_divide_by_the_audio_not_the_transcript(self):
        case = self.waveform()
        self.replay(case)
        self.assertEqual(self.analyzed()[2], case["audioDurationSeconds"])
        self.assertNotEqual(case["audioDurationSeconds"], case["transcriptEndSeconds"])

    def test_a_replay_says_which_case_it_is_working_on(self):
        # A replay spends minutes per case and emits nothing of its own
        # meanwhile: the detector's journal names no case and the report only
        # lands at the end, so two cases running are one interleaved stream
        # nobody can attribute.
        stderr = io.StringIO()
        with mock.patch.object(self.corpus, "replay_spans", lambda case, *, cache: None), \
                redirect_stderr(stderr):
            results = self.corpus.run(
                "replay", library=Path("/nowhere"), cache=Path("/nowhere"))
        named = [line for line in stderr.getvalue().splitlines()
                 if line.startswith("ad-corpus: replaying ")]
        self.assertEqual(len(named), len(results))
        for verdict, line in zip(results, named):
            self.assertIn(verdict.case_id, line)

    def test_reading_the_library_back_does_not_announce_itself(self):
        # `recorded` is milliseconds a case and prints its report immediately,
        # so the same line there would be noise rather than progress.
        stderr = io.StringIO()
        with mock.patch.object(self.corpus, "recorded_spans", lambda case, *, library: None), \
                redirect_stderr(stderr):
            self.corpus.run("recorded", library=Path("/nowhere"), cache=Path("/nowhere"))
        self.assertNotIn("replaying", stderr.getvalue())

    def test_a_source_hash_no_cache_entry_matches_is_a_skip_not_an_empty_result(self):
        # "Never prepared here" and "the detector found nothing" are opposite
        # readings, and only one of them is a failure.
        case = dict(self.waveform(), sourceHash="sha256:notacachedrun")
        self.install_stubs()
        self.assertIsNone(self.corpus.replay_spans(case, cache=self.cache_for(self.waveform())))

    def test_a_missing_input_skips_by_default_and_fails_the_candidate_run(self):
        # The mode a fix is judged in cannot let the corpus shrink to whatever
        # this machine happens to hold: two cases becoming one skipped case and
        # one pass exits zero and reads as success.
        empty = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, empty, True)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            lenient = self.corpus.run("replay", library=Path("/nowhere"), cache=empty)
            self.assertEqual(self.corpus.main(["--mode", "replay", "--cache", str(empty)]), 0)
            strict = self.corpus.run("replay", library=Path("/nowhere"), cache=empty, strict=True)
        self.assertTrue(all(r.skipped and r.passed for r in lenient))
        self.assertTrue(strict)
        for verdict in strict:
            self.assertFalse(verdict.passed)
            self.assertFalse(verdict.skipped)
            # Named, not just counted: "something did not run" is not enough to
            # act on when the fix is to go and prepare the missing episode.
            self.assertIn("no cached transcript for sha256:", verdict.reason)
            self.assertIn(str(empty), verdict.reason)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(
                self.corpus.main(["--mode", "replay", "--cache", str(empty), "--strict"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
