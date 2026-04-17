"""Tests for wilted.engine — TTS playback engine with pause/resume/stop."""

import os
import sys
import threading
import types
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

# Ensure sounddevice is mockable without triggering PortAudio initialization
if "sounddevice" not in sys.modules:
    _sd = types.ModuleType("sounddevice")
    _sd.OutputStream = MagicMock()
    _sd.PortAudioError = OSError
    sys.modules["sounddevice"] = _sd

# Ensure mlx_audio.audio_io is mockable even if mlx_audio isn't installed
if "mlx_audio" not in sys.modules:
    sys.modules["mlx_audio"] = types.ModuleType("mlx_audio")
if "mlx_audio.audio_io" not in sys.modules:
    _audio_io = types.ModuleType("mlx_audio.audio_io")
    _audio_io.write = lambda *a, **kw: None  # stub for test_cli patching
    sys.modules["mlx_audio.audio_io"] = _audio_io

from wilted.engine import AudioEngine, _normalize_segments


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
    with patch("sounddevice.OutputStream") as mock_cls:
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


class TestPlayAudioPublic:
    """Tests for the public play_audio() method (cached audio playback)."""

    def test_clears_stop_event(self, engine, mock_stream):
        """play_audio clears _stop_event so previous skip doesn't block."""
        engine._stop_event.set()
        audio = np.zeros(1024, dtype=np.float32)
        engine.play_audio(audio)
        assert not engine._stop_event.is_set()

    def test_plays_audio_through_stream(self, engine, mock_stream):
        """play_audio opens, writes to, and closes the OutputStream."""
        audio = np.zeros(2048, dtype=np.float32)
        engine.play_audio(audio)
        assert mock_stream.start.called
        assert mock_stream.write.called
        assert mock_stream.stop.called

    def test_respects_stop_during_playback(self, engine, mock_stream):
        """Stopping mid-play_audio exits the write loop."""
        audio = np.zeros(8192, dtype=np.float32)
        call_count = [0]

        def write_side_effect(data):
            call_count[0] += 1
            if call_count[0] >= 2:
                engine._stop_event.set()

        mock_stream.write.side_effect = write_side_effect
        engine.play_audio(audio)
        # Should have stopped after ~2 blocks, not played the full 8 blocks
        assert call_count[0] < 8


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


class TestModelLoading:
    def test_load_model_disables_hf_xet_by_default(self):
        """load_model should disable xet and enable offline mode when cached."""
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=True),
        ):
            engine.load_model()
            assert os.environ["HF_HUB_DISABLE_XET"] == "1"

        assert engine._model == "mock-model"
        mock_load_model.assert_called_once_with(engine.model_name)

    def test_load_model_enables_offline_when_cached(self):
        """load_model sets HF_HUB_OFFLINE=1 when the model snapshot dir exists."""
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=True),
        ):
            engine.load_model()
            assert os.environ.get("HF_HUB_OFFLINE") == "1"

    def test_load_model_skips_offline_when_not_cached(self):
        """load_model should not set offline mode if model cache is missing."""
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=False),
        ):
            engine.load_model()
            assert "HF_HUB_OFFLINE" not in os.environ
            # xet should still be disabled even without cache
            assert os.environ["HF_HUB_DISABLE_XET"] == "1"

    def test_load_model_respects_xet_opt_in(self):
        """Setting WILTED_ENABLE_HF_XET should skip the safety override."""
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model

        with (
            patch.dict(
                os.environ,
                {"WILTED_ENABLE_HF_XET": "1"},
                clear=True,
            ),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                },
            ),
        ):
            engine.load_model()
            # Check inside the controlled env — the real shell may already
            # have the var from a previous wilted run.
            assert "HF_HUB_DISABLE_XET" not in os.environ

        assert engine._model == "mock-model"
        mock_load_model.assert_called_once_with(engine.model_name)


class TestLoadModelThreadSafety:
    def test_concurrent_load_model_only_loads_once(self):
        """Two threads calling load_model simultaneously should only load once."""
        import time

        engine = AudioEngine()
        load_count = 0
        gate = threading.Event()

        def fake_load(name):
            nonlocal load_count
            load_count += 1
            gate.set()  # Signal that we're inside the load
            time.sleep(0.1)  # Hold the lock to give the other thread time to arrive
            return MagicMock()

        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = fake_load

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=True),
        ):
            t1 = threading.Thread(target=engine.load_model)
            t1.start()
            gate.wait(timeout=2)  # Wait until t1 is inside fake_load
            t2 = threading.Thread(target=engine.load_model)
            t2.start()
            t1.join(timeout=5)
            t2.join(timeout=5)

        assert load_count == 1
        assert engine._model is not None


class TestGenerateAudio:
    def test_returns_numpy_array(self):
        # Mock model.generate to return a single segment
        engine = AudioEngine()
        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(1024)
        mock_segment.sample_rate = 24000
        engine._model = MagicMock()
        engine._model.generate.return_value = mock_segment

        with patch("sounddevice.OutputStream"):
            result = engine.generate_audio("Hello world.")
        assert isinstance(result, np.ndarray)
        assert len(result) == 1024

    def test_concatenates_segments(self):
        engine = AudioEngine()
        seg1 = MagicMock()
        seg1.audio = np.zeros(512)
        seg2 = MagicMock()
        seg2.audio = np.ones(512)
        engine._model = MagicMock()
        engine._model.generate.return_value = [seg1, seg2]

        with patch("sounddevice.OutputStream"):
            result = engine.generate_audio("Long paragraph.")
        assert len(result) == 1024

    def test_model_failure_raises_runtime_error(self):
        engine = AudioEngine()
        engine._model = MagicMock()
        engine._model.generate.side_effect = Exception("Generation failed")

        with patch("sounddevice.OutputStream"):
            with pytest.raises(RuntimeError, match="TTS generation failed"):
                engine.generate_audio("Test text.")

    def test_empty_result(self):
        engine = AudioEngine()
        engine._model = MagicMock()
        engine._model.generate.return_value = []

        with patch("sounddevice.OutputStream"):
            result = engine.generate_audio("Empty.")
        assert isinstance(result, np.ndarray)
        assert len(result) == 0

    def test_concurrent_generate_audio_is_serialized(self):
        """Concurrent generate_audio calls must not overlap model.generate."""
        engine = AudioEngine()
        overlap_count = 0
        active_calls = 0
        active_lock = threading.Lock()
        start_gate = threading.Event()

        def fake_generate(*args, **kwargs):
            nonlocal overlap_count, active_calls
            start_gate.wait(timeout=2)
            with active_lock:
                active_calls += 1
                if active_calls > 1:
                    overlap_count += 1
            try:
                threading.Event().wait(0.05)
                return _make_fake_segment(n_samples=128)
            finally:
                with active_lock:
                    active_calls -= 1

        engine._model = MagicMock()
        engine._model.generate.side_effect = fake_generate

        results = []

        def worker():
            results.append(engine.generate_audio("Concurrent text"))

        t1 = threading.Thread(target=worker)
        t2 = threading.Thread(target=worker)
        t1.start()
        t2.start()
        start_gate.set()
        t1.join(timeout=2)
        t2.join(timeout=2)

        assert overlap_count == 0
        assert len(results) == 2
        assert all(isinstance(result, np.ndarray) for result in results)


class TestNormalizeSegments:
    def test_single_result_wrapped_in_list(self):
        result = MagicMock()
        result.audio = np.zeros(1)
        segments = _normalize_segments(result)
        assert segments == [result]

    def test_list_result_passed_through(self):
        result = [MagicMock(), MagicMock()]
        segments = _normalize_segments(result)
        assert segments is result

    def test_generator_result_passed_through(self):
        seg1 = MagicMock()
        seg1.audio = np.zeros(1)
        seg2 = MagicMock()
        seg2.audio = np.zeros(1)
        result = (segment for segment in [seg1, seg2])
        segments = _normalize_segments(result)
        assert list(segments) == [seg1, seg2]


class TestLangCodeParameter:
    def test_generate_and_play_uses_lang_code(self):
        engine = AudioEngine()
        engine.lang = "b"
        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(100)
        engine._model = MagicMock()
        engine._model.generate.return_value = mock_segment

        with patch("sounddevice.OutputStream"):
            engine.generate_and_play("Test.")

        call_kwargs = engine._model.generate.call_args[1]
        assert "lang_code" in call_kwargs

    def test_generate_audio_handles_generator_result(self):
        engine = AudioEngine()
        seg1 = MagicMock()
        seg1.audio = np.zeros(256)
        seg2 = MagicMock()
        seg2.audio = np.ones(256)
        engine._model = MagicMock()
        engine._model.generate.return_value = (segment for segment in [seg1, seg2])

        with patch("sounddevice.OutputStream"):
            result = engine.generate_audio("Test generator output.")

        assert isinstance(result, np.ndarray)
        assert len(result) == 512

    def test_generate_and_play_handles_generator_result(self):
        engine = AudioEngine()
        seg1 = MagicMock()
        seg1.audio = np.zeros(256)
        seg2 = MagicMock()
        seg2.audio = np.ones(256)
        engine._model = MagicMock()
        engine._model.generate.return_value = (segment for segment in [seg1, seg2])

        with patch("sounddevice.OutputStream") as mock_cls:
            stream_instance = MagicMock()
            mock_cls.return_value = stream_instance
            engine.generate_and_play("Test generator playback.")

        assert stream_instance.write.call_count >= 2

    def test_generate_and_play_materializes_generator_inside_lock(self):
        """Lazy generator evaluation must complete before another call enters generate."""
        engine = AudioEngine()
        overlap_count = 0
        active_calls = 0
        active_lock = threading.Lock()
        start_gate = threading.Event()

        def fake_generate(*args, **kwargs):
            start_gate.wait(timeout=2)

            def segments():
                nonlocal overlap_count, active_calls
                with active_lock:
                    active_calls += 1
                    if active_calls > 1:
                        overlap_count += 1
                try:
                    threading.Event().wait(0.05)
                    yield _make_fake_segment(n_samples=64)
                finally:
                    with active_lock:
                        active_calls -= 1

            return segments()

        engine._model = MagicMock()
        engine._model.generate.side_effect = fake_generate

        with patch.object(engine, "_play_audio"):
            t1 = threading.Thread(target=lambda: engine.generate_and_play("One"))
            t2 = threading.Thread(target=lambda: engine.generate_and_play("Two"))
            t1.start()
            t2.start()
            start_gate.set()
            t1.join(timeout=2)
            t2.join(timeout=2)

        assert overlap_count == 0

    def test_play_article_materializes_generator_inside_lock(self):
        """play_article must not leave lazy segment evaluation outside _model_lock."""
        engine = AudioEngine()
        overlap_count = 0
        active_calls = 0
        active_lock = threading.Lock()
        start_gate = threading.Event()

        def fake_generate(*args, **kwargs):
            start_gate.wait(timeout=2)

            def segments():
                nonlocal overlap_count, active_calls
                with active_lock:
                    active_calls += 1
                    if active_calls > 1:
                        overlap_count += 1
                try:
                    threading.Event().wait(0.05)
                    yield _make_fake_segment(n_samples=64)
                finally:
                    with active_lock:
                        active_calls -= 1

            return segments()

        engine._model = MagicMock()
        engine._model.generate.side_effect = fake_generate

        with patch.object(engine, "_play_audio"):
            t1 = threading.Thread(target=lambda: engine.play_article("Paragraph one."))
            t2 = threading.Thread(target=lambda: engine.play_article("Paragraph two."))
            t1.start()
            t2.start()
            start_gate.set()
            t1.join(timeout=2)
            t2.join(timeout=2)

        assert overlap_count == 0

    def test_generate_audio_uses_lang_code(self):
        engine = AudioEngine()
        engine.lang = "j"
        mock_segment = MagicMock()
        mock_segment.audio = np.zeros(100)
        engine._model = MagicMock()
        engine._model.generate.return_value = mock_segment

        with patch("sounddevice.OutputStream"):
            engine.generate_audio("Test.")

        call_kwargs = engine._model.generate.call_args[1]
        assert "lang_code" in call_kwargs
        assert call_kwargs["lang_code"] == "j"
        assert "lang" not in call_kwargs  # Should NOT use 'lang='


class TestExportToWav:
    def test_normal_export(self, engine, mock_stream, tmp_path):
        """export_to_wav generates audio for each chunk and writes WAV."""
        from wilted.engine import export_to_wav

        filepath = str(tmp_path / "output.wav")
        with patch("mlx_audio.audio_io.write", create=True) as mock_write:
            export_to_wav(engine, ["Chunk one.", "Chunk two."], filepath)

        assert engine._model.generate.call_count == 2
        mock_write.assert_called_once()
        assert mock_write.call_args[0][0] == filepath

    def test_on_progress_callback(self, engine, mock_stream, tmp_path):
        """export_to_wav calls on_progress with (current, total)."""
        from wilted.engine import export_to_wav

        progress_calls = []
        filepath = str(tmp_path / "output.wav")
        with patch("mlx_audio.audio_io.write", create=True):
            export_to_wav(
                engine,
                ["A.", "B.", "C."],
                filepath,
                on_progress=lambda cur, tot: progress_calls.append((cur, tot)),
            )

        assert progress_calls == [(1, 3), (2, 3), (3, 3)]

    def test_empty_chunks_raises(self, engine):
        """export_to_wav raises ValueError for empty chunk list."""
        from wilted.engine import export_to_wav

        with pytest.raises(ValueError, match="No text chunks"):
            export_to_wav(engine, [], "output.wav")

    def test_no_audio_generated_raises(self, engine, mock_stream, tmp_path):
        """export_to_wav raises ValueError when model produces no audio."""
        from wilted.engine import export_to_wav

        engine._model.generate.return_value = []  # No segments
        filepath = str(tmp_path / "output.wav")
        with pytest.raises(ValueError, match="No audio generated"):
            export_to_wav(engine, ["Some text."], filepath)

    def test_should_cancel_aborts(self, engine, mock_stream, tmp_path):
        """export_to_wav raises InterruptedError when should_cancel returns True."""
        from wilted.engine import export_to_wav

        filepath = str(tmp_path / "output.wav")
        with pytest.raises(InterruptedError, match="Export cancelled"):
            export_to_wav(
                engine,
                ["Chunk one.", "Chunk two."],
                filepath,
                should_cancel=lambda: True,
            )
        # Model should not have been called — cancel checked before generation
        engine._model.generate.assert_not_called()
