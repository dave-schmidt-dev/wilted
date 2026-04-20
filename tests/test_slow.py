"""Slow tests requiring real TTS model and/or audio hardware.

Run manually: make test-slow
Excluded from: make validate

These tests load the real Kokoro TTS model via mlx-audio and exercise
the full generation pipeline, including MP3 caching and hybrid playback.
They require Apple Silicon and the mlx-audio venv.
"""

import shutil

import numpy as np
import pytest

pytestmark = pytest.mark.slow


class TestRealTTSGeneration:
    """Generate speech from the real Kokoro model."""

    def test_generate_audio_returns_float32(self):
        """AudioEngine.generate_audio() produces a non-empty float32 array."""
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        engine.load_model()
        audio = engine.generate_audio("Hello, this is a test.")

        assert isinstance(audio, np.ndarray)
        assert audio.dtype == np.float32
        assert len(audio) > 1000  # at minimum a few thousand samples
        assert np.abs(audio).mean() > 0.01  # not silence

    def test_speed_affects_output_length(self):
        """Faster speed produces shorter audio for the same text."""
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        engine.load_model()

        audio_normal = engine.generate_audio("This is a speed test sentence.", speed=1.0)
        audio_fast = engine.generate_audio("This is a speed test sentence.", speed=1.5)

        # Faster speech should produce fewer samples
        assert len(audio_fast) < len(audio_normal)


class TestRealCachePipeline:
    """Full cache generation with real TTS model + ffmpeg."""

    @pytest.mark.skipif(
        not shutil.which("ffmpeg"),
        reason="ffmpeg required for MP3 caching",
    )
    def test_generate_article_cache_real(self):
        """Full pipeline: real TTS -> MP3 encode -> read back."""
        from wilted.cache import generate_article_cache, load_audio, load_manifest
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        engine.load_model()

        text = "First paragraph of the test.\n\nSecond paragraph here."
        result = generate_article_cache(
            engine,
            text,
            article_id=1,
            voice="af_heart",
            lang="a",
            speed=1.0,
            added="2026-04-19T00:00:00",
        )

        assert result is True

        # Manifest should be complete with 2 paragraphs
        manifest = load_manifest(1)
        assert manifest is not None
        assert manifest["status"] == "complete"
        assert len(manifest["paragraphs"]) == 2

        # Each paragraph should have a loadable MP3
        for idx in range(2):
            cached = load_audio(1, idx)
            assert cached is not None
            audio, sr = cached
            assert sr == 24000
            assert len(audio) > 1000
            assert audio.dtype == np.float32
