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
            _worker_cue_timing, "probe_duration", return_value=3600.0
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
            _worker_cue_timing, "probe_duration", return_value=3700.0
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
                    _worker_cue_timing, "probe_duration", return_value=10_800.0
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
            _worker_cue_timing, "probe_duration", side_effect=OSError("ffprobe missing")
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
        detect = mock.patch.object(_worker_ad_removal, "detect_and_cut", side_effect=AssertionError("a misaligned transcript drove the cut"))
        with detect as detector, redirect_stderr(io.StringIO()), mock.patch.object(
            _worker_ad_audit, "preflight_ad_removal"
        ), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=3700.0):
            result = wp.run({"audioPath": str(self.audio), "removeAds": True,
                             "transcriptPolicy": "noLocalSTT", "publishedTranscript": self.PUBLISHED})
        detector.assert_not_called()
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["timing"], "none")

    def test_untimed_prose_never_drives_ad_removal(self):
        install_fake_wilted()
        install_fake_trafilatura(prose_transcript("untimed prose words"))
        detect = mock.patch.object(_worker_ad_removal, "detect_and_cut", side_effect=AssertionError("prose drove ad removal"))
        with detect as detector, redirect_stderr(io.StringIO()), mock.patch.object(
            _worker_ad_audit, "preflight_ad_removal"
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
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal") as preflight, self.assertRaises(wp.WorkerError) as raised:
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
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=10.0), redirect_stderr(io.StringIO()):
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

    def test_render_resamples_the_concat_graph_before_the_encoder(self):
        # Regression for a real crash: libmp3lame's FLTP path rejects any
        # frame with linesize < 4 * FFALIGN(nb_samples, 8), which the raw
        # atrim+concat output can produce at non-frame-aligned trim points.
        # Reproduced against a real crashed episode's source audio; fixed by
        # resampling once more after concat, before the encoder ever sees it.
        scratch = REPO_ROOT / ".verify-tmp" / f"render-filtergraph-{os.getpid()}"
        scratch.mkdir(parents=True, exist_ok=True)
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        source = scratch / "source.mp3"
        source.write_bytes(b"\x00")
        output = scratch / "cut.mp3"
        keeps = wp.build_keep_map([(0.0, 3.0), (7.5, 12.0)])
        captured: dict[str, list[str]] = {}

        def fake_run(command, *, timeout_s):
            captured["command"] = command
            Path(command[-1]).write_bytes(b"\x00")

        with mock.patch.object(_worker_cue_timing, "_run_render_with_progress", side_effect=fake_run), \
             mock.patch.object(_worker_cue_timing, "probe_duration", return_value=7.5):
            wp.render_keep_segments(source, output, keeps)

        command = captured["command"]
        filter_complex = command[command.index("-filter_complex") + 1]
        self.assertIn("concat=n=2:v=0:a=1[outc]", filter_complex)
        self.assertIn(";[outc]aresample[outa]", filter_complex)
        self.assertEqual(command[command.index("-map") + 1], "[outa]")

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
