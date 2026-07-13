"""Tests for wilted.engine — TTS playback engine with pause/resume/stop."""

import os
import threading
import time
import types
from unittest.mock import MagicMock, patch

import numpy as np
import pytest
from speech_stack import client

from wilted.engine import AudioEngine, _tts_backend

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
            # Keep the §6c memory guideline off the real mlx.core: repeated
            # real imports of mlx.core within one pytest process (interacting
            # with the sys.modules patching above) can abort the interpreter
            # via a nanobind duplicate-registration error. Not a concern in
            # production (one model load per process), only a test hazard.
            patch("speech_stack.memory.default_memory_limit_bytes", return_value=None),
            patch("speech_stack.memory.apply_memory_policy"),
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
            # See comment in test_load_model_disables_hf_xet_by_default above.
            patch("speech_stack.memory.default_memory_limit_bytes", return_value=None),
            patch("speech_stack.memory.apply_memory_policy"),
        ):
            engine.load_model()
            # Check inside the controlled env — the real shell may already
            # have the var from a previous wilted run.
            assert "HF_HUB_DISABLE_XET" not in os.environ

        assert engine._model == "mock-model"
        mock_load_model.assert_called_once_with(engine.model_name)

    def test_load_model_applies_memory_guideline(self):
        """§6c defense-in-depth: load_model applies the shared mlx memory
        guideline immediately before the mlx_audio model load.

        The guideline is only attempted once ``mlx.core`` is already resident
        in ``sys.modules`` (see the comment at the call site in engine.py), so
        this test seeds a fake ``mlx.core`` alongside the fake ``mlx_audio`` —
        mirroring how the real ``mlx_audio`` import loads the real mlx.core as
        a side effect in production.
        """
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model
        fake_mlx_core = types.ModuleType("mlx.core")

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                    "mlx.core": fake_mlx_core,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=True),
            patch("speech_stack.memory.default_memory_limit_bytes", return_value=12345) as mock_default,
            patch("speech_stack.memory.apply_memory_policy") as mock_apply,
        ):
            engine.load_model()

        mock_default.assert_called_once_with()
        mock_apply.assert_called_once_with(memory_limit_bytes=12345)
        assert engine._model == "mock-model"
        mock_load_model.assert_called_once_with(engine.model_name)

    def test_load_model_proceeds_when_memory_guideline_raises(self):
        """A raising memory guideline must be swallowed — load_model still
        succeeds. This is defense-in-depth and must never become a new
        failure mode."""
        engine = AudioEngine()
        mock_load_model = MagicMock(return_value="mock-model")
        mlx_audio_mod = types.ModuleType("mlx_audio")
        mlx_audio_tts_mod = types.ModuleType("mlx_audio.tts")
        mlx_audio_utils_mod = types.ModuleType("mlx_audio.tts.utils")
        mlx_audio_utils_mod.load_model = mock_load_model
        fake_mlx_core = types.ModuleType("mlx.core")

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(
                "sys.modules",
                {
                    "mlx_audio": mlx_audio_mod,
                    "mlx_audio.tts": mlx_audio_tts_mod,
                    "mlx_audio.tts.utils": mlx_audio_utils_mod,
                    "mlx.core": fake_mlx_core,
                },
            ),
            patch("wilted.engine.os.path.isdir", return_value=True),
            patch("speech_stack.memory.default_memory_limit_bytes", side_effect=RuntimeError("boom")),
        ):
            engine.load_model()

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
            # See comment in TestModelLoading above re: real mlx.core reimport hazard.
            patch("speech_stack.memory.default_memory_limit_bytes", return_value=None),
            patch("speech_stack.memory.apply_memory_policy"),
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


class TestProcessWideMetalLock:
    """Regression: the Metal serialization lock must be PROCESS-WIDE (shared
    across all AudioEngine instances), not per-instance (INV-1).

    Root cause of a launch-time native SIGABRT ("A command encoder is already
    encoding to this command buffer"): the briefing synth, each weather-bulletin
    synth, and the TUI's ``_preload_model`` each use a SEPARATE ``AudioEngine``,
    and their model loads/generates run on separate ``@work`` threads. A
    per-instance ``_model_lock`` cannot serialize across instances, so two
    threads encoded to the MLX/Metal GPU command buffer at once and aborted the
    whole process (no Python traceback — caught only by faulthandler). INV-1
    requires ALL MLX/Metal GPU work to be serialized behind ONE lock.
    """

    def test_model_lock_is_shared_across_instances(self):
        # The direct invariant: reverting to a per-instance lock fails here.
        assert AudioEngine()._model_lock is AudioEngine()._model_lock
        assert AudioEngine._model_lock is AudioEngine()._model_lock

    def test_generate_on_two_engines_never_overlaps(self):
        """Two threads generating on DIFFERENT engines must never run the
        Metal-touching section concurrently — that overlap WAS the crash.

        With a per-instance lock the two ``generate`` sections would overlap
        (and abort on real Metal); with the shared lock they serialize.
        """
        import time

        overlaps: list[bool] = []
        active = {"n": 0}
        counter_lock = threading.Lock()  # guards the counter only, NOT the engines

        def instrumented_generate(*_a, **_k):
            with counter_lock:
                active["n"] += 1
                if active["n"] > 1:
                    overlaps.append(True)
            time.sleep(0.05)  # hold the Metal-touching section open
            with counter_lock:
                active["n"] -= 1
            return _make_fake_segment(n_samples=1024)

        e1 = AudioEngine()
        e1._model = MagicMock()
        e1._model.generate.side_effect = instrumented_generate
        e2 = AudioEngine()
        e2._model = MagicMock()
        e2._model.generate.side_effect = instrumented_generate

        t1 = threading.Thread(target=lambda: e1.generate_audio("a"))
        t2 = threading.Thread(target=lambda: e2.generate_audio("b"))
        t1.start()
        t2.start()
        t1.join(timeout=5)
        t2.join(timeout=5)

        assert not overlaps, (
            "MLX/Metal generate overlapped across two AudioEngine instances — "
            "concurrent GPU encoding, the launch-crash regression"
        )


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

    def test_stop_interrupts_blocked_read(self, engine, mock_stream, tmp_path):
        """stop() must break a play_file() blocked in proc.stdout.read().

        Regression for the walkthrough freeze: the streaming loop only checks
        _stop_event *between* blocks, so a read blocked on a stalled ffmpeg is
        uninterruptible unless stop() kills the process. This fake's second
        read() blocks until the proc is killed; on the pre-fix engine, stop()
        does not kill the proc, so the read blocks until its own 5s timeout and
        play_file does not return within the assertion window — the test fails.
        With the fix, stop() kills the proc, the read returns EOF, and play_file
        returns at once.
        """
        import threading
        import time

        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        first_read_done = threading.Event()
        killed = threading.Event()

        class _BlockingStdout:
            def __init__(self):
                self.closed = False

            def read(self, n: int = -1) -> bytes:
                if not first_read_done.is_set():
                    first_read_done.set()
                    return _make_ffmpeg_pcm(n_samples=1024)  # one block, then stall
                killed.wait(timeout=5.0)  # block like a stalled ffmpeg until killed
                return b""  # EOF once killed

            def close(self):
                self.closed = True

        class _BlockingPopen:
            def __init__(self):
                self.stdout = _BlockingStdout()
                self.stderr = _FakeStderr(b"")
                self.returncode = None
                self.killed = False
                self.wait_calls = 0
                self.args = None

            def wait(self, timeout=None):
                self.wait_calls += 1
                self.returncode = -9
                return self.returncode

            def poll(self):
                return self.returncode

            def kill(self):
                self.killed = True
                killed.set()  # unblock the stalled read -> EOF

        fake = _BlockingPopen()
        returned = threading.Event()

        def _run():
            with _patch_popen(fake):
                engine.play_file(wav_file)
            returned.set()

        worker = threading.Thread(target=_run, daemon=True)
        worker.start()

        assert first_read_done.wait(timeout=3.0), "playback never started"
        time.sleep(0.1)  # ensure we are blocked inside the second read()
        engine.stop()  # must kill the proc so the blocked read returns EOF

        assert returned.wait(timeout=3.0), "play_file did not return after stop() — blocked read not interrupted"
        assert fake.killed is True
        worker.join(timeout=2.0)

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


# ---------------------------------------------------------------------------
# TTS backend: daemon streaming (WILTED_TTS_BACKEND=daemon) — additive, opt-in
# ---------------------------------------------------------------------------


class TestTtsBackendSelector:
    """The env selector is strictly opt-in and case-insensitive."""

    def test_default_is_inprocess(self, monkeypatch):
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)
        assert _tts_backend() == "inprocess"

    def test_daemon_value_selects_daemon(self, monkeypatch):
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        assert _tts_backend() == "daemon"
        monkeypatch.setenv("WILTED_TTS_BACKEND", "DAEMON")  # case-insensitive
        assert _tts_backend() == "daemon"

    def test_unknown_value_falls_back_to_inprocess(self, monkeypatch):
        """An unrecognized value is not a hard error — it keeps today's behavior."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "banana")
        assert _tts_backend() == "inprocess"


class TestGenerateAndPlayDaemonBackend:
    """WILTED_TTS_BACKEND=daemon streams a paragraph through ``speech_stack.client``.

    ``client.tts_stream`` is sample-identical to ``tts_wav`` by contract (PM-7), so
    these tests lock down only the additive daemon seam: same-param routing +
    bytes→numpy correctness, lazy streaming (the first-audio latency win), the
    ``DaemonUnavailable``-only fallback (clean, at the start), and typed-error
    fidelity — a real daemon crash mid-synthesis is NEVER masked by a silent
    in-process retry (INV-6/CV-2). The client is always mocked (never a live
    broker).
    """

    def test_daemon_backend_routes_through_client_tts_stream(self, engine, mock_stream, monkeypatch):
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        # Three deliberately block-UNALIGNED chunks so the carry-remainder path in
        # _stream_pcm is exercised; the concatenation must be reconstructed exactly.
        chunk_arrays = [
            np.linspace(-1.0, 1.0, 1500, dtype=np.float32),
            np.linspace(1.0, -1.0, 700, dtype=np.float32),
            np.full(900, 0.25, dtype=np.float32),
        ]
        captured: dict = {}

        def _fake_tts_stream(text, **kwargs):
            captured["text"] = text
            captured["kwargs"] = kwargs
            for arr in chunk_arrays:
                yield arr.tobytes()

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream),
            patch.object(
                engine,
                "_generate_and_play_inprocess",
                side_effect=AssertionError("in-process path must not run on the daemon backend"),
            ),
        ):
            engine.generate_and_play("Hello daemon.")

        # Routed with the SAME params the in-process _model.generate call uses.
        assert captured["text"] == "Hello daemon."
        assert captured["kwargs"]["voice"] == engine.voice
        assert captured["kwargs"]["speed"] == engine.speed
        assert captured["kwargs"]["lang_code"] == engine.lang
        assert captured["kwargs"]["model"] == engine.model_name

        # PM-7: every sample reached the output stream, IN ORDER, sample-identical
        # to the concatenation of the daemon's PCM chunks — proof the bytes→numpy
        # (`np.frombuffer`) conversion reconstructs the same float32 samples
        # tts_wav would write, across unaligned chunk boundaries.
        written = np.concatenate([call.args[0].reshape(-1) for call in mock_stream.write.call_args_list])
        expected = np.concatenate(chunk_arrays)
        assert written.shape == expected.shape
        np.testing.assert_array_equal(written, expected)

    def test_daemon_streams_first_audio_before_full_synthesis(self, engine, mock_stream, monkeypatch, capsys):
        """First-audio latency win: the daemon PCM iterator is consumed LAZILY, so
        the first block is written to the device before the LAST chunk is
        synthesized — not after the whole paragraph is materialized (the in-process
        behavior). Model-free: each chunk's synthesis is a small sleep stand-in."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        events: list[tuple[str, float]] = []
        n_chunks = 4
        per_chunk_synth_s = 0.02  # stand-in for cold per-segment GPU synthesis

        def _fake_tts_stream(text, **kwargs):
            for _ in range(n_chunks):
                time.sleep(per_chunk_synth_s)
                events.append(("yield", time.perf_counter()))
                yield np.full(1024, 0.1, dtype=np.float32).tobytes()  # exactly one block

        mock_stream.write.side_effect = lambda block: events.append(("write", time.perf_counter()))

        t0 = time.perf_counter()
        with patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream):
            engine.generate_and_play("Stream me.")
        total_elapsed = time.perf_counter() - t0

        kinds = [k for k, _ in events]
        # Deterministic proof of streaming: the first block is written BEFORE the
        # last chunk is yielded (a pre-drain-into-a-list consumer could not).
        first_write = kinds.index("write")
        last_yield = len(kinds) - 1 - kinds[::-1].index("yield")
        assert first_write < last_yield

        # Model-free first-audio latency measurement (reported, not just asserted).
        first_write_ts = next(ts for k, ts in events if k == "write")
        first_audio_latency = first_write_ts - t0
        print(
            f"\n[first-audio-latency] first block at {first_audio_latency * 1e3:.1f} ms "
            f"vs full materialize {total_elapsed * 1e3:.1f} ms "
            f"({n_chunks} chunks × {per_chunk_synth_s * 1e3:.0f} ms synth)"
        )
        assert 0.0 <= first_audio_latency < total_elapsed

    def test_daemon_unavailable_falls_back_to_inprocess_at_start(self, engine, mock_stream, monkeypatch):
        """No broker listening -> fall back to the in-process path, cleanly, BEFORE
        any audio has begun. DaemonUnavailable is the ONLY error that falls back."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")

        def _no_broker(text, **kwargs):
            raise client.DaemonUnavailable("no broker at socket")
            yield  # pragma: no cover — unreachable; makes this a generator function

        called = {"inprocess": False}

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_no_broker),
            patch.object(
                engine,
                "_generate_and_play_inprocess",
                side_effect=lambda text: called.__setitem__("inprocess", True),
            ),
        ):
            engine.generate_and_play("fallback please")

        assert called["inprocess"] is True
        # No audio device work happened on the daemon side of the fall back — the
        # in-process stub handled playback (INV-6: fall back only at the start).
        assert mock_stream.write.call_count == 0

    @pytest.mark.parametrize(
        "daemon_exc",
        [
            client.Timeout("daemon tts timed out"),
            client.GpuAborted("daemon worker died: SIGABRT"),
            client.GpuSegfault("daemon worker died: SIGSEGV"),
            client.WorkerError("daemon worker failed: ValueError: boom"),
            client.ConnectionLost("broker died mid-synthesis"),
        ],
    )
    def test_daemon_typed_error_surfaces_without_masking(self, engine, mock_stream, monkeypatch, daemon_exc):
        """INV-6: a real daemon failure maps to the SAME RuntimeError the in-process
        path raises on a generation failure, with the typed error chained
        (``__cause__``), and is NEVER retried on the in-process path. The AssertionError
        side-effect on the in-process path proves there is no silent fallback once
        streaming has begun."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")

        def _raises_typed(text, **kwargs):
            # One good chunk THEN a mid-stream fault, so the error surfaces even
            # after audio has begun (no fall back possible at that point).
            yield np.full(1024, 0.1, dtype=np.float32).tobytes()
            raise daemon_exc

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_raises_typed),
            patch.object(
                engine,
                "_generate_and_play_inprocess",
                side_effect=AssertionError("a real daemon crash must never fall back to in-process"),
            ),
        ):
            with pytest.raises(RuntimeError) as excinfo:
                engine.generate_and_play("boom")

        # Same type the in-process path raises (RuntimeError) with the typed error
        # chained by identity — nothing masked, and it is a real client.* typed error.
        assert excinfo.value.__cause__ is daemon_exc
        assert isinstance(excinfo.value.__cause__, client.IsolatedError)
        assert str(daemon_exc) in str(excinfo.value)

    def test_daemon_killed_mid_stream_surfaces_no_hang(self, engine, mock_stream, monkeypatch):
        """CV-2: the broker dies mid-stream -> client.tts_stream raises a typed error
        mid-iteration WHILE a sub-block carry remainder is held; _stream_pcm must let
        it propagate (NOT hang on the half-filled carry buffer, NOT silently truncate
        to silence), playback stops cleanly, and the daemon generator is torn down."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        torn_down = {"count": 0}

        def _dies_mid_stream(text, **kwargs):
            try:
                # A sub-block chunk (600 < 1024) leaves a carry remainder unflushed —
                # the exact state CV-2 forbids hanging on — then the broker dies.
                yield np.full(600, 0.2, dtype=np.float32).tobytes()
                raise client.ConnectionLost("speech daemon stream dropped")
            finally:
                torn_down["count"] += 1  # generator torn down (exception or close)

        with patch("wilted.engine.client.tts_stream", side_effect=_dies_mid_stream):
            with pytest.raises(RuntimeError) as excinfo:
                engine.generate_and_play("half a block then die")

        # The typed error surfaced (chained), the run did not hang, and the sd
        # stream was opened+closed cleanly rather than left dangling on the carry.
        assert isinstance(excinfo.value.__cause__, client.ConnectionLost)
        assert torn_down["count"] == 1
        assert mock_stream.stop.called and mock_stream.close.called

    def test_stop_mid_stream_closes_daemon_generator(self, engine, mock_stream, monkeypatch):
        """A stop/skip mid-stream breaks _stream_pcm cleanly and closes the daemon
        generator, so the broker sees EOF and CANCELs the in-flight synthesis."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        gen_state = {"closed": False, "yielded": 0}

        def _long_stream(text, **kwargs):
            try:
                while True:  # never terminates on its own — only a close() stops it
                    gen_state["yielded"] += 1
                    yield np.full(1024, 0.1, dtype=np.float32).tobytes()
            except GeneratorExit:
                gen_state["closed"] = True
                raise

        mock_stream.write.side_effect = lambda block: engine.stop()  # stop after first block

        with patch("wilted.engine.client.tts_stream", side_effect=_long_stream):
            engine.generate_and_play("infinite stream, stopped early")

        # Stop broke the loop early (did not drain the infinite generator) and the
        # daemon generator was explicitly closed -> broker sees EOF -> CANCEL.
        assert gen_state["yielded"] < 5
        assert gen_state["closed"] is True
        assert engine._stop_event.is_set()

    def test_default_backend_never_touches_client(self, engine, mock_stream, monkeypatch):
        """Unset flag -> in-process path only; the daemon client is never called."""
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)

        with patch(
            "wilted.engine.client.tts_stream",
            side_effect=AssertionError("client.tts_stream must not run on the default backend"),
        ):
            engine.generate_and_play("in process")

        engine._model.generate.assert_called_once()

    def test_backend_logged_once_per_process(self, engine, mock_stream, monkeypatch):
        """The chosen TTS backend is logged exactly once, at first use (CR-5)."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        monkeypatch.setattr("wilted.engine._tts_backend_logged", False)

        def _fake_tts_stream(text, **kwargs):
            yield np.full(1024, 0.1, dtype=np.float32).tobytes()

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream),
            patch("wilted.engine.logger") as mock_logger,
        ):
            engine.generate_and_play("first")
            engine.generate_and_play("second")  # second call must NOT re-log the backend

        backend_calls = [c for c in mock_logger.info.call_args_list if c.args and "TTS backend" in str(c.args[0])]
        assert len(backend_calls) == 1
        assert backend_calls[0].args[1] == "daemon"


class TestGenerateAudioDaemonBackend:
    """WILTED_TTS_BACKEND=daemon routes ``generate_audio`` through
    ``speech_stack.client.tts_stream`` and concatenates the streamed PCM chunks
    into the returned array (Task 3.1, PM-11). Mirrors
    ``TestGenerateAndPlayDaemonBackend``'s coverage shape; the client is always
    mocked (never a live broker) per wilted's existing test conventions.
    """

    def test_daemon_backend_routes_through_client_tts_stream(self, engine, mock_stream, monkeypatch):
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        # Deliberately unaligned chunk lengths (not general to 1024-block writes
        # here since generate_audio never touches the audio device — this just
        # proves np.frombuffer + concatenation reconstructs the samples exactly).
        chunk_arrays = [
            np.linspace(-1.0, 1.0, 1500, dtype=np.float32),
            np.linspace(1.0, -1.0, 700, dtype=np.float32),
            np.full(900, 0.25, dtype=np.float32),
        ]
        captured: dict = {}

        def _fake_tts_stream(text, **kwargs):
            captured["text"] = text
            captured["kwargs"] = kwargs
            for arr in chunk_arrays:
                yield arr.tobytes()

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream),
            patch.object(
                engine,
                "_generate_audio_inprocess",
                side_effect=AssertionError("in-process path must not run on the daemon backend"),
            ),
        ):
            result = engine.generate_audio("Hello daemon.")

        # Routed with the SAME params the in-process _model.generate call uses.
        assert captured["text"] == "Hello daemon."
        assert captured["kwargs"]["voice"] == engine.voice
        assert captured["kwargs"]["speed"] == engine.speed
        assert captured["kwargs"]["lang_code"] == engine.lang
        assert captured["kwargs"]["model"] == engine.model_name

        expected = np.concatenate(chunk_arrays)
        assert result.shape == expected.shape
        np.testing.assert_array_equal(result, expected)

    def test_daemon_parity_with_inprocess_fixed_input(self, engine, mock_stream, monkeypatch):
        """PM-11: for a FIXED input, the daemon route's concatenated array is
        sample-identical to the in-process route's concatenated array."""
        text = "A fixed paragraph for parity."
        seg1 = np.linspace(-0.5, 0.5, 800, dtype=np.float32)
        seg2 = np.full(300, -0.75, dtype=np.float32)

        def _make_segment(audio):
            seg = MagicMock()
            seg.audio = audio
            return seg

        engine._model.generate.return_value = [_make_segment(seg1), _make_segment(seg2)]
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)
        inprocess_result = engine.generate_audio(text)

        def _fake_tts_stream(_text, **kwargs):
            yield seg1.tobytes()
            yield seg2.tobytes()

        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        with patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream):
            daemon_result = engine.generate_audio(text)

        assert daemon_result.shape == inprocess_result.shape
        np.testing.assert_array_equal(daemon_result, inprocess_result)

    def test_daemon_parity_with_inprocess_empty_input(self, engine, mock_stream, monkeypatch):
        """PM-11: empty synthesis on EITHER backend returns an empty float32
        array — never raises (np.concatenate([]) would)."""
        text = "Empty."

        engine._model.generate.return_value = []
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)
        inprocess_result = engine.generate_audio(text)
        assert isinstance(inprocess_result, np.ndarray)
        assert inprocess_result.dtype == np.float32
        assert len(inprocess_result) == 0

        def _empty_stream(_text, **kwargs):
            return
            yield  # pragma: no cover — unreachable; makes this a generator function

        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        with patch("wilted.engine.client.tts_stream", side_effect=_empty_stream):
            daemon_result = engine.generate_audio(text)

        assert isinstance(daemon_result, np.ndarray)
        assert daemon_result.dtype == np.float32
        assert len(daemon_result) == 0

    def test_daemon_unavailable_falls_back_to_inprocess(self, engine, mock_stream, monkeypatch):
        """No broker listening -> fall back to the in-process path, cleanly,
        BEFORE any chunk has been consumed. DaemonUnavailable is the ONLY error
        that falls back."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")

        def _no_broker(text, **kwargs):
            raise client.DaemonUnavailable("no broker at socket")
            yield  # pragma: no cover — unreachable; makes this a generator function

        with patch("wilted.engine.client.tts_stream", side_effect=_no_broker):
            result = engine.generate_audio("fallback please")

        # The in-process path actually ran (fixture's mocked _model.generate).
        engine._model.generate.assert_called_once()
        assert isinstance(result, np.ndarray)
        assert len(result) == 4096  # fixture's default fake segment size

    @pytest.mark.parametrize(
        "daemon_exc",
        [
            client.Timeout("daemon tts timed out"),
            client.GpuAborted("daemon worker died: SIGABRT"),
            client.GpuSegfault("daemon worker died: SIGSEGV"),
            client.WorkerError("daemon worker failed: ValueError: boom"),
            client.ConnectionLost("broker died mid-synthesis"),
        ],
    )
    def test_daemon_typed_error_surfaces_without_masking(self, engine, mock_stream, monkeypatch, daemon_exc):
        """INV-6: a real daemon failure maps to the SAME RuntimeError the
        in-process path raises, with the typed error chained, and is NEVER
        retried on the in-process path once a chunk has been consumed."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")

        def _raises_typed(text, **kwargs):
            yield np.full(256, 0.1, dtype=np.float32).tobytes()
            raise daemon_exc

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_raises_typed),
            patch.object(
                engine,
                "_generate_audio_inprocess",
                side_effect=AssertionError("a real daemon crash must never fall back to in-process"),
            ),
        ):
            with pytest.raises(RuntimeError) as excinfo:
                engine.generate_audio("boom")

        assert excinfo.value.__cause__ is daemon_exc
        assert isinstance(excinfo.value.__cause__, client.IsolatedError)
        assert str(daemon_exc) in str(excinfo.value)

    def test_default_backend_never_touches_client(self, engine, mock_stream, monkeypatch):
        """Unset flag -> in-process path only; the daemon client is never called."""
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)

        with patch(
            "wilted.engine.client.tts_stream",
            side_effect=AssertionError("client.tts_stream must not run on the default backend"),
        ):
            engine.generate_audio("in process")

        engine._model.generate.assert_called_once()


class TestPlayArticleDaemonBackend:
    """WILTED_TTS_BACKEND=daemon streams each paragraph's segments through
    ``speech_stack.client.tts_stream`` (Task 3.2, PM-7/CV-2). ``on_progress``
    emission must stay byte-identical to the in-process path — same args, same
    order, one call per segment actually played. The client is always mocked
    (never a live broker).
    """

    def test_daemon_backend_routes_segments_with_progress(self, engine, mock_stream, monkeypatch):
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        text = "Only paragraph here."
        seg_arrays = [
            np.linspace(-1.0, 1.0, 1200, dtype=np.float32),
            np.full(500, 0.5, dtype=np.float32),
        ]
        captured: dict = {}

        def _fake_tts_stream(paragraph_text, **kwargs):
            captured["text"] = paragraph_text
            captured["kwargs"] = kwargs
            for arr in seg_arrays:
                yield arr.tobytes()

        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append((para_idx, seg_idx, total, current_text))

        with (
            patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream),
            patch.object(
                engine,
                "_play_paragraph_inprocess",
                side_effect=AssertionError("in-process path must not run on the daemon backend"),
            ),
        ):
            engine.play_article(text, on_progress=on_progress)

        assert captured["text"] == text
        assert captured["kwargs"]["voice"] == engine.voice
        assert captured["kwargs"]["speed"] == engine.speed
        assert captured["kwargs"]["lang_code"] == engine.lang
        assert captured["kwargs"]["model"] == engine.model_name

        # One on_progress call per segment, byte-identical contract: (para_idx,
        # seg_idx, total_paragraphs, current_text).
        assert progress_calls == [(0, 0, 1, text), (0, 1, 1, text)]

        # Each segment was played whole, in order (PM-7 sample parity).
        written = np.concatenate([call.args[0].reshape(-1) for call in mock_stream.write.call_args_list])
        expected = np.concatenate(seg_arrays)
        np.testing.assert_array_equal(written, expected)

    def test_daemon_parity_with_inprocess_fixed_input(self, engine, mock_stream, monkeypatch):
        """PM-7/PM-11: for a FIXED two-paragraph article, the daemon route's
        on_progress calls and written audio are byte-identical to the
        in-process route's."""
        text = "Para zero here.\nPara one here."
        segments_by_para = {
            "Para zero here.": [
                np.linspace(-0.4, 0.4, 600, dtype=np.float32),
                np.full(200, 0.1, dtype=np.float32),
            ],
            "Para one here.": [
                np.linspace(0.9, -0.9, 400, dtype=np.float32),
            ],
        }

        def _make_segment(audio):
            seg = MagicMock()
            seg.audio = audio
            return seg

        def _fake_generate(paragraph_text, **kwargs):
            return [_make_segment(a) for a in segments_by_para[paragraph_text]]

        # --- in-process run ---
        engine._model.generate.side_effect = _fake_generate
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)
        inprocess_progress = []
        engine.play_article(
            text,
            on_progress=lambda p, s, t, c: inprocess_progress.append((p, s, t, c)),
        )
        inprocess_written = np.concatenate([call.args[0].reshape(-1) for call in mock_stream.write.call_args_list])

        # --- daemon run (fresh mock_stream call history) ---
        mock_stream.write.reset_mock()

        def _fake_tts_stream(paragraph_text, **kwargs):
            for arr in segments_by_para[paragraph_text]:
                yield arr.tobytes()

        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        daemon_progress = []
        with patch("wilted.engine.client.tts_stream", side_effect=_fake_tts_stream):
            engine.play_article(
                text,
                on_progress=lambda p, s, t, c: daemon_progress.append((p, s, t, c)),
            )
        daemon_written = np.concatenate([call.args[0].reshape(-1) for call in mock_stream.write.call_args_list])

        assert daemon_progress == inprocess_progress
        assert daemon_written.shape == inprocess_written.shape
        np.testing.assert_array_equal(daemon_written, inprocess_written)

    def test_mid_paragraph_daemon_kill_no_desync_no_hang(self, engine, mock_stream, monkeypatch):
        """CV-2 fault injection: the broker dies mid-paragraph, AFTER its first
        segment played but BEFORE its second. Assert (a) on_progress fired for
        the segment that actually played and NEVER for the killed segment —
        indices cannot desync; (b) the failure surfaces as a chained
        RuntimeError instead of hanging; (c) the daemon generator is torn down
        (broker sees EOF -> CANCEL); (d) later paragraphs are never reached."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        text = "Para zero here.\nPara one here.\nPara two here."
        torn_down = {"count": 0}
        stream_calls = []

        def _dies_in_second_paragraph(paragraph_text, **kwargs):
            stream_calls.append(paragraph_text)
            if paragraph_text == "Para zero here.":
                yield np.full(300, 0.2, dtype=np.float32).tobytes()
                return
            if paragraph_text == "Para one here.":
                try:
                    # First segment plays fine...
                    yield np.full(300, 0.3, dtype=np.float32).tobytes()
                    # ...then the broker dies before the second segment arrives.
                    raise client.ConnectionLost("speech daemon stream dropped")
                finally:
                    torn_down["count"] += 1  # generator torn down (exception or close)
            raise AssertionError("third paragraph must never be synthesized after the kill")

        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append((para_idx, seg_idx, total, current_text))

        with patch("wilted.engine.client.tts_stream", side_effect=_dies_in_second_paragraph):
            with pytest.raises(RuntimeError) as excinfo:
                engine.play_article(text, on_progress=on_progress)

        # No desync: on_progress fired exactly once for paragraph 0's only
        # segment and once for paragraph 1's FIRST segment — never for the
        # killed segment, never for paragraph 2.
        assert progress_calls == [(0, 0, 3, "Para zero here."), (1, 0, 3, "Para one here.")]

        # The typed error surfaced (chained) instead of being swallowed.
        assert isinstance(excinfo.value.__cause__, client.ConnectionLost)

        # No hang: the call actually raised (not blocked), and the daemon
        # generator for the killed paragraph was torn down exactly once —
        # there is no carry buffer here to hang on (each chunk is one whole
        # segment played via a single _play_audio call).
        assert torn_down["count"] == 1
        assert stream_calls == ["Para zero here.", "Para one here."]

        # play_article's finally still ran despite the propagated exception.
        assert engine.is_playing is False

    def test_daemon_unavailable_falls_back_to_inprocess_mid_article(self, engine, mock_stream, monkeypatch):
        """No broker listening -> fall back to the in-process path for that
        paragraph, cleanly, BEFORE any of its segments have played."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        text = "Only paragraph."

        def _no_broker(paragraph_text, **kwargs):
            raise client.DaemonUnavailable("no broker at socket")
            yield  # pragma: no cover — unreachable; makes this a generator function

        progress_calls = []

        with patch("wilted.engine.client.tts_stream", side_effect=_no_broker):
            engine.play_article(
                text,
                on_progress=lambda p, s, t, c: progress_calls.append((p, s, t, c)),
            )

        # The in-process path actually ran (fixture's mocked _model.generate,
        # one 4096-sample segment) and produced the expected progress call.
        engine._model.generate.assert_called_once()
        assert progress_calls == [(0, 0, 1, text)]

    def test_stop_mid_paragraph_closes_daemon_generator(self, engine, mock_stream, monkeypatch):
        """Stop mid-paragraph breaks the segment loop cleanly and closes the
        daemon generator, so the broker sees EOF and CANCELs synthesis."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        text = "Only paragraph."
        gen_state = {"closed": False, "yielded": 0}

        def _long_stream(paragraph_text, **kwargs):
            try:
                while True:  # never terminates on its own — only a close() stops it
                    gen_state["yielded"] += 1
                    yield np.full(1024, 0.1, dtype=np.float32).tobytes()
            except GeneratorExit:
                gen_state["closed"] = True
                raise

        mock_stream.write.side_effect = lambda block: engine.stop()  # stop after first block

        with patch("wilted.engine.client.tts_stream", side_effect=_long_stream):
            engine.play_article(text)

        assert gen_state["yielded"] < 5
        assert gen_state["closed"] is True
        assert engine._stop_event.is_set()

    def test_daemon_backend_does_not_load_local_model(self, engine, mock_stream, monkeypatch):
        """The daemon backend must never load the local Kokoro model in
        play_article — the daemon owns the model, so an eager local load would
        defeat the migration (and re-introduce the in-process load M3 removes)."""
        monkeypatch.setenv("WILTED_TTS_BACKEND", "daemon")
        load_spy = MagicMock()
        monkeypatch.setattr(engine, "load_model", load_spy)

        def _one_segment(paragraph_text, **kwargs):
            yield np.full(1024, 0.1, dtype=np.float32).tobytes()

        with patch("wilted.engine.client.tts_stream", side_effect=_one_segment):
            engine.play_article("Only paragraph.")

        load_spy.assert_not_called()

    def test_inprocess_backend_loads_before_is_playing(self, engine, mock_stream, monkeypatch):
        """Regression (M3 load_model fix): the in-process path loads the model
        BEFORE is_playing is set — the frozen ordering (load, then play). The
        daemon migration had relocated the load into the per-paragraph helper,
        so it ran with is_playing already True; this locks the ordering back."""
        monkeypatch.delenv("WILTED_TTS_BACKEND", raising=False)
        is_playing_at_load = []
        real_load = engine.load_model

        def _spy_load():
            is_playing_at_load.append(engine.is_playing)
            return real_load()

        monkeypatch.setattr(engine, "load_model", _spy_load)
        engine.play_article("Only paragraph.")

        assert is_playing_at_load, "load_model was never called on the in-process path"
        assert is_playing_at_load[0] is False, "model loaded after is_playing was set (ordering regression)"
