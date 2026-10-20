"""Podcast worker tests: an uncertain ad detection keeps the original audio."""
from __future__ import annotations
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from worker_test_support import *
from worker_test_fake_llm import *
from worker_test_fake_ads import *


class UncertainAdDetectionTests(unittest.TestCase):
    """Production quality fallbacks preserve playable original audio and evidence."""

    def setUp(self):
        self.audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        self.segments = [FakeSegment(0, 2, "buy this"), FakeSegment(2, 4, "content")]
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}

    def test_production_model_failure_retains_original_with_diagnostics(self):
        for llm, reason in (
            (FakeLLM(fail_load=FileNotFoundError("missing GGUF")), "missing GGUF"),
            (FakeLLM(fail_generate=RuntimeError("decode failed")), "decode failed"),
        ):
            with self.subTest(reason=reason):
                install_fake_ads(llm)
                with redirect_stderr(io.StringIO()), \
                        mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                        mock.patch.object(_worker_cue_timing, "_run_render_with_progress") as render:
                    path, spans, keeps, raw, audit = wp.detect_and_cut(
                        self.request, self.audio, [], self.segments
                    )
                self.assertEqual((path, spans, keeps, raw), (self.audio, [], [], []))
                self.assertIn(reason, audit["incompleteError"])
                self.assertTrue(audit["warning"].startswith("original audio includes ads:"))
                render.assert_not_called()
                self.assertTrue(llm.closed)

    def test_production_unresolved_and_invalid_classifier_contract_retain_original(self):
        for code in ("ads-classification-unresolved", "ads-classification-incomplete",
                     "ads-audit-contract-unavailable", "ads-recovery-audit-failed"):
            with self.subTest(code=code):
                install_fake_ads(FakeLLM())
                with redirect_stderr(io.StringIO()), \
                        mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                        mock.patch.object(_worker_ad_removal, "analyze_ad_detections", side_effect=wp.WorkerError(code, "IDs 0, 1 unresolved")), \
                        mock.patch.object(_worker_cue_timing, "_run_render_with_progress") as render:
                    path, spans, keeps, raw, audit = wp.detect_and_cut(
                        self.request, self.audio, [], self.segments
                    )
                self.assertEqual((path, spans, keeps, raw), (self.audio, [], [], []))
                self.assertIn("IDs 0, 1", audit["incompleteError"])
                render.assert_not_called()

    def test_invalid_singleton_answers_keep_actual_unresolved_ids_and_counts(self):
        llm = FakeLLM(classifier_answer="invalid JSON")
        ads = install_fake_ads(llm)
        def detector(segments, backend):
            for prompt in (ads._AD_DETECT_SYSTEM_PROMPT, ads._AD_DETECT_CORRECTION_PROMPT):
                backend.generate(prompt, "[ID 0] buy this", response_format=ads._AD_DETECT_RESPONSE_FORMAT)
            return []
        ads.detect_ads = detector
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            path, spans, keeps, raw, audit = wp.detect_and_cut(
                self.request, self.audio, [], self.segments
            )
        self.assertEqual((path, spans, keeps), (self.audio, [], []))
        self.assertEqual(audit["unresolvedIds"], [0])
        self.assertEqual(audit["classifierValidRequests"], 0)
        self.assertEqual(audit["classifierInvalidRequests"], 4)
        self.assertEqual(audit["modelRequests"], 4)
        self.assertIn("global IDs: 0", audit["incompleteError"])

    def test_definite_programme_seed_preserves_an_independent_confirmed_cut(self):
        segments = [FakeSegment(0, 10, "programme before"),
                    FakeSegment(10, 20, "visit acme dot"),
                    FakeSegment(20, 30, "com to get started today"),
                    FakeSegment(30, 40, "programme after")]
        install_fake_ads(FakeLLM(commercial_ad_ids=[1, 2], commercial_programme_ids=[0, 1, 2, 3]),
                         detections=[FakeAd(100, 120)])
        with tempfile.TemporaryDirectory() as directory, redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", side_effect=lambda path: 480.0 if ".rendering-" in path.name else 500.0), \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress", side_effect=lambda command, **_kwargs: Path(command[-1]).write_bytes(b"synthetic") if "-filter_complex" in command else ""):
            request = {**self.request, "outputPath": str(Path(directory, "cut.mp3"))}
            path, spans, keeps, raw, audit = wp.detect_and_cut(request, self.audio, [], segments)
        self.assertNotEqual(path, self.audio)
        self.assertEqual([(span["startSeconds"], span["endSeconds"]) for span in spans], [(100.0, 120.0)])
        self.assertTrue(keeps)
        self.assertIsNone(audit["warning"])
        self.assertEqual(audit["declinedCommercialEvidenceSeeds"][0]["reason"], "review-declined")

    def test_unexpected_detector_and_backend_defects_remain_fatal(self):
        for error in (ValueError("coding defect"), TypeError("coding defect"), AttributeError("coding defect")):
            with self.subTest(error=type(error).__name__):
                install_fake_ads(FakeLLM())
                with redirect_stderr(io.StringIO()), \
                        mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                        mock.patch.object(_worker_ad_removal, "analyze_ad_detections", side_effect=error), \
                        self.assertRaises(type(error)):
                    wp.detect_and_cut(self.request, self.audio, [], self.segments)
                install_fake_ads(FakeLLM(fail_generate=error))
                with redirect_stderr(io.StringIO()), \
                        mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                        self.assertRaises(type(error)):
                    wp.detect_and_cut(self.request, self.audio, [], self.segments)

    def test_audio_probe_failure_remains_fatal_in_production(self):
        install_fake_ads(FakeLLM())
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", side_effect=RuntimeError("invalid audio")), \
                self.assertRaisesRegex(RuntimeError, "invalid audio"):
            wp.detect_and_cut(self.request, self.audio, [], self.segments)

