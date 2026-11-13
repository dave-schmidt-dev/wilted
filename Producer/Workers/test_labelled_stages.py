"""Integration tests for transcript and cut adStage worker paths."""
from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import labeller_cues as _worker_labeller_cues
from wilted_worker.reporting import WorkerError
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, install_fake_wilted, synthetic_render, wp
from test_silence_trim import AD_KEEPS, AD_SEGMENTS, AD_SILENCES, run_preparation, silence_report, spans


class LabelledStagesTestCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="wilted-labelled-stages-")
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)
        self.audio = self.directory / "source.mp3"
        self.audio.write_bytes(b"original audio")
        self.segments = [
            FakeSegment(0.0, 18.0, "programme opening"),
            FakeSegment(20.0, 40.0, "sponsor read"),
            FakeSegment(41.0, 50.0, "programme middle"),
            FakeSegment(52.0, 57.0, "programme close"),
        ]
        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: self.segments})

    def digest_for(self, segments=None):
        cues = _worker_labeller_cues.build_labeller_cues(segments or self.segments)
        return _worker_labeller_cues.serialize_labeller_cues(cues)[1]

    def cut_request(self, breaks, **overrides):
        request = {
            "protocolVersion": 2,
            "adStage": "cut",
            "audioPath": str(self.audio),
            "outputPath": str(self.directory / "prepared.mp3"),
            "removeAds": True,
            "labelledBreaks": breaks,
            "labellerCuesDigest": self.digest_for(),
            "labellerModelID": "deepseek-v4.1-flash",
            "labellerLevel": "low",
            "labellerPromptVersion": "labeller-prompt-v1",
            "workDir": str(self.directory),
        }
        request.update(overrides)
        return request

    def run_cut(self, breaks, duration=60.0, silences=None, **overrides):
        with contextlib.ExitStack() as stack:
            stack.enter_context(redirect_stderr(io.StringIO()))
            stack.enter_context(synthetic_render(duration, silence_report(silences or [])))
            return wp.run(self.cut_request(breaks, **overrides))


class TranscriptStageTests(LabelledStagesTestCase):
    def test_transcript_stage_returns_cue_path_and_digest_without_cutting(self):
        with mock.patch.object(_worker_ad_removal, "detect_and_cut") as detect, \
                mock.patch.object(_worker_ad_audit, "preflight_ad_removal") as preflight, \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock") as lock, \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=57.0), \
                redirect_stderr(io.StringIO()):
            result = wp.run({
                "protocolVersion": 2,
                "adStage": "transcript",
                "audioPath": str(self.audio),
                "workDir": str(self.directory),
                "transcriptPolicy": "alwaysTranscribe",
            })
        self.assertTrue(result["ok"])
        self.assertEqual(result["adStage"], "transcript")
        self.assertEqual(result["timing"], "aligned")
        self.assertEqual(result["labellerCuesDigest"], self.digest_for())
        self.assertEqual(
            Path(result["labellerCuesPath"]),
            self.directory / "wilted-pipeline" / "labeller-cues.json",
        )
        self.assertTrue(Path(result["labellerCuesPath"]).is_file())
        self.assertNotIn("adSegments", result)
        self.assertNotIn("keepIntervals", result)
        self.assertNotIn("report", result)
        detect.assert_not_called()
        preflight.assert_not_called()
        lock.assert_not_called()


class CutStageTests(LabelledStagesTestCase):
    def test_cut_stage_cuts_labelled_must_cut_breaks(self):
        result = self.run_cut([
            {"start": 20.0, "end": 40.0, "kind": "sponsor", "label": "must-cut", "advertisers": ["Acme"]},
        ])
        self.assertTrue(result["ok"])
        self.assertEqual(result["adStage"], "cut")
        self.assertEqual(result["report"]["outcome"], "cut")
        self.assertEqual(spans(result["adSegments"]), [(20.0, 40.0)])
        self.assertEqual(result["report"]["audit"]["adEngine"], "labelled")
        self.assertEqual(result["report"]["audit"]["breaksCut"], 1)
        self.assertEqual(result["report"]["audit"]["labellerModelID"], "deepseek-v4.1-flash")

    def test_digest_mismatch_returns_labelled_cues_mismatch(self):
        with redirect_stderr(io.StringIO()), \
                synthetic_render(60.0), \
                self.assertRaises(WorkerError) as raised:
            wp.run(self.cut_request(
                [{"start": 20.0, "end": 40.0, "kind": "sponsor", "label": "must-cut", "advertisers": []}],
                labellerCuesDigest="0" * 64,
            ))
        self.assertEqual(raised.exception.code, "labelled-cues-mismatch")

    def test_cut_stage_makes_zero_local_model_calls(self):
        def boom(*_args, **_kwargs):
            raise AssertionError("local model path must not run")

        install_fake_ads(FakeLLM())
        import wilted.llm as llm_module
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal", side_effect=boom), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", side_effect=boom), \
                mock.patch.object(llm_module, "create_backend", side_effect=boom), \
                mock.patch.object(_worker_ad_removal, "analyze_ad_detections", side_effect=boom), \
                redirect_stderr(io.StringIO()), \
                synthetic_render(60.0):
            result = wp.run(self.cut_request([
                {"start": 20.0, "end": 40.0, "kind": "sponsor", "label": "must-cut", "advertisers": []},
            ]))
        self.assertEqual(result["report"]["outcome"], "cut")
        self.assertEqual(result["report"]["audit"]["adEngine"], "labelled")

    def test_absent_ad_stage_matches_silence_trim_fixture_spans(self):
        install_fake_ads(FakeLLM())
        with redirect_stderr(io.StringIO()):
            result = run_preparation(
                self.directory,
                AD_SEGMENTS,
                60.0,
                AD_SILENCES,
                detections=[FakeAd(20.0, 40.0, label="sponsor_read")],
            )
        self.assertEqual(result["report"]["outcome"], "cut")
        self.assertEqual(spans(result["adSegments"]), [(20.0, 40.0)])
        self.assertEqual(spans(result["keepIntervals"]), AD_KEEPS)
        self.assertNotIn("adStage", result)


if __name__ == "__main__":
    unittest.main()
