"""Tests for audio cutting and keep segment computation."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from wilted.ads import (
    AdSegment,
    _compute_keep_segments,
    _merge_adjacent,
    cut_ads,
)

# ---------------------------------------------------------------------------
# _merge_adjacent
# ---------------------------------------------------------------------------


class TestMergeAdjacent:
    def test_merge_overlapping(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="ad_break"),
            AdSegment(start_s=19, end_s=30, confidence=0.8, label="ad_break"),
        ]
        merged = _merge_adjacent(segs)
        assert len(merged) == 1
        assert merged[0].start_s == 10
        assert merged[0].end_s == 30

    def test_no_merge_large_gap(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="ad_break"),
            AdSegment(start_s=30, end_s=40, confidence=0.8, label="sponsor_read"),
        ]
        merged = _merge_adjacent(segs)
        assert len(merged) == 2

    def test_merge_label_tie_preserves_earlier_run_deterministically(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="sponsor_read"),
            AdSegment(start_s=20, end_s=30, confidence=0.8, label="self_promo"),
        ]

        merged = _merge_adjacent(segs)

        assert len(merged) == 1
        assert merged[0].start_s == 10
        assert merged[0].end_s == 30
        assert merged[0].confidence == pytest.approx(0.85)
        assert merged[0].label == "sponsor_read"


# ---------------------------------------------------------------------------
# _compute_keep_segments
# ---------------------------------------------------------------------------


class TestComputeKeepSegments:
    def test_correct_inversion(self):
        """Keeps are the inverse of ad segments."""
        ads = [
            AdSegment(start_s=30.0, end_s=60.0, confidence=0.9, label="ad_break"),
            AdSegment(start_s=120.0, end_s=150.0, confidence=0.85, label="sponsor_read"),
        ]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Expected: [0, 29.5], [60.5, 119.5], [150.5, 300]
        assert len(keeps) == 3
        assert keeps[0] == (0.0, 29.5)
        assert keeps[1] == (60.5, 119.5)
        assert keeps[2] == (150.5, 300.0)

    def test_no_ads_entire_duration_kept(self):
        """No ads means the full duration is one keep segment."""
        keeps = _compute_keep_segments(600.0, [], buffer_s=0.5)
        assert keeps == [(0.0, 600.0)]

    def test_ad_at_beginning(self):
        """Ad at the start of the audio."""
        ads = [AdSegment(start_s=0.0, end_s=30.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Buffer clamps to 0, so ad region is [0, 30.5]
        assert len(keeps) == 1
        assert keeps[0][0] == 30.5
        assert keeps[0][1] == 300.0

    def test_ad_at_end(self):
        """Ad at the end of the audio."""
        ads = [AdSegment(start_s=270.0, end_s=300.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Content before ad: [0, 269.5], ad region [269.5, 300] -> no content after
        assert len(keeps) == 1
        assert keeps[0] == (0.0, 269.5)

    def test_ad_covers_entire_duration(self):
        """Ad spans the whole file leaves nothing."""
        ads = [AdSegment(start_s=0.0, end_s=300.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)
        assert keeps == []

    def test_overlapping_ads(self):
        """Overlapping ad segments handled correctly."""
        ads = [
            AdSegment(start_s=10.0, end_s=30.0, confidence=0.9, label="ad_break"),
            AdSegment(start_s=25.0, end_s=50.0, confidence=0.85, label="sponsor_read"),
        ]
        keeps = _compute_keep_segments(100.0, ads, buffer_s=0.5)

        # After sorting by start_s:
        # Ad 1: [10-0.5, 30+0.5] = [9.5, 30.5]
        # Ad 2: [25-0.5, 50+0.5] = [24.5, 50.5]
        # Merged ad zone: [9.5, 50.5]
        # Keeps: [0, 9.5], [50.5, 100]
        assert len(keeps) == 2
        assert keeps[0] == (0.0, 9.5)
        assert keeps[1] == (50.5, 100.0)


# ---------------------------------------------------------------------------
# cut_ads
# ---------------------------------------------------------------------------


class TestCutAds:
    def test_ffmpeg_commands_correct(self, tmp_path):
        """Verify ffmpeg is called with correct arguments."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio")
        output = tmp_path / "output.mp3"

        ads = [AdSegment(start_s=30.0, end_s=60.0, confidence=0.9, label="ad_break")]

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run") as mock_run,
            patch("wilted.ads.shutil.move"),
            patch("wilted.ads.tempfile.mkdtemp") as mock_mkdtemp,
            patch("wilted.ads.shutil.rmtree"),
        ):
            tmpdir = tmp_path / "tmpwork"
            tmpdir.mkdir()
            mock_mkdtemp.return_value = str(tmpdir)

            # ffprobe returns duration
            probe_result = MagicMock()
            probe_result.stdout = "300.0\n"

            # Segment extraction succeeds
            seg_result = MagicMock()

            mock_run.side_effect = [probe_result, seg_result]

            # With one ad in the middle (30-60s), buffer 0.5s, duration 300s:
            # Keep: [0, 29.5] and [60.5, 300]
            # Two keep segments -> extract + extract + concat
            mock_run.reset_mock()
            mock_run.side_effect = [probe_result, seg_result, seg_result, MagicMock()]

            cut_ads(audio, ads, output, buffer_seconds=0.5)

            calls = mock_run.call_args_list
            # First call: ffprobe
            assert calls[0].args[0][0] == "ffprobe"
            # Second call: ffmpeg extract segment 0
            assert calls[1].args[0][0] == "ffmpeg"
            assert "-ss" in calls[1].args[0]
            assert "-t" in calls[1].args[0]
            # Third call: ffmpeg extract segment 1
            assert calls[2].args[0][0] == "ffmpeg"
            # Fourth call: ffmpeg concat
            assert "-f" in calls[3].args[0]
            assert "concat" in calls[3].args[0]

    def test_no_ads_copies_file(self, tmp_path):
        """No ad segments means the file is copied as-is."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data")
        output = tmp_path / "output.mp3"

        with patch("wilted.ads.check_ffmpeg"):
            result = cut_ads(audio, [], output)

        assert result == output
        assert output.exists()
        assert output.read_bytes() == b"fake audio data"

    def test_missing_audio_raises(self, tmp_path):
        """FileNotFoundError if audio file doesn't exist."""
        audio = tmp_path / "nonexistent.mp3"
        output = tmp_path / "output.mp3"

        with patch("wilted.ads.check_ffmpeg"):
            with pytest.raises(FileNotFoundError):
                cut_ads(audio, [], output)

    def test_single_keep_segment_no_concat(self, tmp_path):
        """Single keep segment uses move instead of concat."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio")
        output = tmp_path / "output.mp3"

        # Ad at the very beginning, so only one keep segment after the ad
        ads = [AdSegment(start_s=0.0, end_s=30.0, confidence=0.9, label="ad_break")]

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run") as mock_run,
            patch("wilted.ads.shutil.move") as mock_move,
            patch("wilted.ads.tempfile.mkdtemp") as mock_mkdtemp,
            patch("wilted.ads.shutil.rmtree"),
        ):
            tmpdir = tmp_path / "tmpwork2"
            tmpdir.mkdir()
            mock_mkdtemp.return_value = str(tmpdir)

            probe_result = MagicMock()
            probe_result.stdout = "300.0\n"
            seg_result = MagicMock()

            mock_run.side_effect = [probe_result, seg_result]

            cut_ads(audio, ads, output, buffer_seconds=0.5)

            # Should have ffprobe + one segment extract (no concat)
            assert mock_run.call_count == 2
            # Should use shutil.move for single segment
            mock_move.assert_called_once()


# ---------------------------------------------------------------------------
# cut_ads — real ffmpeg integration
# ---------------------------------------------------------------------------


def _ffprobe_duration(path) -> float:
    import subprocess

    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(result.stdout.strip())


class TestCutAdsRealFfmpeg:
    @pytest.mark.skipif(
        not __import__("shutil").which("ffmpeg") or not __import__("shutil").which("ffprobe"),
        reason="ffmpeg and ffprobe required",
    )
    def test_cut_removes_middle_segment(self, tmp_path):
        """Real ffmpeg cuts a middle ad segment and produces shorter output."""
        import subprocess

        mp3_path = tmp_path / "input.mp3"
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=3:sample_rate=22050",
                str(mp3_path),
            ],
            capture_output=True,
            check=True,
        )

        ad = AdSegment(start_s=1.0, end_s=2.0, confidence=0.95, label="ad_break")
        output = tmp_path / "output.mp3"

        result = cut_ads(mp3_path, [ad], output, buffer_seconds=0.0)

        assert result == output
        assert output.exists()
        assert output.stat().st_size > 0

        input_dur = _ffprobe_duration(mp3_path)
        output_dur = _ffprobe_duration(output)

        assert output_dur < input_dur
        assert abs(output_dur - 2.0) < 0.5  # ~2s remaining after 1s cut

    @pytest.mark.skipif(
        not __import__("shutil").which("ffmpeg"),
        reason="ffmpeg required",
    )
    def test_no_ads_output_matches_input(self, tmp_path):
        """No ads — output is a byte-identical copy of input."""
        import subprocess

        mp3_path = tmp_path / "input.mp3"
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=2:sample_rate=22050",
                str(mp3_path),
            ],
            capture_output=True,
            check=True,
        )

        output = tmp_path / "output.mp3"
        cut_ads(mp3_path, [], output, buffer_seconds=0.0)

        assert output.read_bytes() == mp3_path.read_bytes()
