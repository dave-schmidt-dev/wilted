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
from wilted_worker.ad_audit import AdAnalysis, AdAnalysisAudit, DeclinedCommercialEvidenceSeed, HeldAdSpan
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

    def test_production_whole_original_serializes_canonical_holds(self):
        llm = FakeLLM()
        install_fake_ads(llm)
        audit = AdAnalysisAudit(
            held_spans=(
                HeldAdSpan(20.0, 25.0, "programme-boundary"),
                HeldAdSpan(10.0, 30.0, "programme-boundary-conflict"),
            ),
            declined_commercial_evidence_seeds=(
                DeclinedCommercialEvidenceSeed(
                    ids=(4,), start_s=40.0, end_s=50.0, reason="dropped-after-proposal",
                ),
            ),
        )
        analysis = AdAnalysis((), audit)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                mock.patch.object(_worker_ad_removal, "analyze_ad_detections", return_value=analysis), \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress") as render:
            path, spans, keeps, raw, serialized = wp.detect_and_cut(
                self.request, self.audio, [], self.segments
            )

        self.assertEqual((path, spans, keeps, raw), (self.audio, [], [], []))
        self.assertEqual(
            serialized["heldSpans"],
            [
                {"reason": "programme-boundary", "startSeconds": 20.0, "endSeconds": 25.0},
                {"reason": "programme-boundary-conflict", "startSeconds": 10.0, "endSeconds": 30.0},
            ],
        )
        self.assertEqual(
            serialized["declinedCommercialEvidenceSeeds"][0]["reason"],
            "dropped-after-proposal",
        )
        self.assertTrue(serialized["warning"].startswith("original audio includes ads:"))
        self.assertIsNotNone(serialized["incompleteError"])
        render.assert_not_called()

    def test_production_share_refusal_serializes_retired_holds(self):
        llm = FakeLLM()
        install_fake_ads(llm)
        audit = AdAnalysisAudit(
            held_spans=tuple(
                HeldAdSpan(start, end, "total-share-ceiling")
                for start, end in ((10.0, 29.0), (40.0, 59.0), (70.0, 89.0), (100.0, 170.0))
            ),
            declined_commercial_evidence_seeds=(
                DeclinedCommercialEvidenceSeed(
                    ids=(4,), start_s=40.0, end_s=50.0, reason="dropped-after-proposal",
                ),
            ),
        )
        analysis = AdAnalysis((), audit)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0), \
                mock.patch.object(_worker_ad_removal, "analyze_ad_detections", return_value=analysis), \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress") as render:
            path, spans, keeps, raw, serialized = wp.detect_and_cut(
                self.request, self.audio, [], self.segments
            )

        self.assertEqual((path, spans, keeps, raw), (self.audio, [], [], []))
        self.assertEqual(len(serialized["heldSpans"]), 4)
        self.assertTrue(all(
            span["reason"] == "total-share-ceiling"
            for span in serialized["heldSpans"]
        ))
        self.assertEqual(
            serialized["declinedCommercialEvidenceSeeds"][0]["reason"],
            "dropped-after-proposal",
        )
        self.assertTrue(serialized["warning"].startswith("original audio includes ads:"))
        render.assert_not_called()

    def test_early_model_and_contract_failures_preserve_invalid_profile_status(self):
        requested_digest = "a" * 64
        request = {
            **self.request,
            "feedID": "feed-exact-1",
            "adProfile": {"payload": "{}", "digest": requested_digest},
        }
        scenarios = (
            (FakeLLM(fail_load=FileNotFoundError("missing GGUF")), False),
            (FakeLLM(), True),
        )
        for llm, break_contract in scenarios:
            with self.subTest(break_contract=break_contract):
                ads = install_fake_ads(llm)
                if break_contract:
                    del ads._parse_ad_response
                with redirect_stderr(io.StringIO()), \
                        mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
                    _path, spans, keeps, raw, audit = wp.detect_and_cut(
                        request, self.audio, [], self.segments
                    )
                self.assertEqual((spans, keeps, raw), ([], [], []))
                self.assertEqual(audit["adProfileStatus"], "invalid")
                self.assertEqual(audit["adProfileRequestedDigest"], requested_digest)
                self.assertIsNone(audit["adProfileAppliedDigest"])

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

