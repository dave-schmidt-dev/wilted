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
from worker_test_support import wp
from worker_test_fake_llm import *
from worker_test_fake_ads import *
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources
from wilted_worker.constants import ALIGNED_STT_CACHE_SCHEMA_VERSION

@dataclass
class AlignedToken:
    text: str
    start_s: float
    end_s: float

@dataclass
class AlignedSegment:
    start_s: float
    end_s: float
    text: str
    tokens: tuple | None = None

def aligned(*pieces) -> AlignedSegment:
    """Build a segment the way parakeet does: text is its tokens joined, stripped."""
    tokens = tuple(AlignedToken(text, start, end) for text, start, end in pieces)
    return AlignedSegment(tokens[0].start_s, tokens[-1].end_s, "".join(t.text for t in tokens).strip(), tokens)

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
        with mock.patch.object(_worker_cue_timing, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            return wp.run(request or self.request)

    def test_reuses_a_detector_compatible_transcript_with_the_explicit_model(self):
        calls = []
        install_fake_wilted()
        transcribe = sys.modules["wilted.transcribe"]

        def transcribe_audio(_path, model_name, **_):
            calls.append(model_name)
            return [FakeSegment(0, 1, "detector words")]

        transcribe.transcribe_audio = transcribe_audio
        request = {**self.request, "alignedTranscriptModel": wp.ALIGNED_STT_MODEL}
        self.run_pipeline(request)
        self.assertEqual(calls, [wp.ALIGNED_STT_MODEL])
        cached = json.loads(self.cache_path(request).read_text())
        self.assertEqual(cached["model"], wp.ALIGNED_STT_MODEL)
        self.assertEqual(cached["sourceHash"], "sha256:source-one")

        # A new daemon double has no valid answer. A cache hit must therefore
        # be what makes this retry succeed, and it must rebuild `.text`,
        # `.start_s`, and `.end_s` for the detector rather than return JSON.
        install_fake_wilted()
        install_fake_ads(FakeLLM())
        request.update({
            "protocolVersion": 2, "removeAds": True,
            "outputPath": str(Path(self.temporary.name) / "prepared.mp3"),
        })
        with mock.patch.object(_worker_ad_removal, "detect_and_cut") as detector:
            with mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                    mock.patch.object(_worker_ad_audit, "preflight_cut_tools"), \
                    mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()):
                # The detector is not reached because this stub prevents the
                # production cut path; its input is still observable below.
                detector.return_value = (
                    self.audio, [], [], [], wp.serialize_ad_audit(_worker_ad_audit.AdAnalysisAudit())
                )
                self.run_pipeline(request)
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
            "mismatched": json.dumps({"schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION, "sourceHash": "sha256:other",
                                      "model": "detector-v1", "segments": []}),
            "invalid-cue": json.dumps({"schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION, "sourceHash": "sha256:source-one",
                                        "model": "detector-v1", "segments": [{"text": "", "start_s": 1, "end_s": 1}]}),
            # A transcript cached before split words were rejoined is valid in
            # every other respect, and must still not be reused.
            "stale-schema": json.dumps({"schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION - 1,
                                         "sourceHash": "sha256:source-one", "model": "detector-v1",
                                         "segments": [{"text": "This is meas", "start_s": 0, "end_s": 1}]}),
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
        request = {
            **self.request, "protocolVersion": 2, "removeAds": True,
            "alignedTranscriptModel": wp.ALIGNED_STT_MODEL,
            "outputPath": str(Path(self.temporary.name) / "prepared.mp3"),
        }
        wp._store_cached_aligned_segments(
            request, request["sourceHash"], request["alignedTranscriptModel"],
            [FakeSegment(0, 1, "cached")],
        )
        install_fake_ads(FakeLLM())
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                mock.patch.object(_worker_ad_audit, "preflight_cut_tools"), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(_worker_ad_removal, "detect_and_cut", side_effect=wp.WorkerError("ads-down", "detector unavailable")), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run(request)
        self.assertEqual(raised.exception.code, "ads-down")
        self.assertTrue(self.cache_path(request).exists())

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

    def test_words_split_by_the_aligner_are_rejoined_before_they_are_returned_or_cached(self):
        install_fake_wilted()
        sys.modules["wilted.transcribe"].transcribe_audio = lambda _path, model_name, **_: [
            aligned(("urable", 0.6, 0.7), (" and", 0.7, 0.8), (" more", 0.8, 0.9)),
            aligned((" This", 0.0, 0.1), (" is", 0.1, 0.2), (" meas", 0.5, 0.6)),
        ]
        with redirect_stderr(io.StringIO()):
            returned = _worker_transcript_sources.transcribe_with_daemon(self.audio, "detector-v1")
        self.assertEqual([(s.text, s.start_s, s.end_s) for s in returned],
                         [("This is measurable", 0.0, 0.7), ("and more", 0.7, 0.9)])

        self.run_pipeline()
        cached = json.loads(self.cache_path().read_text())
        self.assertEqual(cached["schemaVersion"], ALIGNED_STT_CACHE_SCHEMA_VERSION)
        self.assertEqual([(e["text"], e["start_s"], e["end_s"]) for e in cached["segments"]],
                         [("This is measurable", 0.0, 0.7), ("and more", 0.7, 0.9)])

    def test_a_segment_that_spans_no_time_is_dropped_and_the_pass_still_caches(self):
        # parakeet-tdt-0.6b-v3 emitted 2616.48-2616.48 "are." on Rogan #2565;
        # the cache refuses any such segment, which used to cost the whole pass.
        install_fake_wilted()
        sys.modules["wilted.transcribe"].transcribe_audio = lambda _path, model_name, **_: [
            FakeSegment(0.0, 0.5, "Before."), FakeSegment(0.5, 0.5, "are."),
            FakeSegment(0.6, 0.6, " "), FakeSegment(0.6, 1.0, "After."),
        ]
        with redirect_stderr(io.StringIO()) as err:
            returned = _worker_transcript_sources.transcribe_with_daemon(self.audio, "detector-v1")
        self.assertEqual([s.text for s in returned], ["Before.", "After."])
        self.assertIn("transcript.stt.untimed.dropped", err.getvalue())

        self.run_pipeline()
        cached = json.loads(self.cache_path().read_text())
        self.assertEqual([e["text"] for e in cached["segments"]], ["Before.", "After."])

    def test_an_app_built_before_v3_is_served_with_v3_rather_than_refused(self):
        # The installed app runs this checkout's worker and still names 1.1b
        # until it is rebuilt; refusing it failed every ad-removal preparation.
        calls = []
        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: [FakeSegment(0, 1, "programme")]})
        transcribe = sys.modules["wilted.transcribe"]
        original = transcribe.transcribe_audio
        install_fake_ads(FakeLLM())
        request = {"protocolVersion": 2, "audioPath": str(self.audio), "outputPath": "/tmp/cut.mp3",
                   "removeAds": True, "alignedTranscriptModel": "mlx-community/parakeet-tdt-1.1b"}
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=10.0), \
                mock.patch.object(transcribe, "transcribe_audio",
                                  lambda *a, **k: calls.append(k["model_name"]) or original(*a, **k)), \
                redirect_stderr(io.StringIO()) as progress:
            result = wp.run(request)
        self.assertEqual(calls, [wp.ALIGNED_STT_MODEL])
        self.assertEqual(result["report"]["outcome"], "noAds")
        self.assertIn("transcript.stt.model.substituted", progress.getvalue())

        with mock.patch.object(_worker_ad_audit, "preflight_cut_tools"), self.assertRaises(wp.WorkerError) as raised:
            wp.run({**request, "alignedTranscriptModel": "some-other-model"})
        self.assertEqual(raised.exception.code, "aligned-stt-model-required")

    def test_a_join_that_moves_a_start_past_its_neighbour_still_caches_in_order(self):
        # Overlapping stitched windows can put a segment between the fragment
        # and the rest of the sentence it opened; the cache refuses any
        # transcript that is not in time order.
        install_fake_wilted()
        sys.modules["wilted.transcribe"].transcribe_audio = lambda _path, model_name, **_: [
            aligned((" A", 0.0, 0.1), (" meas", 0.3, 0.4)),
            aligned(("urable", 0.4, 0.5), (" end", 0.8, 0.9)),
            aligned((" overlap", 0.6, 0.7)),
        ]
        self.run_pipeline()
        cached = json.loads(self.cache_path().read_text())
        self.assertEqual([e["text"] for e in cached["segments"]], ["A measurable", "overlap", "end"])
