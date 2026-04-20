"""Tests for wilted.engine — TTS playback engine with pause/resume/stop."""

import os
import threading
import types
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from wilted.engine import AudioEngine

pytestmark = pytest.mark.usefixtures("stub_audio_modules")


def _make_fake_segment(n_samples=1024, sample_rate=24000):
    """Create a fake model.generate() result with .audio and .sample_rate."""
    seg = types.SimpleNamespace()
    seg.audio = np.zeros(n_samples)
    seg.sample_rate = sample_rate
    return seg


@pytest.fixture
def engine(stub_audio_modules):
    """Create an AudioEngine with a mock model pre-loaded."""
    eng = AudioEngine()
    eng._model = MagicMock()
    eng._model.generate.return_value = _make_fake_segment(n_samples=4096)
    return eng


@pytest.fixture
def mock_stream(stub_audio_modules):
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

    def test_plays_audio_through_stream(self, engine, mock_stream):
        """play_audio opens, writes to, and closes the OutputStream."""
        audio = np.zeros(2048, dtype=np.float32)
        engine.play_audio(audio)
        assert mock_stream.start.called
        assert mock_stream.write.called
        assert mock_stream.stop.called


class TestControls:
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


def _make_transcript_segment(start_s: float, end_s: float, text: str):
    """Create a duck-typed transcript segment with start_s, end_s, text."""
    return types.SimpleNamespace(start_s=start_s, end_s=end_s, text=text)


def _make_ffmpeg_pcm(n_samples: int = 4800) -> bytes:
    """Generate raw PCM float32 bytes as ffmpeg would produce."""
    audio = np.sin(np.linspace(0, 2 * np.pi * 440, n_samples)).astype(np.float32)
    return audio.tobytes()


@pytest.fixture
def mock_subprocess_ffmpeg():
    """Patch subprocess.run to simulate ffmpeg decoding."""
    pcm_data = _make_ffmpeg_pcm(n_samples=24000)  # 1 second at 24kHz
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = pcm_data
    mock_result.stderr = b""
    with patch("wilted.engine.subprocess.run", return_value=mock_result) as mock_run:
        yield mock_run


class TestPlayFile:
    def test_play_file_decodes_and_plays(self, engine, mock_stream, mock_subprocess_ffmpeg, tmp_path):
        """play_file decodes via ffmpeg and calls _play_audio with float32 array."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()  # File must exist for the path check

        with patch.object(engine, "_play_audio") as mock_play:
            engine.play_file(wav_file)

        mock_subprocess_ffmpeg.assert_called_once()
        cmd = mock_subprocess_ffmpeg.call_args[0][0]
        assert cmd[0] == "ffmpeg"
        assert "-f" in cmd
        assert "f32le" in cmd

        mock_play.assert_called_once()
        played_audio = mock_play.call_args[0][0]
        assert played_audio.dtype == np.float32
        assert len(played_audio) == 24000

    def test_play_file_with_segments(self, engine, mock_stream, mock_subprocess_ffmpeg, tmp_path):
        """on_progress is called for each transcript segment."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        segments = [
            _make_transcript_segment(0.0, 0.3, "First segment."),
            _make_transcript_segment(0.3, 0.7, "Second segment."),
            _make_transcript_segment(0.7, 1.0, "Third segment."),
        ]
        progress_calls = []

        def on_progress(seg_idx, total, text):
            progress_calls.append((seg_idx, total, text))

        with patch.object(engine, "_play_audio"):
            engine.play_file(wav_file, transcript_segments=segments, on_progress=on_progress)

        assert len(progress_calls) == 3
        assert progress_calls[0] == (0, 3, "First segment.")
        assert progress_calls[1] == (1, 3, "Second segment.")
        assert progress_calls[2] == (2, 3, "Third segment.")

    def test_play_file_resume_from_segment(self, engine, mock_stream, mock_subprocess_ffmpeg, tmp_path):
        """start_segment=2 skips earlier segments."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        segments = [
            _make_transcript_segment(0.0, 0.25, "Seg 0"),
            _make_transcript_segment(0.25, 0.5, "Seg 1"),
            _make_transcript_segment(0.5, 0.75, "Seg 2"),
            _make_transcript_segment(0.75, 1.0, "Seg 3"),
        ]
        progress_calls = []

        def on_progress(seg_idx, total, text):
            progress_calls.append((seg_idx, total, text))

        with patch.object(engine, "_play_audio") as mock_play:
            engine.play_file(wav_file, transcript_segments=segments, start_segment=2, on_progress=on_progress)

        # Only segments 2 and 3 should have been played
        assert len(progress_calls) == 2
        assert progress_calls[0] == (2, 4, "Seg 2")
        assert progress_calls[1] == (3, 4, "Seg 3")
        assert mock_play.call_count == 2

        # Verify segment_idx was tracked
        assert engine.current_segment_idx == 3

    def test_play_file_missing_file(self, engine):
        """FileNotFoundError raised for nonexistent file."""
        with pytest.raises(FileNotFoundError, match="Audio file not found"):
            engine.play_file("/nonexistent/path/audio.mp3")

    def test_play_file_stop_during_playback(self, engine, mock_stream, mock_subprocess_ffmpeg, tmp_path):
        """Setting stop_event during segment playback causes early exit."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        segments = [
            _make_transcript_segment(0.0, 0.25, "Seg 0"),
            _make_transcript_segment(0.25, 0.5, "Seg 1"),
            _make_transcript_segment(0.5, 0.75, "Seg 2"),
            _make_transcript_segment(0.75, 1.0, "Seg 3"),
        ]
        progress_calls = []

        def on_progress(seg_idx, total, text):
            progress_calls.append(seg_idx)
            # Stop after first segment completes
            engine._stop_event.set()

        with patch.object(engine, "_play_audio"):
            engine.play_file(wav_file, transcript_segments=segments, on_progress=on_progress)

        # Only the first segment should have completed
        assert len(progress_calls) == 1
        assert progress_calls[0] == 0
        # _playing should be False after exit
        assert not engine.is_playing

    def test_play_file_sets_playing_flag(self, engine, mock_stream, mock_subprocess_ffmpeg, tmp_path):
        """play_file sets _playing=True during playback and False after."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        playing_during = []

        def capture_playing(audio_np):
            playing_during.append(engine.is_playing)
            # Don't actually play (mock_stream handles it), just stop
            engine._stop_event.set()

        with patch.object(engine, "_play_audio", side_effect=capture_playing):
            engine.play_file(wav_file)

        assert playing_during[0] is True
        assert not engine.is_playing

    def test_play_file_ffmpeg_failure(self, engine, tmp_path):
        """RuntimeError raised when ffmpeg returns nonzero exit code."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = b""
        mock_result.stderr = b"Invalid data found when processing input"

        with patch("wilted.engine.subprocess.run", return_value=mock_result):
            with pytest.raises(RuntimeError, match="ffmpeg decode failed"):
                engine.play_file(wav_file)


class TestGetFileDuration:
    def test_get_file_duration(self, engine, tmp_path):
        """get_file_duration returns correct float duration from ffprobe."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = b"42.567890\n"
        mock_result.stderr = b""

        with patch("wilted.engine.subprocess.run", return_value=mock_result) as mock_run:
            duration = engine.get_file_duration(wav_file)

        assert duration == pytest.approx(42.56789)
        mock_run.assert_called_once()
        cmd = mock_run.call_args[0][0]
        assert cmd[0] == "ffprobe"
        assert "-show_entries" in cmd
        assert "format=duration" in cmd

    def test_get_file_duration_ffprobe_failure(self, engine, tmp_path):
        """RuntimeError raised when ffprobe returns nonzero exit code."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = b""
        mock_result.stderr = b"No such file"

        with patch("wilted.engine.subprocess.run", return_value=mock_result):
            with pytest.raises(RuntimeError, match="ffprobe failed"):
                engine.get_file_duration(wav_file)
