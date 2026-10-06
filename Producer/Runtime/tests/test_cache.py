"""Tests for wilted.cache — the ffmpeg availability check."""

from unittest.mock import patch

import pytest


class TestCheckFfmpeg:
    def test_raises_when_ffmpeg_missing(self):
        from wilted.cache import check_ffmpeg

        with patch("wilted.cache.subprocess.run", side_effect=FileNotFoundError):
            with pytest.raises(RuntimeError, match="ffmpeg is required"):
                check_ffmpeg()
