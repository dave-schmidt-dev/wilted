"""Unit tests for speech-to-text hole refilling."""
from __future__ import annotations

import subprocess
import sys
import unittest
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

from wilted_worker import cue_timing, stt_refill, transcript_sources
from wilted_worker.constants import ALIGNED_STT_MODEL
from worker_test_support import install_fake_wilted


@dataclass
class FakeToken:
    text: str
    start_s: float
    end_s: float


@dataclass
class FakeSegment:
    start_s: float
    end_s: float
    text: str
    tokens: tuple[FakeToken, ...] | None = None


def make_continuous_segment(start_s: float, end_s: float, text: str) -> FakeSegment:
    """Build a segment filled with consecutive 1.0 s tokens so no internal holes occur."""
    tokens = []
    n = max(1, int((end_s - start_s) / 1.0))
    step = (end_s - start_s) / n
    words = text.split()
    for i in range(n):
        tok_start = start_s + i * step
        tok_end = start_s + (i + 1) * step
        word = (" " + words[i % len(words)]) if i > 0 else words[0]
        tokens.append(FakeToken(word, tok_start, tok_end))
    return FakeSegment(start_s, end_s, text, tuple(tokens))


class FindHolesTests(unittest.TestCase):
    """Tests for stt_refill.find_holes."""

    def test_interior_gap_found(self):
        segments = [
            make_continuous_segment(0.0, 10.0, "Start."),
            make_continuous_segment(25.0, 35.0, "End."),
        ]
        holes = stt_refill.find_holes(segments, 35.0)
        self.assertEqual(holes, [(10.0, 25.0)])

    def test_leading_and_trailing_gaps_found(self):
        segments = [
            make_continuous_segment(10.0, 20.0, "Middle."),
        ]
        holes = stt_refill.find_holes(segments, 30.0)
        self.assertEqual(holes, [(0.0, 10.0), (20.0, 30.0)])

    def test_stretched_last_token_capped(self):
        # Continuous speech up to 10.0, then a token stretched across 8 seconds of pause
        seg1 = make_continuous_segment(0.0, 10.0, "Start.")
        stretched_seg = FakeSegment(
            0.0,
            18.0,
            "Slow.",
            seg1.tokens + (FakeToken(" Slow.", 10.0, 18.0),),
        )
        seg2 = make_continuous_segment(20.0, 21.0, "Next.")
        segments = [stretched_seg, seg2]

        # Without capping at start + 1.2s (11.2s), gap is 20 - 18 = 2s (< 8s).
        # With cap at 11.2s, gap is 20 - 11.2 = 8.8s (>= 8s).
        holes = stt_refill.find_holes(segments, 21.0)
        self.assertEqual(holes, [(11.2, 20.0)])

    def test_gaps_under_eight_seconds_ignored(self):
        segments = [
            make_continuous_segment(0.0, 10.0, "First."),
            make_continuous_segment(17.0, 25.0, "Second."),
        ]
        holes = stt_refill.find_holes(segments, 25.0)
        self.assertEqual(holes, [])

    def test_tokens_is_none_segments_respected(self):
        segments = [
            FakeSegment(0.0, 10.0, "Untokenized 1", None),
            FakeSegment(25.0, 35.0, "Untokenized 2", None),
        ]
        holes = stt_refill.find_holes(segments, 35.0)
        self.assertEqual(holes, [(10.0, 25.0)])


class RefillWindowsTests(unittest.TestCase):
    """Tests for stt_refill.refill_windows."""

    def test_padding_and_clamping(self):
        holes = [(10.0, 25.0)]
        windows = stt_refill.refill_windows(holes, 30.0)
        self.assertEqual(windows, [(7.0, 28.0)])

        boundary_holes = [(0.0, 15.0), (25.0, 30.0)]
        windows = stt_refill.refill_windows(boundary_holes, 30.0)
        self.assertEqual(windows, [(0.0, 18.0), (22.0, 30.0)])

    def test_nearby_holes_merge(self):
        # Hole 1: 10-20 -> padded: 7-23.
        # Hole 2: 25-35 -> padded: 22-38.
        # Padded spans overlap (22 <= 23): merged -> 7-38.
        holes = [(10.0, 20.0), (25.0, 35.0)]
        windows = stt_refill.refill_windows(holes, 50.0)
        self.assertEqual(windows, [(7.0, 38.0)])

        # Hole 1: 10-20 -> padded: 7-23.
        # Hole 2: 28-38 -> padded: 25-41.
        # Distance between padded spans is 25 - 23 = 2s <= 3s (CONTEXT_S): merged -> 7-41.
        holes_near = [(10.0, 20.0), (28.0, 38.0)]
        windows_near = stt_refill.refill_windows(holes_near, 50.0)
        self.assertEqual(windows_near, [(7.0, 41.0)])

    def test_a_one_hundred_fifty_second_hole_splits_into_three_windows_bounded_by_sixty(self):
        holes = [(0.0, 150.0)]
        windows = stt_refill.refill_windows(holes, 150.0)
        self.assertEqual(len(windows), 3)
        self.assertEqual(windows, [(0.0, 50.0), (50.0, 100.0), (100.0, 150.0)])
        for start, end in windows:
            self.assertLessEqual(end - start, 60.0)


class RefillHolesTests(unittest.TestCase):
    """Tests for stt_refill.refill_holes."""

    @mock.patch("subprocess.run")
    def test_refill_forty_second_hole_and_drop_padding_tokens(self, mock_run):
        segments = [
            make_continuous_segment(0.0, 10.0, "Opening words."),
            make_continuous_segment(50.0, 60.0, "Closing words."),
        ]

        # Hole is 10.0-50.0 (40s). Window is 7.0-53.0.
        def fake_transcribe(_wav_path):
            return [
                # In left padding: window-relative 1.0-2.5 (absolute 8.0-9.5 <= 10.0)
                FakeSegment(1.0, 2.5, "words.", (FakeToken(" words.", 1.0, 2.5),)),
                # Strictly inside hole: window-relative 10.0-20.0 (absolute 17.0-27.0)
                FakeSegment(
                    10.0,
                    20.0,
                    "Recovered text.",
                    (FakeToken(" Recovered", 10.0, 15.0), FakeToken(" text.", 15.0, 20.0)),
                ),
                # In right padding: window-relative 44.0-45.0 (absolute 51.0-52.0 >= 50.0)
                FakeSegment(44.0, 45.0, "Closing", (FakeToken(" Closing", 44.0, 45.0),)),
            ]

        result = stt_refill.refill_holes("dummy.mp3", segments, 60.0, fake_transcribe)
        self.assertEqual(len(result), 3)
        self.assertEqual(
            [(s.text, s.start_s, s.end_s) for s in result],
            [
                ("Opening words.", 0.0, 10.0),
                ("Recovered text.", 17.0, 27.0),
                ("Closing words.", 50.0, 60.0),
            ],
        )

    @mock.patch("subprocess.run")
    def test_words_repeated_across_a_hole_edge_are_dropped(self, mock_run):
        segments = [
            make_continuous_segment(0.0, 10.0, "Opening words."),
            make_continuous_segment(50.0, 60.0, "Closing words."),
        ]

        # Window 7.0-53.0: the decoder hears "words." at 10.4 and "Closing" at 49.5,
        # just inside the hole, besides the recovered sentence.
        def fake_transcribe(_wav_path):
            return [
                FakeSegment(
                    3.4,
                    42.5,
                    "words. Middle bit Closing",
                    (
                        FakeToken(" words.", 3.4, 4.0),
                        FakeToken(" Mid", 20.0, 20.5),
                        FakeToken("dle", 20.5, 21.0),
                        FakeToken(" bit", 21.0, 22.0),
                        FakeToken(" Closing", 42.5, 43.0),
                    ),
                ),
            ]

        result = stt_refill.refill_holes("dummy.mp3", segments, 60.0, fake_transcribe)
        self.assertEqual([(s.text, s.start_s, s.end_s) for s in result][1], ("Middle bit", 27.0, 29.0))

    @mock.patch("subprocess.run")
    def test_window_returning_nothing_leaves_segments_unchanged(self, mock_run):
        segments = [
            make_continuous_segment(0.0, 10.0, "Words."),
            make_continuous_segment(50.0, 60.0, "More."),
        ]
        result = stt_refill.refill_holes("dummy.mp3", segments, 60.0, lambda _: [])
        self.assertEqual(result, segments)

    @mock.patch("subprocess.run")
    def test_window_that_raises_leaves_segments_unchanged_and_returns(self, mock_run):
        segments = [
            make_continuous_segment(0.0, 10.0, "Words."),
            make_continuous_segment(50.0, 60.0, "More."),
        ]

        def failing_transcribe(_):
            raise stt_refill.TranscriptionError("mock failure")

        result = stt_refill.refill_holes("dummy.mp3", segments, 60.0, failing_transcribe)
        self.assertEqual(result, segments)

        mock_run.side_effect = subprocess.CalledProcessError(1, ["ffmpeg"])
        result_ffmpeg_fail = stt_refill.refill_holes("dummy.mp3", segments, 60.0, lambda _: [])
        self.assertEqual(result_ffmpeg_fail, segments)


class TranscribeWithDaemonRefillTests(unittest.TestCase):
    """Tests that transcribe_with_daemon invokes refill_holes."""

    @mock.patch("subprocess.run")
    def test_transcribe_with_daemon_recovers_hole_text(self, mock_run):
        install_fake_wilted()

        calls = []

        def fake_transcribe_audio(path, model_name=ALIGNED_STT_MODEL, **_):
            calls.append((path, model_name))
            if len(calls) == 1:
                # First call on full audio: has a 40 s hole between 10.0 and 50.0
                return [
                    make_continuous_segment(0.0, 10.0, "Opening segment."),
                    make_continuous_segment(50.0, 60.0, "Closing segment."),
                ]
            # Second call for the refill window (7.0 to 53.0)
            return [
                FakeSegment(
                    10.0,
                    20.0,
                    "Recovered middle.",
                    (FakeToken(" Recovered", 10.0, 15.0), FakeToken(" middle.", 15.0, 20.0)),
                ),
            ]

        sys.modules["wilted.transcribe"].transcribe_audio = fake_transcribe_audio

        with mock.patch.object(cue_timing, "probe_duration", return_value=60.0):
            result = transcript_sources.transcribe_with_daemon(Path("sample.mp3"))

        self.assertEqual(len(calls), 2)
        self.assertEqual(
            [(s.text, s.start_s, s.end_s) for s in result],
            [
                ("Opening segment.", 0.0, 10.0),
                ("Recovered middle.", 17.0, 27.0),
                ("Closing segment.", 50.0, 60.0),
            ],
        )
