"""Audio helpers — ffmpeg availability check."""

import subprocess


def check_ffmpeg() -> None:
    """Verify ffmpeg is available. Raises RuntimeError if not found."""
    try:
        subprocess.run(
            ["ffmpeg", "-version"],
            capture_output=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        raise RuntimeError("ffmpeg is required for audio caching. Install it with: brew install ffmpeg")
