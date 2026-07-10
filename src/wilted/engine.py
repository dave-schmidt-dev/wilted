"""Audio engine — TTS generation and playback with pause/resume/stop controls."""

import os
import subprocess
import sys
import threading
from collections.abc import Callable, Iterable
from pathlib import Path

import numpy as np

from wilted.text import split_paragraphs

SAMPLE_RATE = 24000  # Kokoro default


def _normalize_segments(result):
    """Normalize model output to an iterable of segment objects.

    `mlx_audio` may return a single segment object, a list of segments, or a
    generator that yields segments. Preserve iterables as-is so playback can
    stream them, but wrap plain segment objects in a one-item list.
    """
    if hasattr(result, "audio"):
        return [result]
    if isinstance(result, Iterable) and not isinstance(result, (str, bytes)):
        return result
    return [result]


def _force_hf_offline_if_cached(model_name: str) -> None:
    """Enable HF offline mode when the model is already in the local cache.

    The first-time Hugging Face download path can be unstable inside a Textual
    worker on macOS because ``snapshot_download()`` initializes ``tqdm``'s
    multiprocessing lock, which may spawn Python's ``resource_tracker``
    subprocess. When this happens from the worker thread, fork/exec can fail
    with ``bad value(s) in fds_to_keep``.

    When the model is already cached we can sidestep the entire download stack
    by telling ``huggingface_hub`` to work offline. The remaining xet-related
    env/sys.modules guards are retained as defense-in-depth for alternative Hub
    code paths, but they are not the root-cause fix for the ``fds_to_keep``
    failure.

    Set ``WILTED_ENABLE_HF_XET=1`` to opt back into Xet-backed downloads.
    """
    if os.environ.get("WILTED_ENABLE_HF_XET", "").lower() in {"1", "true", "yes"}:
        return

    # --- Layer 1: check cache and go offline if present ---
    cache_dir = os.path.join(
        os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface")),
        "hub",
        f"models--{model_name.replace('/', '--')}",
    )
    if os.path.isdir(os.path.join(cache_dir, "snapshots")):
        os.environ["HF_HUB_OFFLINE"] = "1"

    # --- Layer 2: disable xet via env var ---
    os.environ["HF_HUB_DISABLE_XET"] = "1"

    # --- Layer 3: poison hf_xet in sys.modules ---
    for mod_name in list(sys.modules):
        if mod_name == "hf_xet" or mod_name.startswith("hf_xet."):
            del sys.modules[mod_name]
    sys.modules["hf_xet"] = None  # type: ignore[assignment]

    # --- Layer 4: patch already-loaded constants ---
    hub_constants = sys.modules.get("huggingface_hub.constants")
    if hub_constants is not None:
        hub_constants.HF_HUB_DISABLE_XET = True


class AudioEngine:
    """TTS audio engine with thread-safe playback controls.

    Generates speech from text using Kokoro TTS via mlx-audio and plays it
    through sounddevice.OutputStream with block-level pause/resume/stop support.

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

        self._model = None
        self._model_lock = threading.Lock()

        # Threading controls
        self._stop_event = threading.Event()
        self._pause_event = threading.Event()
        self._pause_event.set()  # SET = playing (not paused)

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

    def load_model(self):
        """Lazy-load the TTS model. Thread-safe via _model_lock."""
        if self._model is not None:
            return
        with self._model_lock:
            # Double-check after acquiring lock (another thread may have loaded)
            if self._model is not None:
                return
            try:
                _force_hf_offline_if_cached(self.model_name)
                from mlx_audio.tts.utils import load_model

                self._model = load_model(self.model_name)
            except Exception as e:
                raise RuntimeError(f"Failed to load TTS model '{self.model_name}': {e}") from e

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
            RuntimeError: If model loading, generation, or audio playback fails.
        """
        self._stop_event.clear()
        self.load_model()

        with self._model_lock:
            try:
                result = self._model.generate(text, voice=self.voice, speed=self.speed, lang_code=self.lang)
            except Exception as e:
                raise RuntimeError(f"TTS generation failed: {e}") from e

            # Materialize segments and convert to numpy inside the lock so all
            # MLX GPU operations complete before releasing — prevents concurrent
            # Metal access from another thread.
            audio_arrays = [np.array(seg.audio, dtype=np.float32) for seg in _normalize_segments(result)]

        for audio_np in audio_arrays:
            if self._stop_event.is_set():
                break
            self._play_audio(audio_np)

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
        """
        self.load_model()
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

                # Generate TTS for this paragraph — may yield 1+ segments
                with self._model_lock:
                    result = self._model.generate(
                        paragraph_text,
                        voice=self.voice,
                        speed=self.speed,
                        lang_code=self.lang,
                    )
                    audio_arrays = [np.array(seg.audio, dtype=np.float32) for seg in _normalize_segments(result)]

                for seg_idx, audio_np in enumerate(audio_arrays):
                    if self._stop_event.is_set():
                        break

                    self.current_segment_idx = seg_idx
                    self._play_audio(audio_np)

                    if on_progress is not None:
                        on_progress(para_idx, seg_idx, total_paragraphs, paragraph_text)
        finally:
            self._playing = False

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

        Raises RuntimeError on model or generation failure.
        """
        self.load_model()
        eff_voice = voice if voice is not None else self.voice
        eff_lang = lang if lang is not None else self.lang
        eff_speed = speed if speed is not None else self.speed

        with self._model_lock:
            try:
                result = self._model.generate(text, voice=eff_voice, speed=eff_speed, lang_code=eff_lang)
            except Exception as e:
                raise RuntimeError(f"TTS generation failed: {e}") from e

            all_audio = [np.array(seg.audio, dtype=np.float32) for seg in _normalize_segments(result)]

        return np.concatenate(all_audio) if all_audio else np.array([], dtype=np.float32)

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
            RuntimeError: If ffmpeg decoding fails (non-zero exit).
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
            if proc.poll() is None:
                proc.kill()
                proc.wait()
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
        """Stop playback entirely. The write loop exits on next block check."""
        self._stop_event.set()
        self._pause_event.set()  # Unblock if paused so the loop can exit
        self._paused = False

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
        engine: AudioEngine instance (model will be loaded if needed).
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
