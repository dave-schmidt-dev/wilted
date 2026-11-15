"""The labelled cut reports on every exit, or says why it cannot.

The labelled cut has no report-free path: a run that analyzed a transcript
returns a serialized audit, and only a run with no segments returns none. A
stage request without protocol version 2 is refused before any work starts.
"""
from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import labelled_outcome
from wilted_worker import transcript_sources
from wilted_worker.reporting import WorkerError
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

    def test_empty_segments_are_the_only_none_audit(self):
        result = labelled_outcome.cut_from_labelled_breaks(self.request, self.audio, [], [])
        self.assertEqual(result, (self.audio, [], [], [], None))

    def test_a_protocol_less_stage_request_is_refused_before_any_work(self):
        request = dict(self.request)
        with mock.patch.object(
            transcript_sources, "transcribe_with_daemon",
            side_effect=AssertionError("protocol check started transcription"),
        ) as transcribe, mock.patch.object(
            labelled_outcome, "cut_from_labelled_breaks",
            side_effect=AssertionError("protocol check started the cut"),
        ) as cut, redirect_stderr(io.StringIO()), synthetic_render(4.0):
            for stage in ("transcript", "cut"):
                with self.subTest(stage=stage):
                    with self.assertRaises(WorkerError) as raised:
                        wp.run({**request, "adStage": stage, "removeAds": stage == "cut"})
                    self.assertEqual(raised.exception.code, "protocol-version-required")
                    self.assertEqual([transcribe.called, cut.called], [False, False])

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
            self.assertEqual([transcribe.called, cut.called], [False, False])

        self.assertTrue(result["ok"])
        self.assertEqual(result["timing"], "published")
        self.assertEqual(result["text"], "hello world")
        self.assertEqual(result["languageCode"], "en")
        self.assertFalse(result["audioChanged"])
        self.assertEqual(result["audioPath"], str(self.audio))


if __name__ == "__main__":
    unittest.main()
