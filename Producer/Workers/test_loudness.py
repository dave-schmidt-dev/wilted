"""Tests for opt-in loudness normalization against real ffmpeg measurements."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path
from unittest import mock

from wilted_worker import cue_timing, loudness
from wilted_worker import loudness as _worker_loudness
from worker_test_support import FakeSegment, install_fake_wilted, wp


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
class LoudnessTests(unittest.TestCase):
    def test_quiet_and_loud_inputs_reach_the_same_integrated_target(self):
        with tempfile.TemporaryDirectory(prefix="wilted-loudness-") as scratch:
            root = Path(scratch)
            results = []
            for name, gain in (("quiet", "-35dB"), ("loud", "-14dB")):
                source = root / f"{name}.mp3"
                output = root / f"{name}-levelled.mp3"
                subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
                     "sine=frequency=440:duration=10", "-af", f"volume={gain}",
                     "-c:a", "libmp3lame", "-q:a", "3", str(source)],
                    check=True, timeout=30,
                )
                before_duration = cue_timing.probe_duration(source)
                metrics, skipped = loudness.normalize(source, output)
                self.assertIsNone(skipped)
                self.assertIsNotNone(metrics)
                measured_i, measured_tp = loudness.measure(output)
                after_duration = cue_timing.probe_duration(output)
                self.assertLessEqual(abs(measured_i - loudness.TARGET_I), 1.0)
                self.assertLessEqual(measured_tp, loudness.TARGET_TP + 0.1)
                self.assertLessEqual(abs(before_duration - after_duration), 0.05)
                self.assertEqual(metrics["outputIntegratedLufs"], round(measured_i, 2))
                results.append(measured_i)
            self.assertLessEqual(abs(results[0] - results[1]), 1.0)

    def test_voice_level_filter_reduces_a_quiet_guest_loud_host_difference(self):
        with tempfile.TemporaryDirectory(prefix="wilted-two-level-") as scratch:
            root = Path(scratch)
            source, output = root / "two-level.mp3", root / "two-level-normalized.mp3"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
                 "-f", "lavfi", "-i", "sine=frequency=660:duration=10", "-filter_complex",
                 "[0:a]volume=-35dB[quiet];[1:a]volume=-14dB[loud];[quiet][loud]concat=n=2:v=0:a=1[out]",
                 "-map", "[out]", "-c:a", "libmp3lame", "-q:a", "3", str(source)],
                check=True, timeout=30,
            )

            def segment_loudness(path: Path, start: int) -> float:
                segment = root / f"segment-{path.stem}-{start}.mp3"
                subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-ss", str(start), "-i", str(path), "-t", "10",
                     "-c:a", "libmp3lame", "-q:a", "3", str(segment)],
                    check=True, timeout=30,
                )
                return loudness.measure(segment)[0]

            before = [segment_loudness(source, start) for start in (0, 10)]
            metrics, skipped = loudness.normalize(source, output)
            self.assertIsNone(skipped)
            self.assertIsNotNone(metrics)
            after = [segment_loudness(output, start) for start in (0, 10)]
            self.assertGreater(abs(before[1] - before[0]), 15.0)
            self.assertGreaterEqual(abs(before[1] - before[0]) - abs(after[1] - after[0]), 6.0)
            self.assertLessEqual(abs(loudness.measure(output)[0] - loudness.TARGET_I), 1.0)

    def test_unmeasurable_or_unsupported_source_is_skipped_without_replacing_it(self):
        with tempfile.TemporaryDirectory(prefix="wilted-loudness-skip-") as scratch:
            root = Path(scratch)
            source, output = root / "silent.wav", root / "prepared.mp3"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                 "-t", "2", str(source)],
                check=True, timeout=30,
            )
            original = source.read_bytes()
            metrics, reason = loudness.normalize(source, output)
            self.assertIsNone(metrics)
            self.assertEqual(reason, "loudness-measure-failed")
            self.assertEqual(source.read_bytes(), original)
            self.assertFalse(output.exists())
            metrics, reason = loudness.normalize(source, root / "prepared.unsupported")
            self.assertIsNone(metrics)
            self.assertEqual(reason, "cut-container-unsupported")
            self.assertEqual(source.read_bytes(), original)

    def test_opted_in_silent_episode_stays_playable_and_reports_skipped_leveling(self):
        with tempfile.TemporaryDirectory(prefix="wilted-silent-worker-") as scratch:
            root = Path(scratch)
            source, output = root / "silent.wav", root / "prepared.mp3"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                 "-t", "2", str(source)],
                check=True, timeout=30,
            )
            original = source.read_bytes()
            install_fake_wilted()
            result = wp.run({
                "protocolVersion": 2, "audioPath": str(source), "outputPath": str(output),
                "removeAds": False, "allowSpeechToText": False, "evenOutVoiceLoudness": True,
            })
            self.assertFalse(result["audioChanged"])
            self.assertEqual(result["audioPath"], str(source))
            self.assertEqual(result["audioLoudnessSkippedReason"], "loudness-measure-failed")
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), original)

    def test_worker_opt_in_renders_full_identity_map_without_moving_transcript_cues(self):
        with tempfile.TemporaryDirectory(prefix="wilted-worker-level-") as scratch:
            root = Path(scratch)
            source, output = root / "source.mp3", root / "prepared.mp3"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
                 "-c:a", "libmp3lame", "-q:a", "3", str(source)],
                check=True, timeout=30,
            )
            install_fake_wilted({"vtt": [FakeSegment(1, 2, "quiet guest"), FakeSegment(3, 4, "host")]})
            body_hash = sha256(source.read_bytes()).digest()
            request = {
                "protocolVersion": 2, "audioPath": str(source), "outputPath": str(output),
                "removeAds": False, "allowSpeechToText": False,
                "publishedTranscript": {
                    "body": "WEBVTT" + chr(10) + chr(10)
                            + "00:00:01.000 --> 00:00:02.000" + chr(10) + "quiet guest" + chr(10) + chr(10)
                            + "00:00:03.000 --> 00:00:04.000" + chr(10) + "host" + chr(10),
                    "mediaType": "text/vtt", "url": "https://example.test/show.vtt",
                },
            }
            with mock.patch.object(_worker_loudness, "normalize", side_effect=AssertionError("off switch rendered")) as normalize_mock:
                unchanged = wp.run(request)
            normalize_mock.assert_not_called()
            self.assertFalse(unchanged["audioChanged"])
            self.assertEqual(unchanged["audioPath"], str(source))
            self.assertEqual(sha256(source.read_bytes()).digest(), body_hash)

            request["evenOutVoiceLoudness"] = True
            output.write_bytes(b"stale render from a cancelled preparation")
            result = wp.run(request)
            self.assertTrue(result["audioChanged"])
            self.assertEqual(result["audioPath"], str(output))
            self.assertEqual([cue["text"] for cue in result["cues"]], ["quiet guest", "host"])
            self.assertEqual([(cue["startSeconds"], cue["endSeconds"]) for cue in result["cues"]],
                             [(1.0, 2.0), (3.0, 4.0)])
            self.assertEqual(result["keepIntervals"], [
                {"startSeconds": 0.0, "endSeconds": 6.0, "outputStartSeconds": 0.0}
            ])
            self.assertLessEqual(abs(cue_timing.probe_duration(source) - cue_timing.probe_duration(output)), 0.05)


if __name__ == "__main__":
    unittest.main()
