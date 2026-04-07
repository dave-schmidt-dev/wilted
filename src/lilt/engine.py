"""Audio engine — TTS generation and playback with pause/resume/stop controls."""

import os
import sys
import threading
from collections.abc import Callable, Iterable

import numpy as np
import sounddevice as sd

from lilt.text import split_paragraphs

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

    ``huggingface_hub``'s download stack (especially the ``hf_xet`` Rust
    extension) is unstable inside the Textual TUI on macOS — open file
    descriptors from the event loop cause ``bad value(s) in fds_to_keep``
    during subprocess forking.

    When the model is already cached we can sidestep the entire download stack
    by telling ``huggingface_hub`` to work offline.  If the model is *not*
    cached, we fall back to the env-var + sys.modules approach so that a plain
    HTTP download can still succeed.

    Set ``LILT_ENABLE_HF_XET=1`` to opt back into Xet-backed downloads.
    """
    if os.environ.get("LILT_ENABLE_HF_XET", "").lower() in {"1", "true", "yes"}:
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

    def load_model(self):
        """Lazy-load the TTS model. No-op if already loaded."""
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

        try:
            result = self._model.generate(text, voice=self.voice, speed=self.speed, lang_code=self.lang)
        except Exception as e:
            raise RuntimeError(f"TTS generation failed: {e}") from e

        segments = _normalize_segments(result)

        for segment in segments:
            if self._stop_event.is_set():
                break
            audio_np = np.array(segment.audio, dtype=np.float32)
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
                result = self._model.generate(
                    paragraph_text,
                    voice=self.voice,
                    speed=self.speed,
                    lang_code=self.lang,
                )

                segments = _normalize_segments(result)

                for seg_idx, segment in enumerate(segments):
                    if self._stop_event.is_set():
                        break

                    self.current_segment_idx = seg_idx
                    audio_np = np.array(segment.audio, dtype=np.float32)
                    self._play_audio(audio_np)

                    if on_progress is not None:
                        on_progress(para_idx, seg_idx, total_paragraphs, paragraph_text)
        finally:
            self._playing = False

    def generate_audio(self, text: str) -> np.ndarray:
        """Generate TTS audio for text and return as numpy array (no playback).

        Raises RuntimeError on model or generation failure.
        """
        self.load_model()
        try:
            result = self._model.generate(text, voice=self.voice, speed=self.speed, lang_code=self.lang)
        except Exception as e:
            raise RuntimeError(f"TTS generation failed: {e}") from e

        segments = _normalize_segments(result)
        all_audio = []
        for segment in segments:
            audio_arr = np.array(segment.audio, dtype=np.float32)
            all_audio.append(audio_arr)

        return np.concatenate(all_audio) if all_audio else np.array([], dtype=np.float32)

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
    def is_playing(self) -> bool:
        """True if playback is active (including when paused)."""
        return self._playing

    @property
    def is_paused(self) -> bool:
        """True if playback is paused."""
        return self._paused
