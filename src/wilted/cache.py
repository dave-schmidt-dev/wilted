"""Audio cache — per-paragraph MP3 storage with manifest tracking."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from typing import TYPE_CHECKING

from wilted import AUDIO_DIR

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    import numpy as np


def check_ffmpeg() -> None:
    """Verify ffmpeg is available. Raises RuntimeError if not found."""
    try:
        subprocess.run(
            ["ffmpeg", "-version"],
            capture_output=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        raise RuntimeError("ffmpeg is required for audio caching. Install it with: brew install ffmpeg")


def get_cache_dir(article_id: int) -> Path:
    """Return the cache directory for an article."""
    return AUDIO_DIR / str(article_id)


def save_audio(article_id: int, para_idx: int, audio_np: np.ndarray, sample_rate: int) -> Path:
    """Save a paragraph's audio as MP3. Returns the file path."""
    from mlx_audio.audio_io import write as audio_write

    cache_dir = get_cache_dir(article_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    path = cache_dir / f"para_{para_idx:03d}.mp3"
    audio_write(path, audio_np, sample_rate)
    return path


def load_audio(article_id: int, para_idx: int) -> tuple[np.ndarray, int] | None:
    """Load a cached paragraph's audio. Returns (float32 array, sample_rate) or None."""
    path = get_cache_dir(article_id) / f"para_{para_idx:03d}.mp3"
    if not path.exists():
        return None

    from mlx_audio.audio_io import read as audio_read

    audio_np, sample_rate = audio_read(path, dtype="float32")
    return audio_np, sample_rate


def save_manifest(article_id: int, manifest: dict) -> None:
    """Atomically write the manifest JSON for an article."""
    cache_dir = get_cache_dir(article_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = cache_dir / "manifest.json"

    with tempfile.NamedTemporaryFile("w", dir=cache_dir, suffix=".tmp", delete=False) as f:
        json.dump(manifest, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, manifest_path)


def load_manifest(article_id: int) -> dict | None:
    """Load the manifest for an article. Returns None if missing or corrupt."""
    manifest_path = get_cache_dir(article_id) / "manifest.json"
    if not manifest_path.exists():
        return None
    try:
        with open(manifest_path) as f:
            return json.load(f)
    except (json.JSONDecodeError, ValueError):
        return None


def is_cache_valid(article_id: int, voice: str, lang: str, speed: float, added: str) -> bool:
    """Check if the cache matches the expected params and is complete."""
    manifest = load_manifest(article_id)
    if manifest is None:
        return False
    return (
        manifest.get("voice") == voice
        and manifest.get("lang") == lang
        and manifest.get("speed") == speed
        and manifest.get("added") == added
        and manifest.get("status") == "complete"
    )


def is_paragraph_cached(article_id: int, para_idx: int, voice: str, lang: str, speed: float, added: str) -> bool:
    """Check if a specific paragraph has valid cached audio.

    Validates that the manifest params match the requested settings AND the
    MP3 file exists on disk. Used by hybrid playback to decide between
    cache hit (play_audio) and streaming fallback (generate_and_play).
    """
    manifest = load_manifest(article_id)
    if manifest is None:
        return False
    if (
        manifest.get("voice") != voice
        or manifest.get("lang") != lang
        or manifest.get("speed") != speed
        or manifest.get("added") != added
    ):
        return False
    path = get_cache_dir(article_id) / f"para_{para_idx:03d}.mp3"
    return path.exists()


def clear_cache(article_id: int) -> None:
    """Remove the entire audio cache directory for an article."""
    cache_dir = get_cache_dir(article_id)
    if cache_dir.exists():
        shutil.rmtree(cache_dir)


def new_manifest(article_id: int, voice: str, lang: str, speed: float, added: str) -> dict:
    """Create a fresh manifest dict."""
    return {
        "article_id": article_id,
        "voice": voice,
        "lang": lang,
        "speed": speed,
        "added": added,
        "status": "generating",
        "paragraphs": [],
    }


def generate_article_cache(
    engine,
    text: str,
    article_id: int,
    voice: str,
    lang: str,
    speed: float,
    added: str,
    *,
    on_progress: Callable | None = None,
    should_cancel: Callable | None = None,
) -> bool:
    """Generate and cache audio for all paragraphs of an article.

    Args:
        engine: AudioEngine instance (model will be loaded if needed).
        text: Full article text.
        article_id: Queue article ID for cache directory.
        voice: TTS voice ID.
        lang: Language code.
        speed: Playback speed.
        added: Article added timestamp (for cache invalidation).
        on_progress: Called with (para_idx, total_paragraphs) after each paragraph.
        should_cancel: Called between paragraphs; return True to stop.

    Returns:
        True if all paragraphs were cached, False if cancelled.
    """
    from wilted.text import split_paragraphs

    check_ffmpeg()

    paragraphs = split_paragraphs(text)
    if not paragraphs:
        return True

    # Clear stale cache if params changed
    if not is_cache_valid(article_id, voice, lang, speed, added):
        clear_cache(article_id)

    manifest = new_manifest(article_id, voice, lang, speed, added)
    save_manifest(article_id, manifest)

    for para_idx, paragraph in enumerate(paragraphs):
        if should_cancel is not None and should_cancel():
            return False

        # Skip if already cached (e.g. partial generation from earlier run)
        cache_path = get_cache_dir(article_id) / f"para_{para_idx:03d}.mp3"
        if cache_path.exists() and para_idx < len(manifest["paragraphs"]):
            if on_progress is not None:
                on_progress(para_idx, len(paragraphs))
            continue

        audio_np = engine.generate_audio(paragraph, voice=voice, lang=lang, speed=speed)

        save_audio(article_id, para_idx, audio_np, engine.sample_rate)

        duration = len(audio_np) / engine.sample_rate
        samples = len(audio_np)

        manifest["paragraphs"].append(
            {
                "file": f"para_{para_idx:03d}.mp3",
                "duration_seconds": round(duration, 3),
                "samples": samples,
            }
        )
        save_manifest(article_id, manifest)

        if on_progress is not None:
            on_progress(para_idx, len(paragraphs))

    manifest["status"] = "complete"
    save_manifest(article_id, manifest)
    return True
