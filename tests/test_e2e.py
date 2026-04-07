"""End-to-end smoke tests for lilt — requires real TTS model.

Run with: pytest -m slow
"""

import subprocess
import sys

import pytest

pytestmark = pytest.mark.slow


# ---------------------------------------------------------------------------
# Tier 1: Subprocess smoke test
# ---------------------------------------------------------------------------


class TestSubprocessSmoke:
    def test_clean_mode_with_stdin(self):
        """lilt --clean reads from stdin and outputs cleaned text."""
        result = subprocess.run(
            [sys.executable, "-m", "lilt.cli", "--clean", "-"],
            input="Hello world. This is a smoke test.\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0
        assert "Hello world" in result.stdout

    def test_version_flag(self):
        """lilt --version outputs version string."""
        result = subprocess.run(
            [sys.executable, "-m", "lilt.cli", "--version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0
        assert "lilt" in result.stdout


# ---------------------------------------------------------------------------
# Tier 2: In-process engine tests (real model)
# ---------------------------------------------------------------------------


class TestEngineSmoke:
    def test_model_loads(self):
        """AudioEngine loads the real Kokoro model without error."""
        from lilt.engine import AudioEngine

        engine = AudioEngine()
        engine.load_model()
        assert engine._model is not None

    def test_generate_short_clip(self):
        """Generating audio for a short sentence produces valid float32 numpy."""
        import numpy as np

        from lilt.engine import AudioEngine

        engine = AudioEngine()
        audio = engine.generate_audio("Hello world.")
        assert isinstance(audio, np.ndarray)
        assert audio.dtype == np.float32
        assert len(audio) > 0
        # Should not be silence (all zeros)
        assert audio.max() > 0.0 or audio.min() < 0.0

    def test_reasonable_duration(self):
        """A short sentence should produce 0.5-10 seconds of audio."""
        from lilt.engine import SAMPLE_RATE, AudioEngine

        engine = AudioEngine()
        audio = engine.generate_audio("The quick brown fox jumps over the lazy dog.")
        duration_secs = len(audio) / SAMPLE_RATE
        assert 0.5 <= duration_secs <= 10.0, f"Duration {duration_secs:.1f}s outside expected range"
