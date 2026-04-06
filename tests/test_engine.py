"""Tests for lilt.engine — TTS playback engine with pause/resume/stop."""

import threading
import types

import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from lilt.engine import AudioEngine


def _make_fake_segment(n_samples=1024, sample_rate=24000):
    """Create a fake model.generate() result with .audio and .sample_rate."""
    seg = types.SimpleNamespace()
    seg.audio = np.zeros(n_samples)
    seg.sample_rate = sample_rate
    return seg


@pytest.fixture
def engine():
    """Create an AudioEngine with a mock model pre-loaded."""
    eng = AudioEngine()
    eng._model = MagicMock()
    eng._model.generate.return_value = _make_fake_segment(n_samples=4096)
    return eng


@pytest.fixture
def mock_stream():
    """Patch sounddevice.OutputStream to a no-op mock."""
    with patch("lilt.engine.sd.OutputStream") as mock_cls:
        stream_instance = MagicMock()
        mock_cls.return_value = stream_instance
        yield stream_instance


class TestPlayAudio:
    def test_stop_event_breaks_loop(self, engine, mock_stream):
        """Setting stop_event before play exits immediately."""
        engine._stop_event.set()
        audio = np.zeros(4096, dtype=np.float32)
        engine._play_audio(audio)
        # Should have written zero or very few blocks
        assert mock_stream.write.call_count == 0

    def test_pause_event_blocks(self, engine, mock_stream):
        """Clearing pause_event prevents the write loop from advancing."""
        engine._pause_event.clear()
        audio = np.zeros(4096, dtype=np.float32)

        result = [False]

        def play_in_thread():
            engine._play_audio(audio)
            result[0] = True

        t = threading.Thread(target=play_in_thread)
        t.start()
        # Give it a moment — it should be blocked on _pause_event.wait()
        t.join(timeout=0.3)
        assert t.is_alive(), "Play loop should be blocked while paused"
        assert mock_stream.write.call_count == 0

        # Unblock by stopping
        engine._stop_event.set()
        engine._pause_event.set()
        t.join(timeout=2.0)
        assert not t.is_alive()

    def test_sample_offset_saved_on_stop(self, engine, mock_stream):
        """Stopping mid-playback saves _sample_offset > 0."""
        audio = np.zeros(8192, dtype=np.float32)
        block_size = 1024
        # After 2 blocks, trigger stop
        call_count = [0]
        original_write = mock_stream.write

        def write_side_effect(data):
            call_count[0] += 1
            if call_count[0] >= 2:
                engine._stop_event.set()

        mock_stream.write.side_effect = write_side_effect

        engine._play_audio(audio)
        # At least 2 blocks written before stop, so offset should be >= 2*1024
        assert engine._sample_offset >= 2 * block_size
        assert engine._sample_offset < len(audio)


class TestPlayArticle:
    def test_calls_on_progress(self, engine, mock_stream):
        """on_progress is called with correct paragraph indices."""
        text = "First paragraph.\nSecond paragraph.\nThird paragraph."
        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append((para_idx, seg_idx, total, current_text))

        engine.play_article(text, on_progress=on_progress)

        assert len(progress_calls) == 3
        assert progress_calls[0] == (0, 0, 3, "First paragraph.")
        assert progress_calls[1] == (1, 0, 3, "Second paragraph.")
        assert progress_calls[2] == (2, 0, 3, "Third paragraph.")

    def test_respects_start_paragraph(self, engine, mock_stream):
        """Starting at paragraph 2 skips earlier paragraphs."""
        text = "Para 0.\nPara 1.\nPara 2.\nPara 3."
        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append((para_idx, seg_idx, total, current_text))

        engine.play_article(text, start_paragraph=2, on_progress=on_progress)

        assert len(progress_calls) == 2
        assert progress_calls[0][0] == 2
        assert progress_calls[1][0] == 3

    def test_stop_mid_article(self, engine, mock_stream):
        """Setting stop_event after first paragraph prevents remaining ones."""
        text = "Para 0.\nPara 1.\nPara 2.\nPara 3."
        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append(para_idx)
            # Stop after first paragraph completes
            engine._stop_event.set()

        engine.play_article(text, on_progress=on_progress)

        # Only the first paragraph should have been fully played
        assert len(progress_calls) == 1
        assert progress_calls[0] == 0


class TestControls:
    def test_pause_clears_event(self):
        """pause() clears _pause_event (blocks the write loop)."""
        engine = AudioEngine()
        assert engine._pause_event.is_set()
        engine.pause()
        assert not engine._pause_event.is_set()

    def test_resume_sets_event(self):
        """resume() sets _pause_event after pause."""
        engine = AudioEngine()
        engine.pause()
        assert not engine._pause_event.is_set()
        engine.resume()
        assert engine._pause_event.is_set()

    def test_stop_sets_event(self):
        """stop() sets _stop_event."""
        engine = AudioEngine()
        assert not engine._stop_event.is_set()
        engine.stop()
        assert engine._stop_event.is_set()

    def test_stop_unblocks_pause(self):
        """stop() also sets _pause_event so a paused loop can exit."""
        engine = AudioEngine()
        engine.pause()
        assert not engine._pause_event.is_set()
        engine.stop()
        assert engine._pause_event.is_set()
        assert engine._stop_event.is_set()

    def test_is_paused_property(self):
        """is_paused reflects pause/resume state."""
        engine = AudioEngine()
        assert not engine.is_paused
        engine.pause()
        assert engine.is_paused
        engine.resume()
        assert not engine.is_paused

    def test_is_playing_default_false(self):
        """is_playing is False before play_article is called."""
        engine = AudioEngine()
        assert not engine.is_playing
