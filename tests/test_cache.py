"""Tests for wilted.cache — audio caching with MP3 storage and manifest tracking."""

import shutil
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

import wilted
from wilted.cache import (
    check_ffmpeg,
    clear_cache,
    get_cache_dir,
    is_cache_valid,
    load_manifest,
    new_manifest,
    save_manifest,
)


class TestCheckFfmpeg:
    def test_passes_when_ffmpeg_available(self):
        """Should not raise when ffmpeg is found."""
        with patch("wilted.cache.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            check_ffmpeg()  # Should not raise

    def test_raises_when_ffmpeg_missing(self):
        with patch("wilted.cache.subprocess.run", side_effect=FileNotFoundError):
            with pytest.raises(RuntimeError, match="ffmpeg is required"):
                check_ffmpeg()

    def test_raises_on_ffmpeg_error(self):
        from subprocess import CalledProcessError

        with patch(
            "wilted.cache.subprocess.run",
            side_effect=CalledProcessError(1, "ffmpeg"),
        ):
            with pytest.raises(RuntimeError, match="ffmpeg is required"):
                check_ffmpeg()


class TestGetCacheDir:
    def test_returns_correct_path(self):
        result = get_cache_dir(42)
        assert result == wilted.AUDIO_DIR / "42"

    def test_uses_string_article_id(self):
        result = get_cache_dir(7)
        assert result.name == "7"


class TestSaveLoadAudio:
    """Test MP3 save/load round-trip via mlx_audio mocks."""

    def test_save_creates_mp3_file(self):
        from wilted.cache import save_audio

        audio_np = np.zeros(24000, dtype=np.float32)
        with patch("mlx_audio.audio_io.write") as mock_write:
            path = save_audio(1, 0, audio_np, 24000)
            assert path.name == "para_000.mp3"
            mock_write.assert_called_once_with(path, audio_np, 24000)

    @pytest.mark.skipif(
        not shutil.which("ffmpeg"),
        reason="ffmpeg required for real MP3 encode/decode",
    )
    def test_real_ffmpeg_round_trip(self, tmp_path):
        """Encode a sine wave to MP3 via ffmpeg subprocess, decode back."""
        import subprocess

        sample_rate = 24000
        duration = 0.5
        t = np.linspace(0, duration, int(sample_rate * duration), dtype=np.float32)
        tone = (0.5 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
        pcm = (np.clip(tone, -1.0, 1.0) * 32767).astype(np.int16)

        mp3_path = tmp_path / "roundtrip.mp3"
        # Encode: raw PCM → MP3
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "s16le",
                "-ar",
                str(sample_rate),
                "-ac",
                "1",
                "-i",
                "pipe:0",
                "-b:a",
                "128k",
                str(mp3_path),
            ],
            input=pcm.tobytes(),
            capture_output=True,
            check=True,
        )
        assert mp3_path.exists()
        assert mp3_path.stat().st_size > 100

        # Decode: MP3 → raw PCM
        result = subprocess.run(
            ["ffmpeg", "-i", str(mp3_path), "-f", "s16le", "-ar", str(sample_rate), "-ac", "1", "pipe:1"],
            capture_output=True,
            check=True,
        )
        decoded = np.frombuffer(result.stdout, dtype=np.int16).astype(np.float32) / 32767
        assert abs(len(decoded) - len(tone)) < sample_rate * 0.1
        assert np.abs(decoded).mean() > 0.05

    def test_save_creates_directory(self):
        from wilted.cache import save_audio

        audio_np = np.zeros(24000, dtype=np.float32)
        with patch("mlx_audio.audio_io.write"):
            path = save_audio(99, 5, audio_np, 24000)
            assert path.parent.exists()
            assert path.name == "para_005.mp3"

    def test_load_returns_none_when_missing(self):
        from wilted.cache import load_audio

        result = load_audio(1, 0)
        assert result is None

    def test_load_returns_float32_array(self):
        from wilted.cache import load_audio

        cache_dir = get_cache_dir(1)
        cache_dir.mkdir(parents=True)
        mp3_path = cache_dir / "para_000.mp3"
        mp3_path.write_bytes(b"fake mp3 data")

        expected = np.zeros(24000, dtype=np.float32)
        mock_read = MagicMock(return_value=(expected, 24000))
        with patch.dict("sys.modules", {"mlx_audio.audio_io": MagicMock(read=mock_read)}):
            result = load_audio(1, 0)
            assert result is not None
            audio, sr = result
            np.testing.assert_array_equal(audio, expected)
            assert sr == 24000
            mock_read.assert_called_once_with(mp3_path, dtype="float32")


class TestManifest:
    def test_save_and_load_round_trip(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        loaded = load_manifest(1)
        assert loaded == manifest

    def test_load_returns_none_when_missing(self):
        assert load_manifest(999) is None

    def test_load_returns_none_on_corrupt_json(self):
        cache_dir = get_cache_dir(1)
        cache_dir.mkdir(parents=True)
        (cache_dir / "manifest.json").write_text("not json{{{")
        assert load_manifest(1) is None

    def test_save_is_atomic(self):
        """No .tmp files left behind after save."""
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        cache_dir = get_cache_dir(1)
        tmp_files = list(cache_dir.glob("*.tmp"))
        assert tmp_files == []

    def test_manifest_fields(self):
        manifest = new_manifest(3, "bf_emma", "b", 1.5, "2026-04-08T10:00:00")
        assert manifest["article_id"] == 3
        assert manifest["voice"] == "bf_emma"
        assert manifest["lang"] == "b"
        assert manifest["speed"] == 1.5
        assert manifest["added"] == "2026-04-08T10:00:00"
        assert manifest["status"] == "generating"
        assert manifest["paragraphs"] == []

    def test_incremental_update(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)

        # Add a paragraph entry
        manifest["paragraphs"].append({"file": "para_000.mp3", "duration_seconds": 12.4, "samples": 297600})
        save_manifest(1, manifest)

        loaded = load_manifest(1)
        assert len(loaded["paragraphs"]) == 1
        assert loaded["paragraphs"][0]["duration_seconds"] == 12.4


class TestCacheValidation:
    def test_valid_cache(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        manifest["status"] = "complete"
        save_manifest(1, manifest)
        assert is_cache_valid(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is True

    def test_incomplete_cache_is_invalid(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        assert manifest["status"] == "generating"
        save_manifest(1, manifest)
        assert is_cache_valid(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is False

    def test_param_mismatch_is_invalid(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        for voice, lang, speed, added in [
            ("bf_emma", "a", 1.0, "2026-04-08T08:00:00"),
            ("af_heart", "b", 1.0, "2026-04-08T08:00:00"),
            ("af_heart", "a", 1.5, "2026-04-08T08:00:00"),
        ]:
            assert is_cache_valid(1, voice, lang, speed, added) is False

    def test_invalid_added(self):
        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        assert is_cache_valid(1, "af_heart", "a", 1.0, "2026-04-08T09:00:00") is False

    def test_no_manifest(self):
        assert is_cache_valid(999, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is False


class TestIsParagraphCached:
    """Tests for is_paragraph_cached() — per-paragraph cache validation."""

    def test_true_when_manifest_matches_and_file_exists(self):
        from wilted.cache import is_paragraph_cached

        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        manifest["paragraphs"].append({"file": "para_000.mp3"})
        save_manifest(1, manifest)
        # Create the MP3 file
        mp3_path = get_cache_dir(1) / "para_000.mp3"
        mp3_path.write_bytes(b"fake mp3")

        assert is_paragraph_cached(1, 0, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is True

    def test_false_when_no_manifest(self):
        from wilted.cache import is_paragraph_cached

        assert is_paragraph_cached(999, 0, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is False

    def test_false_when_manifest_params_mismatch(self):
        from wilted.cache import is_paragraph_cached

        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        mp3_path = get_cache_dir(1) / "para_000.mp3"
        mp3_path.write_bytes(b"fake mp3")

        for voice, lang, speed in [
            ("bf_emma", "a", 1.0),
            ("af_heart", "a", 1.5),
        ]:
            assert is_paragraph_cached(1, 0, voice, lang, speed, "2026-04-08T08:00:00") is False

    def test_false_when_file_missing(self):
        from wilted.cache import is_paragraph_cached

        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        save_manifest(1, manifest)
        # Don't create the MP3 file

        assert is_paragraph_cached(1, 0, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is False

    def test_works_with_generating_status(self):
        """Partially generated cache (status=generating) should still allow hits."""
        from wilted.cache import is_paragraph_cached

        manifest = new_manifest(1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        assert manifest["status"] == "generating"  # Not complete
        save_manifest(1, manifest)
        mp3_path = get_cache_dir(1) / "para_000.mp3"
        mp3_path.write_bytes(b"fake mp3")

        assert is_paragraph_cached(1, 0, "af_heart", "a", 1.0, "2026-04-08T08:00:00") is True


class TestClearCache:
    def test_removes_directory(self):
        cache_dir = get_cache_dir(1)
        cache_dir.mkdir(parents=True)
        (cache_dir / "para_000.mp3").write_bytes(b"data")
        (cache_dir / "manifest.json").write_text("{}")

        clear_cache(1)
        assert not cache_dir.exists()

    def test_no_error_when_missing(self):
        """clear_cache should not raise if directory doesn't exist."""
        clear_cache(999)  # Should not raise


class TestQueueCacheCleanup:
    """Verify queue operations clean up audio cache."""

    def test_remove_article_clears_cache(self):
        from wilted.queue import add_article, remove_article

        entry = add_article("Hello world.", title="Test")
        cache_dir = get_cache_dir(entry["id"])
        cache_dir.mkdir(parents=True)
        (cache_dir / "para_000.mp3").write_bytes(b"data")

        remove_article(0)
        assert not cache_dir.exists()

    def test_mark_completed_retains_cache(self):
        """mark_completed keeps audio cache; the retention policy handles cleanup."""
        from wilted.queue import add_article, mark_completed

        entry = add_article("Hello world.", title="Test")
        cache_dir = get_cache_dir(entry["id"])
        cache_dir.mkdir(parents=True)
        (cache_dir / "para_000.mp3").write_bytes(b"data")

        mark_completed(entry)
        assert cache_dir.exists()

    def test_clear_queue_clears_all_caches(self):
        from wilted.queue import add_article, clear_queue

        e1 = add_article("Article one.", title="One")
        e2 = add_article("Article two.", title="Two")
        for e in [e1, e2]:
            d = get_cache_dir(e["id"])
            d.mkdir(parents=True)
            (d / "para_000.mp3").write_bytes(b"data")

        clear_queue()
        assert not get_cache_dir(e1["id"]).exists()
        assert not get_cache_dir(e2["id"]).exists()


class TestGenerateArticleCache:
    """Tests for generate_article_cache with mock engine."""

    def _make_engine(self):
        """Create a mock engine that returns fake audio."""
        engine = MagicMock()
        engine.sample_rate = 24000
        engine.generate_audio.return_value = np.zeros(24000, dtype=np.float32)
        return engine

    def test_generates_all_paragraphs(self):
        from wilted.cache import generate_article_cache

        engine = self._make_engine()
        text = "Paragraph one.\n\nParagraph two.\n\nParagraph three."

        with patch("mlx_audio.audio_io.write"):
            result = generate_article_cache(engine, text, 1, "af_heart", "a", 1.0, "2026-04-08T08:00:00")

        assert result is True
        assert engine.generate_audio.call_count == 3
        # Verify explicit params passed
        for call in engine.generate_audio.call_args_list:
            assert call.kwargs["voice"] == "af_heart"
            assert call.kwargs["lang"] == "a"
            assert call.kwargs["speed"] == 1.0

        manifest = load_manifest(1)
        assert manifest["status"] == "complete"
        assert len(manifest["paragraphs"]) == 3

    def test_cancellation_stops_early(self):
        from wilted.cache import generate_article_cache

        engine = self._make_engine()
        text = "Para one.\n\nPara two.\n\nPara three."
        cancel_after = [1]  # Cancel after first paragraph

        def should_cancel():
            if cancel_after[0] <= 0:
                return True
            cancel_after[0] -= 1
            return False

        with patch("mlx_audio.audio_io.write"):
            result = generate_article_cache(
                engine,
                text,
                2,
                "af_heart",
                "a",
                1.0,
                "2026-04-08T08:00:00",
                should_cancel=should_cancel,
            )

        assert result is False
        assert engine.generate_audio.call_count == 1

    def test_on_progress_callback(self):
        from wilted.cache import generate_article_cache

        engine = self._make_engine()
        text = "First.\n\nSecond."
        progress_calls = []

        with patch("mlx_audio.audio_io.write"):
            generate_article_cache(
                engine,
                text,
                3,
                "af_heart",
                "a",
                1.0,
                "2026-04-08T08:00:00",
                on_progress=lambda idx, total: progress_calls.append((idx, total)),
            )

        assert progress_calls == [(0, 2), (1, 2)]

    def test_clears_stale_cache(self):
        from wilted.cache import generate_article_cache

        # Create cache with different voice
        manifest = new_manifest(4, "bf_emma", "b", 1.0, "2026-04-08T08:00:00")
        save_manifest(4, manifest)

        engine = self._make_engine()
        with patch("mlx_audio.audio_io.write"):
            generate_article_cache(engine, "Hello.", 4, "af_heart", "a", 1.0, "2026-04-08T08:00:00")

        manifest = load_manifest(4)
        assert manifest["voice"] == "af_heart"

    def test_empty_text_returns_true(self):
        from wilted.cache import generate_article_cache

        engine = self._make_engine()
        result = generate_article_cache(engine, "", 5, "af_heart", "a", 1.0, "2026-04-08T08:00:00")
        assert result is True
        engine.generate_audio.assert_not_called()


class TestEngineExplicitParams:
    """Tests for generate_audio() with explicit voice/lang/speed params."""

    def test_explicit_params_used(self):
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        mock_model = MagicMock()
        mock_segment = MagicMock()
        mock_segment.audio = [0.0] * 100
        mock_model.generate.return_value = mock_segment
        engine._model = mock_model

        engine.generate_audio("hello", voice="bf_emma", lang="b", speed=1.5)
        mock_model.generate.assert_called_once_with("hello", voice="bf_emma", speed=1.5, lang_code="b")

    def test_fallback_to_instance_attrs(self):
        from wilted.engine import AudioEngine

        engine = AudioEngine(voice="am_adam", speed=0.8, lang="a")
        mock_model = MagicMock()
        mock_segment = MagicMock()
        mock_segment.audio = [0.0] * 100
        mock_model.generate.return_value = mock_segment
        engine._model = mock_model

        engine.generate_audio("hello")
        mock_model.generate.assert_called_once_with("hello", voice="am_adam", speed=0.8, lang_code="a")

    def test_partial_override(self):
        from wilted.engine import AudioEngine

        engine = AudioEngine(voice="am_adam", speed=0.8, lang="a")
        mock_model = MagicMock()
        mock_segment = MagicMock()
        mock_segment.audio = [0.0] * 100
        mock_model.generate.return_value = mock_segment
        engine._model = mock_model

        engine.generate_audio("hello", voice="bf_emma")
        mock_model.generate.assert_called_once_with("hello", voice="bf_emma", speed=0.8, lang_code="a")


class TestModelLock:
    """Tests for threading.Lock on model access."""

    def test_lock_exists(self):
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        assert hasattr(engine, "_model_lock")

    def test_generate_audio_acquires_lock(self):
        from wilted.engine import AudioEngine

        engine = AudioEngine()
        mock_model = MagicMock()
        mock_segment = MagicMock()
        mock_segment.audio = [0.0] * 100
        mock_model.generate.return_value = mock_segment
        engine._model = mock_model

        # Replace lock with a mock to verify acquisition
        mock_lock = MagicMock()
        mock_lock.__enter__ = MagicMock(return_value=None)
        mock_lock.__exit__ = MagicMock(return_value=False)
        engine._model_lock = mock_lock

        engine.generate_audio("hello")
        mock_lock.__enter__.assert_called_once()
        mock_lock.__exit__.assert_called_once()
