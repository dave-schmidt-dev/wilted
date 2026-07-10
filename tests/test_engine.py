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


class _FakeStdout:
    """A fake proc.stdout that hands out a byte buffer in fixed-size reads.

    Records how many read() calls occurred so tests can assert the PCM was
    consumed incrementally (streamed), not slurped in one full-buffer capture.
    """

    def __init__(self, data: bytes):
        self._data = data
        self._pos = 0
        self.read_calls = 0
        self.closed = False

    def read(self, n: int = -1) -> bytes:
        self.read_calls += 1
        if n is None or n < 0:
            chunk = self._data[self._pos :]
            self._pos = len(self._data)
            return chunk
        chunk = self._data[self._pos : self._pos + n]
        self._pos += len(chunk)
        return chunk

    def close(self):
        self.closed = True


class _FakeStderr:
    def __init__(self, data: bytes = b""):
        self._data = data
        self.closed = False

    def read(self, n: int = -1) -> bytes:
        return self._data

    def close(self):
        self.closed = True


class _FakePopen:
    """Minimal subprocess.Popen stand-in for streaming ffmpeg decode tests."""

    def __init__(self, pcm: bytes, returncode: int = 0, stderr: bytes = b""):
        self.stdout = _FakeStdout(pcm)
        self.stderr = _FakeStderr(stderr)
        self._returncode = returncode
        self.returncode = None  # Set on wait(), mirroring real Popen.
        self.killed = False
        self.wait_calls = 0
        self.args = None  # Populated by the patched Popen factory.

    def wait(self, timeout=None):
        self.wait_calls += 1
        self.returncode = self._returncode
        return self.returncode

    def poll(self):
        return self.returncode

    def kill(self):
        self.killed = True
        # A killed process is reaped by the following wait() call.


def _patch_popen(fake: _FakePopen):
    """Patch wilted.engine.subprocess.Popen to return `fake`, capturing argv."""

    def _factory(cmd, *args, **kwargs):
        fake.args = cmd
        return fake

    return patch("wilted.engine.subprocess.Popen", side_effect=_factory)


class TestPlayFileStreaming:
    def test_streams_pcm_incrementally(self, engine, mock_stream, tmp_path):
        """play_file uses Popen and reads PCM in multiple chunk reads (not one capture)."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        n_samples = 24000  # 1 second at 24kHz
        pcm = _make_ffmpeg_pcm(n_samples=n_samples)
        fake = _FakePopen(pcm)

        with _patch_popen(fake) as popen:
            engine.play_file(wav_file)

        # Popen used (streaming), not subprocess.run full-buffer capture.
        popen.assert_called_once()
        cmd = fake.args
        assert cmd[0] == "ffmpeg"
        assert "-f" in cmd and "f32le" in cmd
        assert "pipe:1" in cmd

        # PCM was consumed incrementally: more than one data read (plus the
        # final empty read that signals EOF).
        assert fake.stdout.read_calls > 2

        # All samples reached the output stream (24 blocks of 1024).
        total_written = sum(len(call.args[0]) for call in mock_stream.write.call_args_list)
        assert total_written == n_samples

    def test_peak_resident_is_chunk_sized(self, engine, mock_stream, tmp_path):
        """Each read pulls at most one block worth of float32 (O(chunk), not O(episode))."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        pcm = _make_ffmpeg_pcm(n_samples=8192)
        fake = _FakePopen(pcm)

        # Instrument the read size requested from ffmpeg's stdout.
        requested_sizes = []
        orig_read = fake.stdout.read

        def _tracking_read(n=-1):
            requested_sizes.append(n)
            return orig_read(n)

        fake.stdout.read = _tracking_read

        with _patch_popen(fake):
            engine.play_file(wav_file)

        block_bytes = 1024 * np.dtype(np.float32).itemsize
        assert requested_sizes, "no reads issued"
        assert all(size == block_bytes for size in requested_sizes)

    def test_on_progress_fires_once_per_segment(self, engine, mock_stream, tmp_path):
        """on_progress fires once per segment and current_segment_idx advances."""
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

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=24000))  # 1.0s covers all starts
        with _patch_popen(fake):
            engine.play_file(wav_file, transcript_segments=segments, on_progress=on_progress)

        assert progress_calls == [
            (0, 3, "First segment."),
            (1, 3, "Second segment."),
            (2, 3, "Third segment."),
        ]
        assert engine.current_segment_idx == 2

    def test_resume_seeks_ffmpeg_and_offsets_time(self, engine, mock_stream, tmp_path):
        """start_segment>0 issues ffmpeg -ss to the segment start; playback_time_s starts there."""
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

        # Short stream so the whole thing plays quickly; time starts at 0.5s.
        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=2048))
        with _patch_popen(fake):
            engine.play_file(wav_file, transcript_segments=segments, start_segment=2, on_progress=on_progress)

        cmd = fake.args
        # Accurate output seek: -ss appears AFTER -i, at the expected timestamp.
        assert "-ss" in cmd
        ss_idx = cmd.index("-ss")
        assert cmd[ss_idx - 2] == "-i"  # -i FILE -ss T
        assert float(cmd[ss_idx + 1]) == pytest.approx(0.5)

        # Only segments 2 (fired at the seek offset) onward — never 0 or 1.
        fired = [c[0] for c in progress_calls]
        assert fired[0] == 2
        assert 0 not in fired and 1 not in fired

        # playback_time_s reflects true episode time (>= the 0.5s seek offset).
        assert engine.playback_time_s >= 0.5

    def test_ffmpeg_stderr_is_quieted_to_prevent_pipe_deadlock(self, engine, mock_stream, tmp_path):
        """ffmpeg is invoked with banner/progress/stats suppressed so its stderr
        pipe cannot fill and deadlock playback.

        Regression lock for the streaming-decode stderr deadlock: stdout is read
        at playback rate while stderr is drained only after the stream ends, so
        ffmpeg's default per-second progress lines would fill the ~64 KB stderr
        pipe, block ffmpeg's write, and stall a long episode. ``-loglevel error``
        must remain so genuine decode errors still reach the failure path.
        """
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=2048))
        with _patch_popen(fake):
            engine.play_file(wav_file)

        cmd = fake.args
        assert "-nostats" in cmd
        assert "-hide_banner" in cmd
        assert "-loglevel" in cmd
        assert cmd[cmd.index("-loglevel") + 1] == "error"

    def test_ffmpeg_nonzero_exit_raises(self, engine, mock_stream, tmp_path):
        """RuntimeError raised when ffmpeg exits non-zero after the stream ends."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        # Empty PCM + non-zero return code + stderr → decode failure.
        fake = _FakePopen(b"", returncode=1, stderr=b"Invalid data found when processing input")
        with _patch_popen(fake):
            with pytest.raises(RuntimeError, match="ffmpeg decode failed"):
                engine.play_file(wav_file)

    def test_stop_mid_stream_reaps_process(self, engine, mock_stream, tmp_path):
        """stop() mid-stream exits promptly and the ffmpeg process is killed and waited."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        # Long stream so playback is in progress when stop lands.
        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=240000))  # 10s of audio

        # Stop after a couple of blocks are written.
        block_count = [0]

        def _stop_after_two(data):
            block_count[0] += 1
            if block_count[0] >= 2:
                engine.stop()

        mock_stream.write.side_effect = _stop_after_two

        with _patch_popen(fake):
            engine.play_file(wav_file)

        # Did not drain the whole 10s stream — stopped early.
        assert block_count[0] < 234  # << 240000/1024 ≈ 234 blocks
        # ffmpeg reaped: kill() + wait() called, no zombie.
        assert fake.killed is True
        assert fake.wait_calls >= 1
        assert fake.returncode is not None
        assert not engine.is_playing

    def test_playback_time_advances_for_checkpoint(self, engine, mock_stream, tmp_path):
        """playback_time_s advances during playback and is readable for checkpointing."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        pcm = _make_ffmpeg_pcm(n_samples=24000)  # 1.0s at 24kHz
        fake = _FakePopen(pcm)

        # Sample the position AFTER each block's write completes (the engine
        # updates _playback_time_s post-write, so read it on the next call).
        samples = []

        def _sample_time(data):
            samples.append(engine.playback_time_s)

        mock_stream.write.side_effect = _sample_time

        assert engine.playback_time_s == 0.0
        with _patch_popen(fake):
            engine.play_file(wav_file)

        # Position advanced during playback and is monotonically non-decreasing.
        assert samples == sorted(samples)
        assert samples[-1] > 0.0  # Time moved forward across blocks.
        assert samples[-1] < engine.playback_time_s  # Last block updated after.
        # Final position reflects the full ~1.0s episode, readable for checkpoint.
        assert engine.playback_time_s == pytest.approx(1.0, abs=0.05)

    def test_missing_file_raises(self, engine):
        """FileNotFoundError raised for nonexistent file."""
        with pytest.raises(FileNotFoundError, match="Audio file not found"):
            engine.play_file("/nonexistent/path/audio.mp3")

    def test_sets_playing_flag(self, engine, mock_stream, tmp_path):
        """play_file sets _playing=True during playback and False after."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        playing_during = []

        def _capture(data):
            playing_during.append(engine.is_playing)
            engine.stop()

        mock_stream.write.side_effect = _capture

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=24000))
        with _patch_popen(fake):
            engine.play_file(wav_file)

        assert playing_during[0] is True
        assert not engine.is_playing


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
