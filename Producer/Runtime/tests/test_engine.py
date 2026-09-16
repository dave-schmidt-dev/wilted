"""Tests for wilted.engine — TTS playback engine with pause/resume/stop."""

import threading
import time
import types
from unittest.mock import MagicMock, patch

import numpy as np
import pytest
from speech_stack import client

from wilted.engine import AudioEngine

pytestmark = pytest.mark.usefixtures("stub_audio_modules")


@pytest.fixture
def engine(stub_audio_modules):
    """Create an AudioEngine for daemon-backed tests."""
    return AudioEngine()


@pytest.fixture
def mock_stream(stub_audio_modules):
    """Patch sounddevice.OutputStream to a no-op mock."""
    with patch("sounddevice.OutputStream") as mock_cls:
        stream_instance = MagicMock()
        mock_cls.return_value = stream_instance
        yield stream_instance


@pytest.fixture
def single_segment_tts_stream():
    """Provide a deterministic daemon stream for paragraph-playback tests."""

    def stream(*_args, **_kwargs):
        yield np.ones(32, dtype=np.float32).tobytes()

    with patch("wilted.engine.client.tts_stream", side_effect=stream):
        yield


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
    def test_calls_on_progress(self, engine, mock_stream, single_segment_tts_stream):
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

    def test_respects_start_paragraph(self, engine, mock_stream, single_segment_tts_stream):
        """Starting at paragraph 2 skips earlier paragraphs."""
        text = "Para 0.\nPara 1.\nPara 2.\nPara 3."
        progress_calls = []

        def on_progress(para_idx, seg_idx, total, current_text):
            progress_calls.append((para_idx, seg_idx, total, current_text))

        engine.play_article(text, start_paragraph=2, on_progress=on_progress)

        assert len(progress_calls) == 2
        assert progress_calls[0][0] == 2
        assert progress_calls[1][0] == 3

    def test_stop_mid_article(self, engine, mock_stream, single_segment_tts_stream):
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


def _make_transcript_segment(start_s: float, end_s: float, text: str):
    return types.SimpleNamespace(start_s=start_s, end_s=end_s, text=text)


def _make_ffmpeg_pcm(n_samples: int = 4800) -> bytes:
    return np.sin(np.linspace(0, 2 * np.pi * 440, n_samples)).astype(np.float32).tobytes()


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

    def test_start_time_s_seeks_without_any_transcript_segments(self, engine, mock_stream, tmp_path):
        """Regression: seeking must not require a transcript to seek by.

        ffmpeg's ``-ss`` has always taken an arbitrary timestamp; only the
        *addressing* was segment-indexed. TTS-synthesized briefings and
        bulletins are never transcribed, so requiring segments meant they could
        not resume at all and silently restarted at 0:00 no matter how accurate
        the checkpoint was.
        """
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=2048))
        with _patch_popen(fake):
            engine.play_file(wav_file, start_time_s=0.5)

        cmd = fake.args
        assert "-ss" in cmd
        ss_idx = cmd.index("-ss")
        assert cmd[ss_idx - 2] == "-i"  # accurate output seek, same as the segment path
        assert float(cmd[ss_idx + 1]) == pytest.approx(0.5)
        assert engine.playback_time_s >= 0.5

    def test_start_time_s_zero_issues_no_seek(self, engine, mock_stream, tmp_path):
        """Playing from the beginning must stay a plain decode, with no -ss."""
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=2048))
        with _patch_popen(fake):
            engine.play_file(wav_file, start_time_s=0.0)

        assert "-ss" not in fake.args

    def test_segment_seek_takes_precedence_over_start_time_s(self, engine, mock_stream, tmp_path):
        """When both are usable the segment seek wins.

        The station adapter passes ``start_time_s`` on every call, so this pins
        the precedence that keeps the transcribed-podcast path behaving exactly
        as it did before the parameter existed.
        """
        wav_file = tmp_path / "test.wav"
        wav_file.touch()

        segments = [
            _make_transcript_segment(0.0, 0.25, "Seg 0"),
            _make_transcript_segment(0.25, 0.5, "Seg 1"),
            _make_transcript_segment(0.5, 0.75, "Seg 2"),
        ]

        fake = _FakePopen(_make_ffmpeg_pcm(n_samples=2048))
        with _patch_popen(fake):
            engine.play_file(wav_file, transcript_segments=segments, start_segment=2, start_time_s=0.9)

        cmd = fake.args
        ss_idx = cmd.index("-ss")
        assert float(cmd[ss_idx + 1]) == pytest.approx(0.5)  # segment 2's start_s, not 0.9

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


class TestDaemonTts:
    """Daemon-only TTS contracts; no local model seam exists after M4."""

    def test_generate_and_play_forwards_params_and_streams_lazily(self, engine, mock_stream):
        chunks = [np.arange(1500, dtype=np.float32), np.arange(700, dtype=np.float32)]
        seen: dict[str, object] = {}

        def stream(text, **kwargs):
            seen["text"] = text
            seen.update(kwargs)
            for chunk in chunks:
                yield chunk.tobytes()

        with patch("wilted.engine.client.tts_stream", side_effect=stream):
            engine.generate_and_play("daemon only")

        assert seen == {
            "text": "daemon only",
            "voice": engine.voice,
            "speed": engine.speed,
            "model": engine.model_name,
            "lang_code": engine.lang,
        }
        written = np.concatenate([call.args[0].reshape(-1) for call in mock_stream.write.call_args_list])
        np.testing.assert_array_equal(written, np.concatenate(chunks))

    @pytest.mark.parametrize(
        "operation",
        [
            lambda engine: engine.generate_and_play("failure"),
            lambda engine: engine.play_article("Failure."),
            lambda engine: engine.generate_audio("failure"),
        ],
    )
    def test_daemon_unavailable_errors_are_actionable_on_all_tts_paths(self, engine, operation):
        error = client.DaemonUnavailable("down")

        def stream(*_args, **_kwargs):
            raise error
            yield b""  # pragma: no cover

        with patch("wilted.engine.client.tts_stream", side_effect=stream), pytest.raises(RuntimeError) as excinfo:
            operation(engine)

        assert excinfo.value.__cause__ is error
        assert "TTS daemon is unavailable" in str(excinfo.value)
        assert "make install-daemon" in str(excinfo.value)

    def test_other_typed_daemon_errors_remain_generation_failures(self, engine):
        error = client.ConnectionLost("lost")

        def stream(*_args, **_kwargs):
            raise error
            yield b""  # pragma: no cover

        with patch("wilted.engine.client.tts_stream", side_effect=stream), pytest.raises(RuntimeError) as excinfo:
            engine.generate_and_play("failure")

        assert excinfo.value.__cause__ is error
        assert "TTS generation failed" in str(excinfo.value)

    def test_generate_audio_concatenates_daemon_pcm_and_supports_overrides(self, engine):
        chunks = [np.array([0.1, 0.2], dtype=np.float32), np.array([0.3], dtype=np.float32)]
        with patch("wilted.engine.client.tts_stream", return_value=(chunk.tobytes() for chunk in chunks)) as stream:
            result = engine.generate_audio("briefing", voice="bf_emma", lang="b", speed=1.2)

        np.testing.assert_array_equal(result, np.concatenate(chunks))
        stream.assert_called_once_with("briefing", voice="bf_emma", speed=1.2, model=engine.model_name, lang_code="b")

    def test_generate_audio_returns_empty_float32_for_empty_stream(self, engine):
        """An empty daemon stream retains the no-segments public contract."""

        def stream(*_args, **_kwargs):
            if False:  # pragma: no cover - preserves the generator close() contract
                yield b""

        with patch("wilted.engine.client.tts_stream", side_effect=stream):
            result = engine.generate_audio("no audio")

        assert result.dtype == np.float32
        assert result.size == 0

    def test_generate_and_play_mid_stream_error_closes_generator_without_hanging(self, engine, mock_stream):
        """A daemon fault after a partial carry surfaces and leaves no open stream."""
        closed = False
        error = client.ConnectionLost("broker exited")

        def stream(*_args, **_kwargs):
            nonlocal closed
            try:
                # Leaves a 476-sample carry after the first 1024-sample block.
                yield np.ones(1500, dtype=np.float32).tobytes()
                raise error
            finally:
                closed = True

        with patch("wilted.engine.client.tts_stream", side_effect=stream), pytest.raises(RuntimeError) as excinfo:
            engine.generate_and_play("fault after audio")

        assert excinfo.value.__cause__ is error
        assert "TTS generation failed" in str(excinfo.value)
        assert mock_stream.write.call_count == 1
        assert closed

    def test_play_article_mid_paragraph_error_does_not_advance_failed_segment(self, engine, mock_stream):
        """A daemon fault stops the article before failed/later segment progress can emit."""
        closed = False
        requested: list[str] = []
        progress = []
        error = client.ConnectionLost("broker exited")

        def stream(text, **_kwargs):
            nonlocal closed
            requested.append(text)
            try:
                yield np.ones(32, dtype=np.float32).tobytes()
                raise error
            finally:
                closed = True

        with patch("wilted.engine.client.tts_stream", side_effect=stream), pytest.raises(RuntimeError) as excinfo:
            engine.play_article("First paragraph.\nLater paragraph.", on_progress=lambda *args: progress.append(args))

        assert excinfo.value.__cause__ is error
        assert progress == [(0, 0, 2, "First paragraph.")]
        assert requested == ["First paragraph."]
        assert engine.current_segment_idx == 0
        assert not engine.is_playing
        assert closed

    def test_play_article_preserves_progress_per_daemon_segment(self, engine, mock_stream):
        progress = []

        def stream(_text, **_kwargs):
            yield np.ones(32, dtype=np.float32).tobytes()
            yield np.ones(16, dtype=np.float32).tobytes()

        with patch("wilted.engine.client.tts_stream", side_effect=stream):
            engine.play_article("Only paragraph.", on_progress=lambda *args: progress.append(args))

        assert progress == [(0, 0, 1, "Only paragraph."), (0, 1, 1, "Only paragraph.")]

    def test_stop_closes_daemon_stream(self, engine, mock_stream):
        closed = False

        def stream(*_args, **_kwargs):
            nonlocal closed
            try:
                while True:
                    yield np.ones(1024, dtype=np.float32).tobytes()
            except GeneratorExit:
                closed = True
                raise

        mock_stream.write.side_effect = lambda _block: engine.stop()
        with patch("wilted.engine.client.tts_stream", side_effect=stream):
            engine.generate_and_play("stop")

        assert closed
