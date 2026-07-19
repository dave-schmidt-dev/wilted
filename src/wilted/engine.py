"""Audio engine — TTS generation and playback with pause/resume/stop controls."""

import logging
import subprocess
import threading
from collections.abc import Callable, Iterable
from pathlib import Path

import numpy as np
from speech_stack import client

from wilted.text import split_paragraphs

SAMPLE_RATE = 24000  # Kokoro default

logger = logging.getLogger(__name__)


def _tts_generation_error(error: client.IsolatedError) -> RuntimeError:
    """Translate a daemon synthesis error into the public engine contract."""
    if isinstance(error, client.DaemonUnavailable):
        return RuntimeError(f"TTS daemon is unavailable: {error}. Start it with `make install-daemon`.")
    return RuntimeError(f"TTS generation failed: {error}")


class AudioEngine:
    """TTS audio engine with thread-safe playback controls.

    Generates speech through the resident speech daemon and plays it through
    sounddevice.OutputStream with block-level pause/resume/stop support.

    Threading model:
        _stop_event: set to stop playback entirely.
        _pause_event: SET means "playing", CLEAR means "paused".
            Initialized as SET (not paused).

    All audio generation and playback happens in the calling thread — the TUI
    calls from a @work(thread=True) worker.
    """

    def __init__(
        self,
        model_name: str = "mlx-community/Kokoro-82M-bf16",
        voice: str = "af_heart",
        speed: float = 1.0,
        lang: str = "a",
    ):
        self.model_name = model_name
        self.voice = voice
        self.speed = speed
        self.lang = lang
        self.sample_rate = SAMPLE_RATE

        # Threading controls
        self._stop_event = threading.Event()
        self._pause_event = threading.Event()
        self._pause_event.set()  # SET = playing (not paused)

        # ffmpeg subprocess handle for the active play_file() stream. stop() kills
        # it to interrupt a blocked stdout read: setting _stop_event alone only
        # takes effect *between* blocks, so a read blocked on a stalled ffmpeg (or
        # a write blocked on a wedged audio device) is otherwise uninterruptible
        # and play_file() hangs forever. Guarded by _proc_lock for cross-thread
        # access (stop() runs on a different thread than play_file()).
        self._current_proc: subprocess.Popen | None = None
        self._proc_lock = threading.Lock()

        # Playback position tracking
        self._playing = False
        self._paused = False
        self.current_paragraph_idx: int = 0
        self.current_segment_idx: int = 0
        self._sample_offset: int = 0

        # Continuous playback position in seconds (episode time). Updated block
        # by block while streaming a file so a checkpoint can read "resume at T
        # seconds" mid-playback. Reset to the seek offset at the start of each
        # play_file() call. See the playback_time_s property.
        self._playback_time_s: float = 0.0

    def _play_audio(self, audio_np: np.ndarray):
        """Play a numpy audio array with pause/resume/stop support.

        Uses sounddevice.OutputStream with a block-write loop (block_size=1024,
        ~42ms at 24kHz) for responsive pause latency. Checks _stop_event each
        block and waits on _pause_event (zero CPU while paused).

        Saves _sample_offset on interruption for resume tracking.

        Raises:
            RuntimeError: If the audio device cannot be opened or playback fails.
        """
        import sounddevice as sd

        self._sample_offset = 0
        block_size = 1024
        try:
            stream = sd.OutputStream(samplerate=self.sample_rate, channels=1, dtype="float32")
            stream.start()
        except sd.PortAudioError as e:
            raise RuntimeError(f"Audio device error — cannot open output stream: {e}") from e
        try:
            offset = 0
            while offset < len(audio_np):
                if self._stop_event.is_set():
                    break
                self._pause_event.wait()  # Blocks while paused (zero CPU)
                if self._stop_event.is_set():
                    break
                end = min(offset + block_size, len(audio_np))
                try:
                    stream.write(audio_np[offset:end].reshape(-1, 1))
                except sd.PortAudioError as e:
                    raise RuntimeError(f"Audio playback error during write: {e}") from e
                offset = end
            self._sample_offset = offset
        finally:
            stream.stop()
            stream.close()

    def _stream_pcm(
        self,
        chunks: Iterable[np.ndarray],
        *,
        start_time_s: float = 0.0,
        on_block: Callable[[float], None] | None = None,
    ) -> None:
        """Stream float32 PCM chunks to the output device block by block.

        Shares the block-write discipline of :meth:`_play_audio` — opens one
        ``sd.OutputStream``, writes in fixed 1024-sample blocks, checks
        ``_stop_event`` each block and waits on ``_pause_event`` (SET=playing,
        CLEAR=paused) so pause/stop stay responsive regardless of how large the
        upstream chunks are. Peak resident PCM is O(one input chunk + one block),
        never O(episode): chunks are consumed lazily from ``chunks``.

        As samples are emitted, ``self._playback_time_s`` is advanced from the
        running total of samples written (offset by ``start_time_s``) so a
        checkpoint can read the true episode position mid-playback.

        Args:
            chunks: Iterable yielding 1-D float32 numpy arrays of mono PCM at
                ``self.sample_rate``. Consumed lazily.
            start_time_s: Episode time in seconds corresponding to the first
                emitted sample (the ffmpeg seek target on resume). Sets the
                initial value of ``self._playback_time_s``.
            on_block: Optional callback invoked with the current episode time in
                seconds after each block is written. Used by :meth:`play_file`
                to detect transcript-segment boundary crossings.

        Raises:
            RuntimeError: If the audio device cannot be opened or a write fails.
        """
        import sounddevice as sd

        block_size = 1024  # Match _play_audio (~42ms at 24kHz) for pause latency.
        self._sample_offset = 0
        self._playback_time_s = start_time_s
        emitted = 0  # Total samples written since start (excludes seek offset).

        try:
            stream = sd.OutputStream(samplerate=self.sample_rate, channels=1, dtype="float32")
            stream.start()
        except sd.PortAudioError as e:
            raise RuntimeError(f"Audio device error — cannot open output stream: {e}") from e

        # Carry a remainder so unaligned upstream chunks still write full blocks.
        carry = np.empty(0, dtype=np.float32)
        try:

            def _write_block(block: np.ndarray) -> None:
                nonlocal emitted
                try:
                    stream.write(block.reshape(-1, 1))
                except sd.PortAudioError as e:
                    raise RuntimeError(f"Audio playback error during write: {e}") from e
                emitted += len(block)
                self._sample_offset = emitted
                self._playback_time_s = start_time_s + emitted / self.sample_rate
                if on_block is not None:
                    on_block(self._playback_time_s)

            for chunk in chunks:
                if self._stop_event.is_set():
                    break
                if len(chunk) == 0:
                    continue
                if len(carry):
                    chunk = np.concatenate((carry, chunk))
                    carry = np.empty(0, dtype=np.float32)

                offset = 0
                n = len(chunk)
                while offset + block_size <= n:
                    if self._stop_event.is_set():
                        break
                    self._pause_event.wait()  # Blocks while paused (zero CPU).
                    if self._stop_event.is_set():
                        break
                    _write_block(chunk[offset : offset + block_size])
                    offset += block_size

                if self._stop_event.is_set():
                    break
                # Hold the sub-block tail until the next chunk fills a block.
                if offset < n:
                    carry = chunk[offset:].copy()

            # Flush the final partial block (end of stream, not a stop).
            if not self._stop_event.is_set() and len(carry):
                self._pause_event.wait()
                if not self._stop_event.is_set():
                    _write_block(carry)
        finally:
            stream.stop()
            stream.close()

    def play_audio(self, audio_np: np.ndarray):
        """Play pre-generated audio (e.g. from cache) with pause/resume/stop.

        Clears _stop_event at entry so a previous skip doesn't block the next call.

        Args:
            audio_np: Float32 numpy array of audio samples at self.sample_rate.
        """
        self._stop_event.clear()
        self._play_audio(audio_np)

    def generate_and_play(self, text: str):
        """Generate TTS for a single text string and play it.

        Intended to be called from the TUI worker loop, once per paragraph.
        Clears _stop_event at entry so that a previous skip (which sets
        _stop_event without cancelling the worker) doesn't block the next call.

        Args:
            text: The text to synthesize and play.

        Raises:
            RuntimeError: If daemon synthesis or audio playback fails.
        """
        self._generate_and_play_via_daemon(text)

    def _generate_and_play_via_daemon(self, text: str) -> None:
        """Stream a paragraph's TTS through the speech daemon.

        Routes the SAME voice/speed/lang/model params through
        ``client.tts_stream``, which yields raw little-endian float32 PCM chunks
        whose concatenation is sample-identical to the in-process path (PM-7).
        Each ``bytes`` chunk is converted to a float32 numpy array
        (``np.frombuffer``) and the LAZY chunk iterator is fed straight into
        :meth:`_stream_pcm` — never pre-drained into a list — so audio starts at
        the first daemon chunk (low first-audio latency) and an early close still
        cancels the in-flight synthesis.

        INV-6 (typed-error fidelity): every daemon typed failure, including
        ``DaemonUnavailable``,
        (``Timeout`` / ``GpuAborted`` / ``GpuSegfault`` / ``WorkerError`` /
        ``ConnectionLost`` — all ``client.*`` re-exports of the isolated classes)
        is a real synthesis failure. It surfaces as the SAME ``RuntimeError`` the
        raises a ``RuntimeError`` with the typed error chained (``__cause__``),
        so a missing daemon fails loudly and actionably.

        CV-2 (daemon-killed-mid-stream): if the broker dies while streaming,
        ``client.tts_stream`` raises a typed error mid-iteration; :meth:`_stream_pcm`
        does not catch it, so it propagates cleanly (no hang on a half-filled carry
        buffer, no silent truncation to silence). A stop/skip (``_stop_event``)
        mid-stream instead breaks ``_stream_pcm`` cleanly; either way the
        ``finally`` closes the daemon generator so the broker sees EOF and CANCELs
        the in-flight synthesis.
        """
        self._stop_event.clear()

        pcm_stream = client.tts_stream(
            text,
            voice=self.voice,
            speed=self.speed,
            model=self.model_name,
            lang_code=self.lang,
        )
        try:
            try:
                first = next(pcm_stream)
            except StopIteration:
                return  # empty synthesis (no segments) — nothing to play

            def _chunks():
                # bytes -> float32 numpy (PM-7: the concatenation reconstructs the
                # same samples tts_wav would write). Lazy: one input chunk resident.
                yield np.frombuffer(first, dtype=np.float32)
                for chunk in pcm_stream:
                    yield np.frombuffer(chunk, dtype=np.float32)

            self._stream_pcm(_chunks())
        except client.IsolatedError as e:
            raise _tts_generation_error(e) from e
        finally:
            # stop/skip OR any error: closing the daemon generator makes the broker
            # see EOF and CANCEL the in-flight synthesis (CV-2 cleanup). Idempotent
            # — a no-op if the generator already finished or raised.
            pcm_stream.close()

    def play_article(
        self,
        text: str,
        start_paragraph: int = 0,
        on_progress: Callable | None = None,
    ):
        """Generate and play TTS for an article, paragraph by paragraph.

        Args:
            text: Full article text.
            start_paragraph: Paragraph index to start from (for resume).
            on_progress: Callback called after each segment with
                (paragraph_idx, segment_idx, total_paragraphs, current_text).

        Each paragraph's segments stream from the resident speech daemon:
        ``client.tts_stream`` yields exactly one PCM blob per synthesized
        segment (PM-7), so the paragraph->segment split and the
        ``on_progress`` contract are preserved byte-identically.
        """
        self._stop_event.clear()
        self._playing = True
        self._paused = False

        paragraphs = split_paragraphs(text)
        total_paragraphs = len(paragraphs)

        try:
            for para_idx in range(start_paragraph, total_paragraphs):
                if self._stop_event.is_set():
                    break

                self.current_paragraph_idx = para_idx
                paragraph_text = paragraphs[para_idx]

                self._play_paragraph_via_daemon(paragraph_text, para_idx, total_paragraphs, on_progress)
        finally:
            self._playing = False

    def _play_paragraph_via_daemon(
        self,
        paragraph_text: str,
        para_idx: int,
        total_paragraphs: int,
        on_progress: Callable | None,
    ) -> None:
        """Stream one paragraph's segments through the speech daemon.

        ``client.tts_stream`` yields exactly one raw little-endian float32 PCM
        blob per synthesized segment (PM-7), so each yielded chunk is a
        paragraph segment. The ``on_progress(para_idx, seg_idx, total_paragraphs,
        paragraph_text)`` emission, one call per segment, in order.

        INV-6 (typed-error fidelity): every typed daemon failure, including
        ``DaemonUnavailable``, surfaces as ``RuntimeError`` with the typed
        error chained (``__cause__``).

        CV-2 (daemon-killed-mid-paragraph): if the broker dies between
        segments, the typed error raises out of the segment loop BEFORE the
        killed segment's ``_play_audio``/``on_progress`` run — ``on_progress``
        has already fired for every segment that actually played and never
        fires for the segment that didn't, so progress tracking cannot desync.
        There is no carry buffer here (each daemon chunk is one complete
        segment played in a single :meth:`_play_audio` call, unlike
        :meth:`_stream_pcm`'s sub-block carry), so a mid-stream kill can never
        hang on a half-filled buffer — it propagates cleanly and the daemon
        generator is always closed in ``finally`` (broker sees EOF -> CANCEL).
        A stop/skip mid-paragraph instead breaks the segment loop cleanly,
        same as the in-process path.
        """
        pcm_stream = client.tts_stream(
            paragraph_text,
            voice=self.voice,
            speed=self.speed,
            model=self.model_name,
            lang_code=self.lang,
        )
        try:
            try:
                first = next(pcm_stream)
            except StopIteration:
                return  # empty synthesis (no segments) — nothing to play

            def _segment_chunks():
                yield first
                yield from pcm_stream

            for seg_idx, chunk in enumerate(_segment_chunks()):
                if self._stop_event.is_set():
                    break

                self.current_segment_idx = seg_idx
                self._play_audio(np.frombuffer(chunk, dtype=np.float32))

                if on_progress is not None:
                    on_progress(para_idx, seg_idx, total_paragraphs, paragraph_text)
        except client.IsolatedError as e:
            raise _tts_generation_error(e) from e
        finally:
            pcm_stream.close()

    def generate_audio(
        self,
        text: str,
        *,
        voice: str | None = None,
        lang: str | None = None,
        speed: float | None = None,
    ) -> np.ndarray:
        """Generate TTS audio for text and return as numpy array (no playback).

        Args:
            text: The text to synthesize.
            voice: Override voice (falls back to self.voice).
            lang: Override language (falls back to self.lang).
            speed: Override speed (falls back to self.speed).

        Raises RuntimeError on daemon generation failure. Returns an empty
        float32 array (never raises) when synthesis produces no segments (PM-11).
        """
        return self._generate_audio_via_daemon(text, voice=voice, lang=lang, speed=speed)

    def _generate_audio_via_daemon(
        self,
        text: str,
        *,
        voice: str | None = None,
        lang: str | None = None,
        speed: float | None = None,
    ) -> np.ndarray:
        """Generate TTS audio via the speech daemon.

        Routes the SAME voice/speed/lang/model params through
        ``client.tts_stream`` and concatenates its raw little-endian float32 PCM
        chunks into one array (PM-7). Unlike the playback paths there is no audio
        device to feed lazily and the caller wants the finished array, so the
        chunk iterator is drained eagerly here — but the empty-synthesis guard
        still applies: zero chunks return ``np.array([], dtype=np.float32)``
        rather than calling ``np.concatenate([])``, which raises (PM-11).

        Every typed daemon failure, including ``DaemonUnavailable``, maps to a
        ``RuntimeError`` with the typed error chained (``__cause__``).
        """
        eff_voice = voice if voice is not None else self.voice
        eff_lang = lang if lang is not None else self.lang
        eff_speed = speed if speed is not None else self.speed

        pcm_stream = client.tts_stream(
            text,
            voice=eff_voice,
            speed=eff_speed,
            model=self.model_name,
            lang_code=eff_lang,
        )
        chunks: list[np.ndarray] = []
        try:
            try:
                first = next(pcm_stream)
            except StopIteration:
                return np.array([], dtype=np.float32)  # empty synthesis (PM-11)

            chunks.append(np.frombuffer(first, dtype=np.float32))
            for chunk in pcm_stream:
                chunks.append(np.frombuffer(chunk, dtype=np.float32))
        except client.IsolatedError as e:
            raise _tts_generation_error(e) from e
        finally:
            pcm_stream.close()

        return np.concatenate(chunks) if chunks else np.array([], dtype=np.float32)

    def play_file(
        self,
        path: str | Path,
        transcript_segments: list | None = None,
        start_segment: int = 0,
        on_progress: Callable | None = None,
    ) -> None:
        """Play an audio file from disk with pause/resume/stop support.

        Streams the file through ffmpeg to raw PCM float32 mono at
        ``self.sample_rate`` and feeds it to the output device in 1024-sample
        blocks (see :meth:`_stream_pcm`). Peak resident PCM is O(one chunk),
        never O(episode) — a 94-minute episode no longer materializes ~542 MB or
        stalls the first audio by several seconds while the whole file decodes.

        Position tracking:
            ``self._playback_time_s`` (readable via ``playback_time_s``) tracks
            continuous episode time in seconds for checkpointing. On resume it
            starts at the seek target. When ``transcript_segments`` is given,
            ``current_segment_idx`` advances and ``on_progress`` fires exactly
            once as playback crosses into each segment.

        Resume:
            When ``start_segment > 0`` ffmpeg seeks to
            ``transcript_segments[start_segment].start_s`` (accurate output seek,
            ``-i FILE -ss T``) rather than decoding and discarding the prefix.

        Args:
            path: Path to audio file (MP3, AAC, M4A, WAV, FLAC, OGG).
            transcript_segments: Optional list of segment objects for position
                tracking. Each must have start_s, end_s, text attributes.
            start_segment: Segment index to start playback from (for resume).
            on_progress: Callback(segment_idx, total_segments, current_text)
                called when playback crosses into a new transcript segment.

        Raises:
            FileNotFoundError: If the audio file does not exist.
            RuntimeError: If ffmpeg decoding fails with a *non-zero* exit.

        Note:
            A *truncated* decode is NOT detected here. ffmpeg can exit 0 after
            stopping early on a corrupt/truncated stream, so this method returns
            normally even though playback fell short of the file's real duration
            (``playback_time_s`` will lag ``get_file_duration``). Completion
            cleanliness is the caller's responsibility: the station path verifies
            it in ``MacPlaybackAdapter._on_play_file_finished`` (PM-10) by
            comparing ``playback_time_s`` against ``get_file_duration`` and only
            reports ``ENDED`` within tolerance. Do not treat a normal return as
            proof the whole file played.
        """
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(f"Audio file not found: {path}")

        # Resume seek: jump ffmpeg to the start segment's timestamp instead of
        # decoding-and-discarding the prefix. Accurate output seek (-i then -ss)
        # decodes from the previous keyframe and drops frames up to T, so the
        # first emitted sample lands on true episode time T — worth the small
        # startup cost over fast input seek, which would snap to a keyframe and
        # desync transcript-segment tracking.
        seek_time_s = 0.0
        if transcript_segments is not None and start_segment > 0:
            seek_time_s = float(transcript_segments[start_segment].start_s)

        # -hide_banner/-loglevel error/-nostats stop ffmpeg from streaming its
        # banner and periodic "size=... time=..." progress lines to stderr. We
        # read stdout at playback rate and drain stderr only after the stream
        # ends, so an unbounded stderr would fill its ~64 KB pipe buffer, block
        # ffmpeg's next stderr write, and thereby stall its stdout output —
        # deadlocking playback partway through a long episode. `-loglevel error`
        # still lets genuine decode errors through for the failure check below.
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats"]
        cmd += ["-i", str(path)]
        if seek_time_s > 0.0:
            cmd += ["-ss", f"{seek_time_s:.6f}"]
        cmd += ["-f", "f32le", "-ar", str(self.sample_rate), "-ac", "1", "pipe:1"]

        self._stop_event.clear()
        self._playing = True
        self._paused = False

        # Segment-crossing state for the on_block callback. Segments are in time
        # order; advance a cursor as episode time crosses each boundary and fire
        # on_progress exactly once per segment. The cursor starts at
        # start_segment: the first block's episode time is at/after that
        # segment's start_s (the seek target), so it fires immediately.
        seg_cursor = start_segment
        total_segments = len(transcript_segments) if transcript_segments is not None else 0

        def _on_block(episode_time_s: float) -> None:
            nonlocal seg_cursor
            if transcript_segments is None:
                return
            while seg_cursor < total_segments and episode_time_s >= transcript_segments[seg_cursor].start_s:
                self.current_segment_idx = seg_cursor
                if on_progress is not None:
                    seg = transcript_segments[seg_cursor]
                    on_progress(seg_cursor, total_segments, seg.text)
                seg_cursor += 1

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with self._proc_lock:
            self._current_proc = proc
        # Read one block's worth of float32 per iteration (O(chunk) resident).
        chunk_bytes = 1024 * np.dtype(np.float32).itemsize
        try:

            def _pcm_chunks():
                while True:
                    raw = proc.stdout.read(chunk_bytes)
                    if not raw:
                        break
                    yield np.frombuffer(raw, dtype=np.float32)

            self._stream_pcm(_pcm_chunks(), start_time_s=seek_time_s, on_block=_on_block)

            # If we consumed the stream to the end (not a user stop), the process
            # should have exited cleanly. Detect ffmpeg failure after streaming.
            if not self._stop_event.is_set():
                proc.wait()
                if proc.returncode not in (0, None):
                    stderr = proc.stderr.read().decode(errors="replace")[:500]
                    raise RuntimeError(f"ffmpeg decode failed (exit {proc.returncode}): {stderr}")
        finally:
            # Reap ffmpeg on stop OR exception — no zombies, no leaked pipes.
            # Clear the handle first so a concurrent stop() can't kill a proc we
            # are already reaping. Reap best-effort (stop() may have killed it).
            with self._proc_lock:
                self._current_proc = None
            try:
                if proc.poll() is None:
                    proc.kill()
                proc.wait()
            except Exception:  # noqa: BLE001 - reaping is best-effort, never mask the real error
                pass
            if proc.stdout is not None:
                proc.stdout.close()
            if proc.stderr is not None:
                proc.stderr.close()
            self._playing = False

    def get_file_duration(self, path: str | Path) -> float:
        """Return the duration in seconds of an audio file using ffprobe.

        Args:
            path: Path to audio file.

        Raises:
            FileNotFoundError: If the audio file does not exist.
            RuntimeError: If ffprobe fails or returns invalid output.
        """
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(f"Audio file not found: {path}")

        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "quiet",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"ffprobe failed (exit {result.returncode}): {result.stderr.decode(errors='replace')[:500]}"
            )

        try:
            return float(result.stdout.decode().strip())
        except ValueError as e:
            raise RuntimeError(f"ffprobe returned invalid duration: {result.stdout.decode().strip()!r}") from e

    def pause(self):
        """Pause playback. The write loop blocks until resume()."""
        self._pause_event.clear()
        self._paused = True

    def resume(self):
        """Resume playback after pause."""
        self._pause_event.set()
        self._paused = False

    def stop(self):
        """Stop playback entirely.

        Sets ``_stop_event`` (the write loop exits on its next block check) and,
        critically, kills any in-flight ``play_file`` ffmpeg process so a
        ``proc.stdout.read()`` that is blocked on a stalled ffmpeg returns EOF at
        once. Without the kill, ``_stop_event`` is only observed *between* blocks,
        so a blocked read/write makes ``play_file`` hang forever regardless of
        stop() — the bug behind the measurement-harness freeze. Safe to call from
        any thread and never raises.
        """
        self._stop_event.set()
        self._pause_event.set()  # Unblock if paused so the loop can exit
        self._paused = False
        with self._proc_lock:
            proc = self._current_proc
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.kill()
            except Exception:  # noqa: BLE001 - stop() must never raise
                pass

    @property
    def playback_time_s(self) -> float:
        """Continuous playback position in seconds (episode time).

        Updated block by block while :meth:`play_file` streams, so a checkpoint
        can read the current "resume at T seconds" position mid-playback. On a
        resume it starts at the ffmpeg seek target rather than zero. Reflects
        true episode time, not time-since-play-started.
        """
        return self._playback_time_s

    @property
    def is_playing(self) -> bool:
        """True if playback is active (including when paused)."""
        return self._playing

    @property
    def is_paused(self) -> bool:
        """True if playback is paused."""
        return self._paused


def export_to_wav(
    engine: AudioEngine,
    chunks: list[str],
    filepath: str,
    *,
    on_progress: Callable[[int, int], None] | None = None,
    should_cancel: Callable[[], bool] | None = None,
) -> None:
    """Generate TTS audio for text chunks and write to a WAV file.

    Args:
        engine: AudioEngine instance used for daemon-backed synthesis.
        chunks: Pre-split text chunks (paragraphs or sentence groups).
        filepath: Output WAV file path.
        on_progress: Optional callback called with (current_chunk, total_chunks).
        should_cancel: Optional callback returning True to abort export.
            Checked between chunks. Raises InterruptedError on cancellation.

    Raises:
        ValueError: If chunks is empty or no audio is generated.
        RuntimeError: If TTS generation fails.
        InterruptedError: If should_cancel returns True.
    """
    if not chunks:
        raise ValueError("No text chunks to export")

    all_audio = []
    total = len(chunks)

    for i, chunk in enumerate(chunks):
        if should_cancel is not None and should_cancel():
            raise InterruptedError("Export cancelled")
        audio = engine.generate_audio(chunk)
        if len(audio) > 0:
            all_audio.append(audio)
        if on_progress is not None:
            on_progress(i + 1, total)

    if not all_audio:
        raise ValueError("No audio generated")

    combined = np.concatenate(all_audio)

    from mlx_audio.audio_io import write as audio_write

    audio_write(filepath, combined, engine.sample_rate)
