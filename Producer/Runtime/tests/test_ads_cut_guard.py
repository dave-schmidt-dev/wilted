"""cut_ads never turns an all-ad or zero-width result into a silent 0-byte file."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from wilted.ads import AdSegment


def _ad_segment(start_s, end_s):
    """Build a high-confidence AdSegment for the empty-cut guard tests."""
    return AdSegment(start_s=start_s, end_s=end_s, confidence=0.95, label="ad_break")


class TestCutAdsEmptyResultGuard:
    """cut_ads never turns an all-ad or zero-width result into a silent 0-byte file."""

    def test_cut_ads_raises_when_nothing_to_keep(self, tmp_path):
        """cut_ads no longer returns a silent 0-byte file when all is ads."""
        from wilted.ads import EmptyCutResultError, cut_ads

        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data with real bytes")

        output = tmp_path / "output.mp3"
        # One ad spanning the whole clip -> _compute_keep_segments returns [].
        ads = [_ad_segment(0.0, 300.0)]

        probe_result = MagicMock()
        probe_result.stdout = "300.0\n"

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run", return_value=probe_result),
        ):
            with pytest.raises(EmptyCutResultError):
                cut_ads(audio, ads, output, buffer_seconds=0.5)

        # No 0-byte file should have been created at the output path.
        assert not output.exists()

    def test_cut_ads_raises_when_all_keep_segments_zero_width(self, tmp_path):
        """cut_ads raises when keep_segments is non-empty but every segment
        has duration <= 0 after buffer clamping, so the extraction loop
        skips all of them and segment_files ends up empty (ads.py:493).
        """
        from wilted.ads import EmptyCutResultError, cut_ads

        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data with real bytes")

        output = tmp_path / "output.mp3"
        # Ad segments here are irrelevant since _compute_keep_segments is
        # mocked directly; a non-empty list just satisfies the
        # `if not ad_segments` short-circuit so cut_ads reaches the ffprobe
        # call and the extraction loop.
        ads = [_ad_segment(0.0, 10.0)]

        probe_result = MagicMock()
        probe_result.stdout = "300.0\n"

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run", return_value=probe_result),
            # Non-empty keep_segments (bypasses the :458 raise) but every
            # segment is zero-width, so the extraction loop's
            # `if duration <= 0: continue` skips all of them.
            patch("wilted.ads._compute_keep_segments", return_value=[(5.0, 5.0), (10.0, 10.0)]),
        ):
            with pytest.raises(EmptyCutResultError, match="No non-empty keep-segments"):
                cut_ads(audio, ads, output, buffer_seconds=0.5)

        # No 0-byte file should have been created at the output path.
        assert not output.exists()

