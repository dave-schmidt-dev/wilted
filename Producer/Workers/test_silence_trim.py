"""Tests for shortening long pauses in prepared audio."""
from __future__ import annotations

import contextlib
import io
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import silence_trim
from wilted_worker.ad_audit import AdAnalysis, AdAnalysisAudit
from wilted_worker.constants import SILENCE_DETECT_TIMEOUT_S, SILENCE_MAX_KEEP_INTERVALS
from wilted_worker.cue_timing import build_keep_map, serialize_keep_map
from wilted_worker.reporting import WorkerError
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, install_fake_wilted, synthetic_render, wp

# Four one-second tone bursts: 1.5 s of silence before them, 2 s between them
# and 5 s after them.
BURST_LAYOUT = [(1.5, False), (1.0, True), (2.0, False), (1.0, True), (2.0, False),
                (1.0, True), (2.0, False), (1.0, True), (5.0, False)]
BURST_SILENCES = [(0.0, 1.5), (2.5, 4.5), (5.5, 7.5), (8.5, 10.5), (11.5, 16.5)]
BURST_SEGMENTS = [FakeSegment(1.5, 2.5, "one"), FakeSegment(4.5, 5.5, "two"),
                  FakeSegment(7.5, 8.5, "three"), FakeSegment(10.5, 11.5, "four")]
# Each 2 s gap keeps 0.25 s on each side; the lead and the tail go entirely.
BURST_KEEPS = [(1.5, 2.75), (4.25, 5.75), (7.25, 8.75), (10.25, 11.5)]

# A 60 s episode with one ad at 20-40 s. The pause either side of the ad
# becomes one 3 s pause once the ad is cut, so it is trimmed as one.
AD_SEGMENTS = [FakeSegment(0.0, 18.0, "programme opening"), FakeSegment(20.0, 40.0, "sponsor read"),
               FakeSegment(41.0, 50.0, "programme middle"), FakeSegment(52.0, 57.0, "programme close")]
AD_SILENCES = [(18.0, 20.0), (40.0, 41.0), (50.0, 52.0), (57.0, 60.0)]
AD_KEEPS = [(0.0, 18.25), (40.75, 50.25), (51.75, 57.0)]


def silence_report(spans) -> str:
    """The stderr ``silencedetect`` prints for ``spans``."""
    lines = []
    for start, end in spans:
        lines.append(f"[silencedetect @ 0x1] silence_start: {start:g}")
        lines.append(f"[silencedetect @ 0x1] silence_end: {end:g} | silence_duration: {end - start:g}")
    return "\n".join(lines) + "\n"


def write_bursts(path: Path, layout, rate: int = 16000) -> None:
    """Write a mono WAV of 440 Hz tone and digital silence."""
    frames = bytearray()
    for seconds, tone in layout:
        for sample in range(round(seconds * rate)):
            value = int(16000 * math.sin(2 * math.pi * 440 * sample / rate)) if tone else 0
            frames += struct.pack("<h", value)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(bytes(frames))


def run_preparation(directory, segments, duration, silences, *, detections=None, stderr=None):
    """Run the real worker with fake models, a fake ffmpeg and ``silences``."""
    audio = Path(directory) / "source.mp3"
    audio.write_bytes(b"original audio")
    install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: segments})
    install_fake_ads(FakeLLM())
    request = {"protocolVersion": 2, "audioPath": str(audio), "outputPath": str(Path(directory) / "prepared.mp3"),
               "removeAds": True, "readableTranscript": False}
    with contextlib.ExitStack() as stack:
        stack.enter_context(redirect_stderr(stderr if stderr is not None else io.StringIO()))
        stack.enter_context(synthetic_render(duration, silence_report(silences)))
        stack.enter_context(mock.patch.object(_worker_ad_audit, "preflight_ad_removal"))
        stack.enter_context(mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock",
                                              return_value=contextlib.nullcontext()))
        if detections is not None:
            audit = AdAnalysisAudit(classifier_requests=4, classifier_valid_requests=4, model_requests=4)
            stack.enter_context(mock.patch.object(_worker_ad_removal, "analyze_ad_detections",
                                                  return_value=AdAnalysis(detections=tuple(detections), audit=audit)))
        return wp.run(request)


def silence_contract_payloads():
    """Real worker results with trimmed silence, for the Swift decoder's contract test."""
    results = []
    for name, segments, duration, silences, detections in (
        ("silence-only", BURST_SEGMENTS, 16.5, BURST_SILENCES, None),
        ("ads-and-silence", AD_SEGMENTS, 60.0, AD_SILENCES, [FakeAd(20.0, 40.0, label="sponsor_read")]),
    ):
        with tempfile.TemporaryDirectory(prefix="wilted-silence-contract-") as directory:
            payload = run_preparation(directory, segments, duration, silences, detections=detections)
        results.append({"scenario": name, "payload": payload})
    return results


def spans(intervals) -> list[tuple[float, float]]:
    return [(interval["startSeconds"], interval["endSeconds"]) for interval in intervals]


class SilenceTrimTestCase(unittest.TestCase):
    def setUp(self):
        # Other suites install their own `wilted` doubles; put them back.
        saved = {name: module for name, module in sys.modules.items()
                 if name == "wilted" or name.startswith("wilted.")}

        def restore():
            for name in [name for name in sys.modules if name == "wilted" or name.startswith("wilted.")]:
                if name not in saved:
                    del sys.modules[name]
            sys.modules.update(saved)

        self.addCleanup(restore)
        scratch = tempfile.TemporaryDirectory(prefix="wilted-silence-")
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)


class SilencePlanTests(SilenceTrimTestCase):
    def test_gaps_shrink_to_half_a_second_and_the_lead_and_tail_go(self):
        keeps = silence_trim.plan_trims(build_keep_map([(0.0, 16.5)]), BURST_SILENCES)
        self.assertEqual([(keep.start_s, keep.end_s) for keep in keeps], BURST_KEEPS)
        self.assertAlmostEqual(sum(keep.duration_s for keep in keeps), 5.5)

    def test_short_pauses_and_a_quiet_map_are_left_alone(self):
        whole = build_keep_map([(0.0, 30.0)])
        self.assertIs(silence_trim.plan_trims(whole, []), whole)
        self.assertIs(silence_trim.plan_trims(whole, [(10.0, 10.5)]), whole)

    def test_every_interior_pause_over_half_a_second_is_trimmed_within_the_map_budget(self):
        for duration in (0.5001, 0.51, 0.55, 0.6):
            with self.subTest(duration=duration):
                whole = build_keep_map([(0.0, 30.0)])
                keeps = silence_trim.plan_trims(whole, [(10.0, 10.0 + duration)])
                self.assertEqual(len(keeps), 2)
                self.assertAlmostEqual(keeps[0].end_s, 10.25)
                self.assertAlmostEqual(keeps[1].start_s, 10.0 + duration - 0.25)
                self.assertAlmostEqual(sum(keep.duration_s for keep in keeps), 30.0 - duration + 0.5)

    def test_a_pause_split_by_an_ad_cut_is_measured_whole(self):
        keeps = silence_trim.plan_trims(build_keep_map([(0.0, 20.0), (40.0, 60.0)]), AD_SILENCES)
        self.assertEqual([(keep.start_s, keep.end_s) for keep in keeps], AD_KEEPS)

    def test_the_keep_count_stays_under_the_mac_limit_taking_the_longest_pauses(self):
        silences = [(3.0 + 5.0 * index, 3.7 + 5.0 * index + index * 0.0001) for index in range(2000)]
        keeps = silence_trim.plan_trims(build_keep_map([(0.0, 10_005.0)]), silences)
        self.assertEqual(len(keeps), SILENCE_MAX_KEEP_INTERVALS)
        self.assertLessEqual(len(serialize_keep_map(keeps)), 512)
        trimmed = {round(previous.end_s - 0.25, 6) for previous in keeps[:-1]}
        self.assertEqual(trimmed, {round(start, 6) for start, _end in silences[-(SILENCE_MAX_KEEP_INTERVALS - 1):]})

    def test_trimming_everything_keeps_the_untrimmed_map(self):
        whole = build_keep_map([(0.0, 8.0)])
        stream = io.StringIO()
        with redirect_stderr(stream), \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress",
                                  return_value=silence_report([(0.0, 8.0)])):
            self.assertIs(silence_trim.trimmed_keeps(Path("source.mp3"), whole), whole)
        self.assertIn("would leave no audio", stream.getvalue())

    def test_the_report_parser_clamps_to_the_source_and_closes_an_open_silence(self):
        report = ("silence_start: -0.002\nsilence_end: 1.5 | silence_duration: 1.502\n"
                  "silence_start: 3.25e+00\nsilence_end: 9.9 | silence_duration: 6.65\n"
                  "silence_start: 12\n")
        self.assertEqual(silence_trim.parse_silences(report, 9.0), [(0.0, 1.5), (3.25, 9.0)])
        self.assertEqual(silence_trim.parse_silences(report, 15.0), [(0.0, 1.5), (3.25, 9.9), (12.0, 15.0)])

    def test_detection_is_one_bounded_pass_with_its_own_heartbeat(self):
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress", return_value="") as runner:
            self.assertEqual(silence_trim.detect_silences(Path("source.mp3"), 10.0), [])
        runner.assert_called_once()
        command = runner.call_args.args[0]
        self.assertIn("silencedetect=noise=-50dB:d=0.25", command)
        self.assertEqual(runner.call_args.kwargs, {"timeout_s": SILENCE_DETECT_TIMEOUT_S,
                                                   "stage": "audio.silence.detect.progress"})


class SilenceFallbackTests(SilenceTrimTestCase):
    def test_a_failed_detection_keeps_the_map_and_warns_without_ffmpeg_output(self):
        keeps = build_keep_map([(0.0, 20.0), (40.0, 60.0)])
        for error, reason in ((WorkerError("cut-render-failed", "ffmpeg exited 1: /Users/x/secret.mp3"),
                               "cut-render-failed"),
                              (WorkerError("cut-render-timeout", "ffmpeg exceeded its 900s limit"), "cut-render-timeout"),
                              (FileNotFoundError("/opt/ffmpeg"), "FileNotFoundError")):
            with self.subTest(reason), redirect_stderr(io.StringIO()) as stream, \
                    mock.patch.object(_worker_cue_timing, "_run_render_with_progress", side_effect=error):
                self.assertIs(silence_trim.trimmed_keeps(Path("source.mp3"), keeps), keeps)
            records = [json.loads(line) for line in stream.getvalue().splitlines()]
            skipped = [record["detail"] for record in records if record["stage"] == "audio.silence.skipped"]
            self.assertEqual(skipped, [f"warning: silence not trimmed, detection failed: {reason}"])
            self.assertNotIn("secret", stream.getvalue())

    def test_a_failed_silence_only_render_returns_the_original(self):
        audio = self.directory / "source.mp3"
        audio.write_bytes(b"original audio")
        with redirect_stderr(io.StringIO()) as stream, \
                mock.patch.object(_worker_cue_timing, "_run_render_with_progress",
                                  return_value=silence_report(BURST_SILENCES)), \
                mock.patch.object(_worker_cue_timing, "render_keep_segments",
                                  side_effect=WorkerError("cut-duration-mismatch", "rendered 1s")):
            result = silence_trim.trim_unedited(audio, self.directory / "prepared.mp3", 16.5)
        self.assertEqual(result, (audio, []))
        self.assertIn("render failed: cut-duration-mismatch", stream.getvalue())

    def test_a_container_the_cut_cannot_write_is_left_alone(self):
        audio = self.directory / "source.ogg"
        audio.write_bytes(b"original audio")
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(silence_trim, "detect_silences") as detect:
            result = silence_trim.trim_unedited(audio, self.directory / "prepared.ogg", 16.5)
        self.assertEqual(result, (audio, []))
        detect.assert_not_called()

    def test_a_detection_failure_never_fails_the_episode(self):
        with mock.patch.object(silence_trim, "detect_silences", side_effect=RuntimeError("decoder crashed")):
            result = run_preparation(self.directory, BURST_SEGMENTS, 16.5, [])
        self.assertTrue(result["ok"])
        self.assertEqual(result["report"]["outcome"], "noAds")
        self.assertFalse(result["audioChanged"])
        self.assertEqual((result["keepIntervals"], result["silenceTrims"]), ([], []))

    def test_uncertain_and_disabled_preparations_are_never_trimmed(self):
        warning = "original audio includes ads: model missing"
        uncertain = wp.serialize_ad_audit(AdAnalysisAudit(incomplete_error="model missing", warning=warning))
        source = self.directory / "source.mp3"
        with mock.patch.object(silence_trim, "detect_silences") as detect, \
                mock.patch.object(_worker_ad_removal, "detect_and_cut",
                                  return_value=(source, [], [], [], uncertain)):
            result = run_preparation(self.directory, BURST_SEGMENTS, 16.5, BURST_SILENCES)
            self.assertEqual(result["report"]["outcome"], "uncertain")
            install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: BURST_SEGMENTS})
            with redirect_stderr(io.StringIO()), synthetic_render(16.5, silence_report(BURST_SILENCES)):
                disabled = wp.run({"audioPath": result["audioPath"], "removeAds": False})
        detect.assert_not_called()
        self.assertEqual(disabled["report"]["outcome"], "disabled")
        for payload in (result, disabled):
            self.assertFalse(payload["audioChanged"])
            self.assertEqual((payload["keepIntervals"], payload["silenceTrims"]), ([], []))


class SilenceResultTests(SilenceTrimTestCase):
    def test_a_clean_episode_reports_its_trims_and_moves_its_cues(self):
        stream = io.StringIO()
        result = run_preparation(self.directory, BURST_SEGMENTS, 16.5, BURST_SILENCES, stderr=stream)
        self.assertEqual(result["report"]["outcome"], "noAds")
        self.assertTrue(result["audioChanged"])
        self.assertEqual((result["adSegments"], result["removedSeconds"]), ([], 0.0))
        self.assertEqual(spans(result["keepIntervals"]), BURST_KEEPS)
        self.assertEqual(spans(result["silenceTrims"]),
                         [(0.0, 1.5), (2.75, 4.25), (5.75, 7.25), (8.75, 10.25), (11.5, 16.5)])
        self.assertEqual(spans(result["cues"]), [(0.0, 1.0), (1.5, 2.5), (3.0, 4.0), (4.5, 5.5)])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertLess(stages.index("audio.silence.detect"), stages.index("audio.silence.trimmed"))

    def test_silence_never_changes_the_ad_report(self):
        ad = [FakeAd(20.0, 40.0, label="sponsor_read")]
        (self.directory / "trimmed").mkdir()
        (self.directory / "plain").mkdir()
        trimmed = run_preparation(self.directory / "trimmed", AD_SEGMENTS, 60.0, AD_SILENCES, detections=ad)
        plain = run_preparation(self.directory / "plain", AD_SEGMENTS, 60.0, [], detections=ad)
        for key in ("adSegments", "removedSeconds"):
            self.assertEqual(trimmed[key], plain[key], key)
        self.assertEqual(trimmed["report"]["rawNominations"], plain["report"]["rawNominations"])
        self.assertEqual((trimmed["report"]["outcome"], plain["report"]["outcome"]), ("cut", "cut"))
        self.assertEqual(spans(trimmed["adSegments"]), [(20.0, 40.0)])
        self.assertEqual(trimmed["removedSeconds"], 20.0)
        self.assertEqual(spans(plain["keepIntervals"]), [(0.0, 20.0), (40.0, 60.0)])
        self.assertEqual(plain["silenceTrims"], [])
        self.assertEqual(spans(trimmed["keepIntervals"]), AD_KEEPS)
        self.assertEqual(spans(trimmed["silenceTrims"]), [(18.25, 20.0), (40.0, 40.75), (50.25, 51.75), (57.0, 60.0)])
        # Ads, silence and kept audio tile the original with no gap or overlap.
        pieces = sorted(spans(trimmed["adSegments"]) + spans(trimmed["silenceTrims"]) + AD_KEEPS)
        self.assertEqual(pieces[0][0], 0.0)
        self.assertEqual(pieces[-1][1], 60.0)
        self.assertTrue(all(left[1] == right[0] for left, right in zip(pieces, pieces[1:])))
        self.assertEqual(spans(trimmed["cues"]), [(0.0, 18.0), (18.5, 27.5), (28.0, 33.0)])

    def test_real_trimmed_payloads_carry_the_silence_contract(self):
        results = silence_contract_payloads()
        self.assertEqual([entry["scenario"] for entry in results], ["silence-only", "ads-and-silence"])
        for entry in results:
            self.assertTrue(entry["payload"]["audioChanged"])
            self.assertTrue(entry["payload"]["silenceTrims"])
        json.dumps(results)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
class RealFfmpegSilenceTests(SilenceTrimTestCase):
    def test_gaps_become_half_a_second_and_the_tail_is_gone(self):
        source = self.directory / "bursts.wav"
        output = self.directory / "prepared.mp3"
        write_bursts(source, BURST_LAYOUT)
        with redirect_stderr(io.StringIO()):
            path, keeps = silence_trim.trim_unedited(source, output, None)
        self.assertEqual(path, output)
        self.assertEqual(len(keeps), len(BURST_KEEPS))
        for keep, (start, end) in zip(keeps, BURST_KEEPS):
            self.assertAlmostEqual(keep.start_s, start, delta=0.01)
            self.assertAlmostEqual(keep.end_s, end, delta=0.01)
        duration = _worker_cue_timing.probe_duration(output)
        self.assertAlmostEqual(duration, 5.5, delta=0.05)
        stderr = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats", "-v", "info", "-i", str(output),
             "-af", "silencedetect=noise=-50dB:d=0.3", "-f", "null", "-"],
            check=True, capture_output=True, text=True,
        ).stderr
        pauses = silence_trim.parse_silences(stderr, duration)
        self.assertEqual(len(pauses), 3, pauses)
        for start, end in pauses:
            self.assertGreater(start, 0.5)
            self.assertLess(end, duration - 0.5)
            self.assertAlmostEqual(end - start, 0.5, delta=0.06)


if __name__ == "__main__":
    unittest.main()
