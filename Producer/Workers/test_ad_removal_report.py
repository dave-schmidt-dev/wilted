"""The ad-removal entry point reports on every exit, or says why it cannot.

`detect_and_cut` used to have a protocol-less mode that cut audio without a
detector audit. That mode is retired: every caller now gets five values and,
for every run that actually analyzed or tried to analyze a transcript, a
serialized audit. These tests walk each exit through the public entry point so
a future change cannot quietly bring back a report-free path.
"""
from __future__ import annotations

import inspect
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit
from wilted_worker import ad_removal
from wilted_worker import transcript_sources
from wilted_worker.ad_audit import AdAnalysis
from wilted_worker.ad_audit import AdAnalysisAudit
from wilted_worker.ad_audit import HeldAdSpan
from wilted_worker.reporting import WorkerError
from worker_test_fake_ads import FakeAd
from worker_test_fake_ads import install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment
from worker_test_support import install_fake_wilted
from worker_test_support import synthetic_render
from worker_test_support import wp


class AdRemovalReportTests(unittest.TestCase):
    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory(prefix="wilted-ad-report-")
        self.addCleanup(self._scratch.cleanup)
        # Other suites install their own `wilted` doubles. Remember what was
        # loaded before this test and put it back afterwards, so these tests
        # leave the rest of the process exactly as they found it.
        self._wilted_modules = {
            name: module
            for name, module in sys.modules.items()
            if name == "wilted" or name.startswith("wilted.")
        }
        self.addCleanup(self._restore_wilted_modules)
        self.root = Path(self._scratch.name)
        self.audio = self.root / "source.mp3"
        self.audio.write_bytes(b"original audio")
        self.output = self.root / "prepared.mp3"
        self.request = {"audioPath": str(self.audio), "outputPath": str(self.output)}

    def _restore_wilted_modules(self):
        for name in [name for name in sys.modules if name == "wilted" or name.startswith("wilted.")]:
            if name not in self._wilted_modules:
                del sys.modules[name]
        sys.modules.update(self._wilted_modules)

    def run_detection(self, segments, *, llm=None, detections=(), duration=100.0,
                      analysis=None, break_contract=False):
        """Call the entry point with a synthetic source and no real ffmpeg."""
        llm = llm if llm is not None else FakeLLM()
        ads = install_fake_ads(llm, detections=detections)
        if break_contract:
            # `AuditingBackend` validates this archive seam at construction.
            ads._AD_DETECT_RESPONSE_FORMAT = None
        with redirect_stderr(io.StringIO()), synthetic_render(duration):
            if analysis is None:
                result = ad_removal.detect_and_cut(self.request, self.audio, [], segments)
            else:
                with mock.patch.object(
                    ad_removal, "analyze_ad_detections", return_value=analysis
                ):
                    result = ad_removal.detect_and_cut(self.request, self.audio, [], segments)
        return result, llm

    def assert_report_shape(self, result):
        """Assert the five-value contract and the two safe uncertain shapes."""
        self.assertEqual(len(result), 5)
        output_path, spans, keeps, nominations, audit = result
        self.assertIsInstance(audit, dict)
        if Path(output_path) != self.audio:
            # A cut is only allowed when the detector did not report doubt.
            self.assertIsNone(audit.get("warning"))
            self.assertIsNone(audit.get("incompleteError"))
        if audit.get("warning") is not None:
            # An uncertain run retains the whole original and cuts nothing.
            self.assertEqual(Path(output_path), self.audio)
            self.assertEqual(spans, [])
            self.assertEqual(keeps, [])
        return output_path, spans, keeps, nominations, audit

    def assert_uncertain(self, result):
        output_path, spans, keeps, _nominations, audit = self.assert_report_shape(result)
        self.assertEqual(Path(output_path), self.audio)
        self.assertEqual((spans, keeps), ([], []))
        self.assertIsNotNone(audit["warning"])
        self.assertTrue(audit["warning"].startswith("original audio includes ads:"))
        return audit

    def test_the_entry_point_no_longer_accepts_with_report(self):
        parameters = inspect.signature(ad_removal.detect_and_cut).parameters
        self.assertNotIn("with_report", parameters)
        self.assertIn("model_lock", parameters)

    def test_a_model_that_cannot_load_reports_an_uncertain_audit(self):
        result, llm = self.run_detection(
            [FakeSegment(0.0, 30.0, "programme cue")],
            llm=FakeLLM(fail_load=FileNotFoundError("missing GGUF")),
        )
        audit = self.assert_uncertain(result)
        self.assertIn("missing GGUF", audit["incompleteError"])
        self.assertTrue(llm.closed)

    def test_an_unavailable_classifier_contract_reports_an_uncertain_audit(self):
        result, _llm = self.run_detection(
            [FakeSegment(0.0, 30.0, "programme cue")],
            break_contract=True,
        )
        audit = self.assert_uncertain(result)
        self.assertIn("archived classifier contract unavailable", audit["incompleteError"])

    def test_a_classification_error_reports_an_uncertain_audit(self):
        result, _llm = self.run_detection(
            [FakeSegment(0.0, 30.0, "programme cue")],
            llm=FakeLLM(classifier_answer="invalid JSON"),
            duration=30.0,
        )
        audit = self.assert_uncertain(result)
        self.assertEqual(audit["unresolvedIds"], [0])
        self.assertIn("global IDs: 0", audit["incompleteError"])

    def test_an_unresolved_held_span_reports_an_uncertain_audit(self):
        analysis = AdAnalysis(
            detections=(FakeAd(40.0, 60.0, label="sponsor_read"),),
            audit=AdAnalysisAudit(
                held_spans=(HeldAdSpan(10.0, 30.0, "boundary-review-unresolved"),)
            ),
        )
        result, _llm = self.run_detection(
            [FakeSegment(0.0, 100.0, "programme cue")], analysis=analysis
        )
        audit = self.assert_uncertain(result)
        self.assertIn("could not safely resolve", audit["incompleteError"])
        self.assertEqual(audit["heldSpans"][0]["reason"], "boundary-review-unresolved")

    def test_no_detections_reports_a_clean_audit(self):
        segments = [
            FakeSegment(0.0, 50.0, "programme one"),
            FakeSegment(50.0, 100.0, "programme two"),
        ]
        result, _llm = self.run_detection(segments)
        output_path, spans, keeps, nominations, audit = self.assert_report_shape(result)
        self.assertEqual(Path(output_path), self.audio)
        self.assertEqual((spans, keeps, nominations), ([], [], []))
        self.assertIsNone(audit["warning"])
        self.assertIsNone(audit["incompleteError"])

    def test_cut_planning_refuses_unsafe_timing_with_an_uncertain_audit(self):
        analysis = AdAnalysis(
            detections=(FakeAd(110.0, 120.0, label="sponsor_read"),),
            audit=AdAnalysisAudit(),
        )
        result, _llm = self.run_detection(
            [FakeSegment(0.0, 100.0, "programme cue")],
            analysis=analysis,
            duration=100.0,
        )
        audit = self.assert_uncertain(result)
        self.assertIn("ad cut unsafe", audit["incompleteError"])
        self.assertEqual(len(result[3]), 1)

    def test_an_all_advertisement_result_is_refused_with_an_uncertain_audit(self):
        analysis = AdAnalysis(
            detections=(FakeAd(0.0, 100.0, label="sponsor_read"),),
            audit=AdAnalysisAudit(),
        )
        result, _llm = self.run_detection(
            [FakeSegment(0.0, 100.0, "programme cue")],
            analysis=analysis,
            duration=100.0,
        )
        audit = self.assert_uncertain(result)
        self.assertIn("every span was classified as an advertisement", audit["incompleteError"])
        self.assertEqual(len(result[3]), 1)

    def test_a_successful_cut_reports_a_clean_audit(self):
        segments = [
            FakeSegment(0.0, 50.0, "programme one"),
            FakeSegment(50.0, 100.0, "programme two"),
        ]
        result, _llm = self.run_detection(
            segments,
            detections=[FakeAd(10.0, 20.0, label="sponsor_read")],
            duration=100.0,
        )
        output_path, spans, keeps, nominations, audit = self.assert_report_shape(result)
        self.assertNotEqual(Path(output_path), self.audio)
        self.assertTrue(Path(output_path).exists())
        self.assertEqual(
            [(span["startSeconds"], span["endSeconds"]) for span in spans],
            [(10.0, 20.0)],
        )
        self.assertEqual(
            [(keep.start_s, keep.end_s) for keep in keeps],
            [(0.0, 10.0), (20.0, 100.0)],
        )
        self.assertEqual(nominations, spans)
        self.assertIsNone(audit["warning"])
        self.assertIsNone(audit["incompleteError"])

    def test_empty_segments_are_the_only_none_audit(self):
        # The entry point imports the archive before its empty-segment
        # shortcut, so even this exit needs the doubles installed.
        install_fake_ads(FakeLLM())
        result = ad_removal.detect_and_cut(self.request, self.audio, [], [])
        self.assertEqual(result, (self.audio, [], [], [], None))

    def test_a_protocol_less_removal_request_is_refused_before_any_work(self):
        request = dict(self.request)
        with mock.patch.object(
            ad_audit, "preflight_ad_removal",
            side_effect=AssertionError("protocol check ran preflight"),
        ) as preflight, mock.patch.object(
            transcript_sources, "transcribe_with_daemon",
            side_effect=AssertionError("protocol check started transcription"),
        ) as transcribe, mock.patch.object(
            ad_removal, "detect_and_cut",
            side_effect=AssertionError("protocol check started ad detection"),
        ) as detect, redirect_stderr(io.StringIO()), synthetic_render(4.0):
            with self.assertRaises(WorkerError) as raised:
                wp.run({**request, "removeAds": True})
            self.assertEqual(raised.exception.code, "protocol-version-required")
            self.assertEqual(
                [preflight.called, transcribe.called, detect.called],
                [False, False, False],
            )

            # The same request may still ask only for a transcript.
            install_fake_wilted({
                "vtt": [FakeSegment(0, 2, "hello"), FakeSegment(2, 4, "world")],
            })
            result = wp.run({
                **request,
                "removeAds": False,
                "allowSpeechToText": False,
                "publishedTranscript": {
                    "body": "WEBVTT",
                    "mediaType": "text/vtt",
                    "url": "https://x.test/a.vtt",
                    "languageCode": "en",
                },
            })
            self.assertEqual(
                [preflight.called, transcribe.called, detect.called],
                [False, False, False],
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["timing"], "published")
        self.assertEqual(result["text"], "hello world")
        self.assertEqual(result["languageCode"], "en")
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["audioPath"], str(self.audio))


if __name__ == "__main__":
    unittest.main()
