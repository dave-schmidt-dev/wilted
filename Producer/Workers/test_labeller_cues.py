"""Labeller cue export tests."""
from __future__ import annotations
import hashlib
import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from wilted_worker import labeller_cues as _worker_labeller_cues
from worker_test_support import *

class BuildLabellerCuesTests(unittest.TestCase):
    def test_cues_are_0_based_ordered_rounded_and_stripped(self):
        segments = [
            FakeSegment(0.0, 2.5, " first words "),
            FakeSegment(2.5, 5.0004, "second words"),
            FakeSegment(6.0, 9.0, "third words"),
        ]
        self.assertEqual(_worker_labeller_cues.build_labeller_cues(segments), [
            {"id": 0, "start": 0.0, "end": 2.5, "text": "first words"},
            {"id": 1, "start": 2.5, "end": 5.0, "text": "second words"},
            {"id": 2, "start": 6.0, "end": 9.0, "text": "third words"},
        ])

    def test_serialization_is_canonical_utf8_and_sha256_hashed(self):
        cues = _worker_labeller_cues.build_labeller_cues([FakeSegment(0.0, 1.0, "café")])
        payload, digest = _worker_labeller_cues.serialize_labeller_cues(cues)
        self.assertEqual(payload, '[{"end":1.0,"id":0,"start":0.0,"text":"café"}]'.encode("utf-8"))
        self.assertEqual(digest, hashlib.sha256(payload).hexdigest())

class LabellerCuesExportTests(unittest.TestCase):
    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.work_dir = tempfile.mkdtemp(prefix="wilted-labeller-cues-")
        self.addCleanup(shutil.rmtree, self.work_dir, ignore_errors=True)

    def aligned_request(self, **overrides):
        request = {
            "audioPath": str(self.audio), "removeAds": False,
            "transcriptPolicy": "alwaysTranscribe", "workDir": self.work_dir,
        }
        request.update(overrides)
        return request

    def install_aligned_segments(self):
        install_fake_wilted(transcriptions={
            wp.ALIGNED_STT_MODEL: [
                FakeSegment(0.0, 2.5, " first words "),
                FakeSegment(2.5, 5.25, "second words"),
            ]
        })

    def test_the_cue_file_content_equals_the_aligned_segments(self):
        self.install_aligned_segments()
        with redirect_stderr(io.StringIO()):
            result = wp.run(self.aligned_request(emitLabellerCues=True))
        self.assertTrue(result["ok"])
        self.assertEqual(result["timing"], "aligned")
        path = Path(result["labellerCuesPath"])
        self.assertEqual(path, Path(self.work_dir) / "wilted-pipeline" / "labeller-cues.json")
        cues = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(cues, [
            {"id": 0, "start": 0.0, "end": 2.5, "text": "first words"},
            {"id": 1, "start": 2.5, "end": 5.25, "text": "second words"},
        ])
        self.assertEqual([cue["id"] for cue in cues], [0, 1])

    def test_the_returned_digest_is_recomputed_from_the_file_bytes(self):
        self.install_aligned_segments()
        with redirect_stderr(io.StringIO()):
            result = wp.run(self.aligned_request(emitLabellerCues=True))
        file_bytes = Path(result["labellerCuesPath"]).read_bytes()
        self.assertEqual(result["labellerCuesDigest"], hashlib.sha256(file_bytes).hexdigest())

    def test_a_request_without_the_flag_produces_no_cue_fields(self):
        for flag in (None, False):
            with self.subTest(flag=flag):
                self.install_aligned_segments()
                overrides = {"workDir": self.work_dir}
                if flag is not None:
                    overrides["emitLabellerCues"] = flag
                with redirect_stderr(io.StringIO()):
                    result = wp.run(self.aligned_request(**overrides))
                self.assertTrue(result["ok"])
                self.assertNotIn("labellerCuesPath", result)
                self.assertNotIn("labellerCuesDigest", result)
                self.assertFalse((Path(self.work_dir) / "wilted-pipeline" / "labeller-cues.json").exists())

    def test_the_flag_without_aligned_segments_writes_nothing(self):
        install_fake_wilted({"vtt": [FakeSegment(0, 2, "published words")]})
        with redirect_stderr(io.StringIO()):
            result = wp.run({
                "audioPath": str(self.audio), "removeAds": False, "emitLabellerCues": True,
                "workDir": self.work_dir,
                "publishedTranscript": {"body": "WEBVTT", "mediaType": "text/vtt",
                                        "url": "https://x.test/a.vtt"},
            })
        self.assertEqual(result["timing"], "published")
        self.assertNotIn("labellerCuesPath", result)
        self.assertNotIn("labellerCuesDigest", result)
        self.assertFalse((Path(self.work_dir) / "wilted-pipeline" / "labeller-cues.json").exists())

if __name__ == "__main__":
    unittest.main()
