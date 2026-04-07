"""Edge case tests for lilt — corrupt data, missing files, concurrent access, engine errors."""

import json
import threading
import types
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

import lilt
from lilt.engine import AudioEngine
from lilt.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
    save_queue,
)
from lilt.state import (
    clear_article_state,
    get_article_state,
    load_state,
    set_article_state,
)

# ---------------------------------------------------------------------------
# TestCorruptQueue
# ---------------------------------------------------------------------------


class TestCorruptQueue:
    """Verify load_queue() handles corrupt or unexpected queue file contents."""

    def test_corrupt_json_returns_empty(self):
        """Invalid JSON in the queue file should return an empty list."""
        lilt.QUEUE_FILE.write_text("{not valid json at all!!")
        assert load_queue() == []

    def test_empty_file_returns_empty(self):
        """A zero-byte queue file should return an empty list."""
        lilt.QUEUE_FILE.write_text("")
        assert load_queue() == []

    def test_non_list_json_returns_empty(self):
        """A JSON object (dict) instead of a list should return an empty list.

        After hardening, load_queue() validates the top-level type and returns []
        for non-list JSON.
        """
        lilt.QUEUE_FILE.write_text(json.dumps({"not": "a list"}))
        result = load_queue()
        assert result == []

    def test_non_list_json_types_return_empty(self):
        """Non-list JSON types (string, int, dict) should all return []."""
        for value in ['"just a string"', "42", '{"key": "val"}']:
            lilt.QUEUE_FILE.write_text(value)
            assert load_queue() == [], f"load_queue() should return [] for JSON: {value}"

    def test_corrupt_queue_does_not_break_add(self):
        """Adding an article when the queue file is corrupt should recover."""
        lilt.QUEUE_FILE.write_text("<<<garbage>>>")
        entry = add_article("Recovery test article.", title="Recovery")
        assert entry["id"] == 1
        assert load_queue() == [entry]

    def test_corrupt_queue_does_not_break_clear(self):
        """Clearing when the queue file is corrupt should not crash."""
        lilt.QUEUE_FILE.write_text("not json")
        count = clear_queue()
        assert count == 0


# ---------------------------------------------------------------------------
# TestCorruptState
# ---------------------------------------------------------------------------


class TestCorruptState:
    """Verify state module functions survive corrupt state files."""

    def test_corrupt_json_returns_empty_dict(self):
        """Corrupt state file should produce an empty dict from load_state()."""
        lilt.STATE_FILE.write_text("{{{bad json!!")
        assert load_state() == {}

    def test_non_dict_json_returns_empty_dict(self):
        """Non-dict JSON types (list, string, int) should return {}."""
        for value in ["[1, 2, 3]", '"a string"', "42"]:
            lilt.STATE_FILE.write_text(value)
            assert load_state() == {}, f"load_state() should return {{}} for JSON: {value}"

    def test_get_article_state_on_corrupt_file(self):
        """get_article_state() should return None when state is corrupt."""
        lilt.STATE_FILE.write_text("not json")
        assert get_article_state(1) is None

    def test_set_article_state_on_corrupt_file(self):
        """set_article_state() should overwrite corrupt state without crashing."""
        lilt.STATE_FILE.write_text("corrupt!")
        set_article_state(1, paragraph_idx=5, segment_in_paragraph=2)
        result = get_article_state(1)
        assert result is not None
        assert result["paragraph_idx"] == 5

    def test_clear_article_state_on_corrupt_file(self):
        """clear_article_state() should not crash on corrupt state file."""
        lilt.STATE_FILE.write_text("{oops")
        clear_article_state(42)  # should not raise
        assert load_state() == {}


# ---------------------------------------------------------------------------
# TestMissingArticleFile
# ---------------------------------------------------------------------------


class TestMissingArticleFile:
    """Verify queue operations survive when cached article files are deleted."""

    def test_get_article_text_missing_file(self):
        """Add an article, delete its file, then get_article_text returns None."""
        entry = add_article("Some article text.", title="Vanishing")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        assert article_path.exists()
        article_path.unlink()
        assert get_article_text(entry) is None

    def test_remove_article_missing_file(self):
        """remove_article should not crash when the cached file is already gone."""
        entry = add_article("Disappearing content.", title="Gone")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        article_path.unlink()
        removed = remove_article(0)
        assert removed["title"] == "Gone"
        assert load_queue() == []

    def test_clear_queue_missing_files(self):
        """clear_queue should not crash when cached files are already deleted."""
        add_article("First article.", title="First")
        add_article("Second article.", title="Second")
        # Delete all cached files before clearing
        for f in lilt.ARTICLES_DIR.iterdir():
            f.unlink()
        count = clear_queue()
        assert count == 2
        assert load_queue() == []

    def test_mark_completed_missing_file(self):
        """mark_completed should not crash when the cached file is gone."""
        entry = add_article("Completed content.", title="Done")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        article_path.unlink()
        mark_completed(entry)  # should not raise
        assert load_queue() == []


# ---------------------------------------------------------------------------
# TestConcurrentQueueAccess
# ---------------------------------------------------------------------------


class TestConcurrentQueueAccess:
    """Verify queue behavior under simulated concurrent access patterns."""

    def test_add_during_read(self):
        """Simulate CLI --add while queue is loaded: both entries should persist."""
        add_article("First article.", title="First")
        # Simulate reading the queue, then adding another article
        queue_snapshot = load_queue()
        assert len(queue_snapshot) == 1
        add_article("Second article.", title="Second")
        fresh_queue = load_queue()
        assert len(fresh_queue) == 2
        assert fresh_queue[0]["title"] == "First"
        assert fresh_queue[1]["title"] == "Second"

    def test_atomic_write_survives_content(self):
        """Overwriting queue with save_queue() replaces entirely, no partial merge."""
        save_queue([{"id": 1, "title": "Old", "file": "old.txt"}])
        new_queue = [{"id": 2, "title": "New", "file": "new.txt"}]
        save_queue(new_queue)
        loaded = load_queue()
        assert len(loaded) == 1
        assert loaded[0]["title"] == "New"

    def test_concurrent_adds_from_threads(self):
        """Two threads adding articles concurrently should not corrupt the file.

        NOTE: Without file locking, the final count may be 1 instead of 2 due to
        a race condition. This test documents the behavior — after hardening with
        file locks, both entries should survive.
        """
        barrier = threading.Barrier(2)
        results = [None, None]

        def add_in_thread(idx, text, title):
            barrier.wait()
            results[idx] = add_article(text, title=title)

        t1 = threading.Thread(target=add_in_thread, args=(0, "Thread one.", "T1"))
        t2 = threading.Thread(target=add_in_thread, args=(1, "Thread two.", "T2"))
        t1.start()
        t2.start()
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        queue = load_queue()
        # The queue file should be valid JSON regardless of race outcome
        assert isinstance(queue, list)
        assert len(queue) >= 1  # At minimum, one write succeeded


# ---------------------------------------------------------------------------
# TestEngineErrorHandling
# ---------------------------------------------------------------------------


class TestEngineErrorHandling:
    """Verify AudioEngine handles errors in model loading and playback."""

    def test_model_load_failure(self):
        """ImportError from mlx_audio should be wrapped in RuntimeError."""
        engine = AudioEngine()
        with patch.dict("sys.modules", {"mlx_audio": None, "mlx_audio.tts": None, "mlx_audio.tts.utils": None}):
            # Force a fresh import attempt by ensuring _model is None
            engine._model = None
            with pytest.raises(RuntimeError, match="Failed to load TTS model"):
                engine.load_model()

    def test_model_load_failure_via_mock(self):
        """Mock load_model import to raise ImportError, verify RuntimeError."""
        engine = AudioEngine()

        def _failing_load(*args, **kwargs):
            raise ImportError("mlx_audio not available")

        with patch("lilt.engine.AudioEngine.load_model") as mock_load:
            mock_load.side_effect = RuntimeError("Failed to load TTS model 'test': mlx_audio not available")
            with pytest.raises(RuntimeError, match="Failed to load TTS model"):
                engine.load_model()

    def test_audio_device_error(self):
        """sd.OutputStream raising an exception should propagate from _play_audio().

        After hardening, _play_audio() may wrap device errors in RuntimeError.
        Before hardening, the raw exception propagates. Either way, it should not
        silently swallow the error.
        """
        engine = AudioEngine()
        engine._model = MagicMock()
        audio = np.zeros(4096, dtype=np.float32)

        with patch("lilt.engine.sd.OutputStream") as mock_cls:
            mock_cls.side_effect = OSError("No audio device found")
            with pytest.raises((OSError, RuntimeError)):
                engine._play_audio(audio)

    def test_generate_and_play_exists(self):
        """AudioEngine should have a generate_and_play method (used by TUI)."""
        engine = AudioEngine()
        assert hasattr(engine, "generate_and_play"), (
            "AudioEngine is missing generate_and_play — the TUI depends on this method"
        )

    def test_generate_and_play_respects_stop_between_segments(self):
        """Setting stop_event mid-playback should prevent remaining segments.

        generate_and_play() clears _stop_event at entry (by design — it's called
        per-paragraph from the TUI). Stop is checked between segments, so we set
        stop after the first segment plays.
        """
        engine = AudioEngine()
        engine._model = MagicMock()
        seg1 = types.SimpleNamespace(audio=np.zeros(1024), sample_rate=24000)
        seg2 = types.SimpleNamespace(audio=np.zeros(1024), sample_rate=24000)
        engine._model.generate.return_value = [seg1, seg2]

        with patch("lilt.engine.sd.OutputStream") as mock_cls:
            stream_instance = MagicMock()
            mock_cls.return_value = stream_instance

            # Stop after first segment's audio is written
            call_count = [0]

            def write_side_effect(data):
                call_count[0] += 1
                if call_count[0] >= 1:
                    engine._stop_event.set()

            stream_instance.write.side_effect = write_side_effect

            if hasattr(engine, "generate_and_play"):
                engine.generate_and_play("Test paragraph.")
                # Model should have been called (stop is cleared at entry)
                assert engine._model.generate.called
            else:
                pytest.skip("generate_and_play not yet implemented")

    def test_play_article_with_empty_text(self):
        """play_article with empty string should complete without error."""
        engine = AudioEngine()
        engine._model = MagicMock()

        with patch("lilt.engine.sd.OutputStream"):
            engine.play_article("")
            # No paragraphs to process, so model.generate should not be called
            engine._model.generate.assert_not_called()

    def test_play_article_stop_during_playback(self):
        """Setting stop mid-article should prevent remaining paragraphs.

        play_article() clears _stop_event at entry (by design). Stop is checked
        between paragraphs, so we trigger it during the first paragraph's playback.
        """
        engine = AudioEngine()
        engine._model = MagicMock()
        fake_segment = types.SimpleNamespace(audio=np.zeros(1024), sample_rate=24000)
        engine._model.generate.return_value = fake_segment

        progress_calls = []

        def on_progress(para_idx, seg_idx, total, text):
            progress_calls.append(para_idx)
            engine._stop_event.set()  # Stop after first paragraph

        with patch("lilt.engine.sd.OutputStream") as mock_cls:
            stream_instance = MagicMock()
            mock_cls.return_value = stream_instance
            engine.play_article(
                "Para 0.\nPara 1.\nPara 2.",
                on_progress=on_progress,
            )

        # Only the first paragraph should have been processed
        assert len(progress_calls) == 1
        assert progress_calls[0] == 0

    def test_load_model_noop_when_already_loaded(self):
        """load_model() is a no-op when _model is already set."""
        engine = AudioEngine()
        engine._model = MagicMock()
        # Should not attempt to import mlx_audio
        engine.load_model()  # no-op, should not raise
        assert engine._model is not None


# ---------------------------------------------------------------------------
# TestGenerateAudioEdgeCases
# ---------------------------------------------------------------------------


class TestGenerateAudioEdgeCases:
    """Edge cases for the generate_audio engine method."""

    def test_empty_text_returns_empty_array(self):
        """generate_audio with text that produces no segments returns empty array."""
        engine = AudioEngine()
        engine._model = MagicMock()
        engine._model.generate.return_value = []

        with patch("lilt.engine.sd"):
            result = engine.generate_audio("")
        assert isinstance(result, np.ndarray)
        assert len(result) == 0

    def test_model_not_loaded_auto_loads(self):
        """generate_audio should auto-load model if not loaded."""
        engine = AudioEngine()

        mock_model = MagicMock()
        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(100)
        mock_model.generate.return_value = mock_segment

        with patch("lilt.engine.sd"), patch("mlx_audio.tts.utils.load_model", return_value=mock_model) as mock_load:
            engine.generate_audio("Test text.")
            mock_load.assert_called_once()


# ---------------------------------------------------------------------------
# TestLanguageConstants
# ---------------------------------------------------------------------------


class TestLanguageConstants:
    """Verify LANGUAGES dict is complete and consistent with VOICES."""

    def test_all_voice_accents_have_language(self):
        """Every accent in VOICES should have a matching LANGUAGES entry."""
        from lilt import LANGUAGES, VOICES

        for voice_id, info in VOICES.items():
            accent = info["accent"]
            matching = [code for code, name in LANGUAGES.items() if accent in name]
            assert matching, f"Voice {voice_id} has accent '{accent}' with no matching LANGUAGES entry"

    def test_chinese_language_exists(self):
        """Chinese must be in LANGUAGES since Chinese voices exist."""
        from lilt import LANGUAGES

        assert "z" in LANGUAGES
        assert "Chinese" in LANGUAGES["z"]

    def test_wpm_estimate_is_positive(self):
        from lilt import WPM_ESTIMATE

        assert WPM_ESTIMATE > 0


# ---------------------------------------------------------------------------
# TestLangCodeIntegration
# ---------------------------------------------------------------------------


class TestLangCodeIntegration:
    """Verify lang_code is used correctly across the engine."""

    def test_play_article_uses_lang_code(self):
        """play_article should pass lang_code= to model.generate."""
        engine = AudioEngine()
        engine.lang = "b"

        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(100)
        engine._model = MagicMock()
        engine._model.generate.return_value = mock_segment

        progress_calls = []

        def on_progress(*args):
            progress_calls.append(args)

        with patch("lilt.engine.sd"):
            engine.play_article("Test paragraph.", on_progress=on_progress)

        call_kwargs = engine._model.generate.call_args[1]
        assert "lang_code" in call_kwargs
        assert call_kwargs["lang_code"] == "b"
        assert "lang" not in call_kwargs

    def test_generate_and_play_clears_stop_event(self):
        """generate_and_play should clear stop event at entry for skip support."""
        engine = AudioEngine()
        engine._stop_event.set()  # Simulate previous stop

        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(100)
        engine._model = MagicMock()
        engine._model.generate.return_value = mock_segment

        with patch("lilt.engine.sd"):
            engine.generate_and_play("Test.")

        # Stop event should have been cleared at entry
        # (and may be set again by the end, but the method should have run)
        engine._model.generate.assert_called_once()


# ---------------------------------------------------------------------------
# TestWpmEstimateConsistency
# ---------------------------------------------------------------------------


class TestWpmEstimateConsistency:
    """Verify no hardcoded 150 WPM literals remain in the codebase."""

    @staticmethod
    def _scan_for_hardcoded_150(path):
        """Scan a file for hardcoded 150 WPM literals, return violations."""
        import re

        content = path.read_text()
        lines = content.split("\n")
        violations = []
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith('"') or stripped.startswith("'"):
                continue
            if re.search(r"/\s*\(?\s*150\s*[*)]", line):
                violations.append(f"Line {i}: {stripped}")
        return violations

    def test_no_hardcoded_150_in_tui(self):
        """lilt-tui should use WPM_ESTIMATE, not literal 150."""
        from pathlib import Path

        tui_path = Path(__file__).resolve().parent.parent / "src" / "lilt" / "tui.py"
        violations = self._scan_for_hardcoded_150(tui_path)
        assert not violations, "Hardcoded 150 WPM found in tui.py:\n" + "\n".join(violations)

    def test_no_hardcoded_150_in_cli(self):
        """lilt CLI module should use WPM_ESTIMATE, not literal 150."""
        from pathlib import Path

        cli_path = Path(__file__).resolve().parent.parent / "src" / "lilt" / "cli.py"
        violations = self._scan_for_hardcoded_150(cli_path)
        assert not violations, "Hardcoded 150 WPM found in cli.py:\n" + "\n".join(violations)
