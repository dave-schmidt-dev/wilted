"""Tests for wilted.station_runtime.normalize.

Covers Task 2.3 (Item -> MediaDescriptor normalization):

- Podcast with a transcript: playable, sha resolves to immutable bytes,
  transcript segments are converted seconds->ms via the single tested
  helper, safe_interruption is WINDOWED.
- Podcast without a transcript: still playable (FinalizationState is
  independent of safe_interruption), but safe_interruption is explicitly
  NO_INTERRUPT (the no-transcript rule).
- Article: delegates to article_assembly, segments/sha/duration come from
  the assembled cache.
- The ms<->s conversion helper, unit-tested directly (including a
  regression guard for a dropped/wrong multiplication factor).
- Unfinalized items refuse rather than fabricate a descriptor: article with
  an incomplete cache raises ArticleCacheIncompleteError; podcast with no
  audio_file raises ItemNotFinalizedError and publishes no blob.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import UTC, datetime

import pytest

import wilted
from wilted.db import Item
from wilted.station.models import InterruptionMode
from wilted.station_runtime import media_store
from wilted.station_runtime.article_assembly import ArticleCacheIncompleteError
from wilted.station_runtime.normalize import (
    ItemNotFinalizedError,
    _transcribe_segment_to_station_ms,
    normalize_item,
)
from wilted.transcribe import TranscriptSegment as SecondsTranscriptSegment
from wilted.transcribe import save_transcript

FFMPEG_MISSING = shutil.which("ffmpeg") is None


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_item(**kwargs) -> Item:
    defaults = dict(
        feed=None,
        guid="test-guid",
        title="Test Item",
        discovered_at=_now(),
        status="ready",
        status_changed_at=_now(),
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


def _make_tiny_mp3(path, duration_s: float = 0.3) -> None:
    """Synthesize a tiny real mp3 via ffmpeg's anullsrc lavfi source."""
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=24000:cl=mono",
            "-t",
            str(duration_s),
            "-q:a",
            "9",
            str(path),
        ],
        capture_output=True,
        check=True,
    )


def _no_blobs_published() -> bool:
    media_root = wilted.DATA_DIR / "media"
    if not media_root.exists():
        return True
    return not any(media_root.rglob("*")) or all(p.is_dir() for p in media_root.rglob("*"))


# ---------------------------------------------------------------------------
# ms<->s conversion helper
# ---------------------------------------------------------------------------


def test_transcribe_segment_to_station_ms_exact_conversion():
    seg = SecondsTranscriptSegment(start_s=1.5, end_s=3.25, text="hello")
    station_seg = _transcribe_segment_to_station_ms(seg)
    assert station_seg.start_ms == 1500
    assert station_seg.end_ms == 3250
    assert station_seg.text == "hello"


def test_transcribe_segment_to_station_ms_rounds_to_nearest():
    seg = SecondsTranscriptSegment(start_s=1.2345, end_s=1.2344, text="x")
    station_seg = _transcribe_segment_to_station_ms(seg)
    assert station_seg.start_ms == round(1.2345 * 1000)
    assert station_seg.end_ms == round(1.2344 * 1000)


def test_transcribe_segment_to_station_ms_regression_guard_multiplication_factor():
    """Guard against a dropped or wrong (!=1000) multiplication factor.

    Neither "forgot to multiply" (would produce start_ms=126, not 126680)
    nor "wrong factor" raises an exception on its own — both silently
    produce a plausible-looking int. Assert the exact expected value so a
    regression here fails loudly.
    """
    seg = SecondsTranscriptSegment(start_s=126.68, end_s=127.32, text="segment 12")
    station_seg = _transcribe_segment_to_station_ms(seg)
    assert station_seg.start_ms == 126680
    assert station_seg.end_ms == 127320
    # Explicitly rule out the "forgot to multiply" and "divided instead"
    # failure modes.
    assert station_seg.start_ms != 126
    assert station_seg.start_ms != round(126.68 / 1000)


# ---------------------------------------------------------------------------
# Podcast: with transcript
# ---------------------------------------------------------------------------


@pytest.mark.skipif(FFMPEG_MISSING, reason="ffmpeg not on PATH")
def test_normalize_podcast_with_transcript_is_playable_and_windowed(tmp_path):
    audio_path = tmp_path / "episode.mp3"
    _make_tiny_mp3(audio_path, duration_s=2.0)

    segments = [
        SecondsTranscriptSegment(start_s=0.0, end_s=1.0, text="first"),
        SecondsTranscriptSegment(start_s=1.0, end_s=2.0, text="second"),
    ]
    transcript_path = tmp_path / "transcript.json"
    save_transcript(segments, transcript_path)

    item = _make_item(
        item_type="podcast_episode",
        audio_file=str(audio_path),
        transcript_file=str(transcript_path),
        duration_seconds=2.0,
    )

    descriptor = normalize_item(item)

    assert descriptor.is_playable
    resolved = media_store.path_for(descriptor.sha256)
    assert resolved is not None
    assert resolved.exists()
    assert resolved.stat().st_size == descriptor.byte_size
    # Immutable bytes: the resolved path's content hashes to the same sha.
    import hashlib

    assert hashlib.sha256(resolved.read_bytes()).hexdigest() == descriptor.sha256

    assert len(descriptor.transcript_segments) == 2
    assert descriptor.transcript_segments[0].start_ms == 0
    assert descriptor.transcript_segments[0].end_ms == 1000
    assert descriptor.transcript_segments[1].start_ms == 1000
    assert descriptor.transcript_segments[1].end_ms == 2000
    assert descriptor.duration_ms == 2000

    assert descriptor.safe_interruption.mode is InterruptionMode.WINDOWED
    assert not descriptor.safe_interruption.is_no_interrupt


# ---------------------------------------------------------------------------
# Podcast: without transcript
# ---------------------------------------------------------------------------


@pytest.mark.skipif(FFMPEG_MISSING, reason="ffmpeg not on PATH")
def test_normalize_podcast_without_transcript_playable_but_no_interrupt(tmp_path):
    audio_path = tmp_path / "episode.mp3"
    _make_tiny_mp3(audio_path, duration_s=1.5)

    item = _make_item(
        item_type="podcast_episode",
        audio_file=str(audio_path),
        transcript_file=None,
        duration_seconds=1.5,
    )

    descriptor = normalize_item(item)

    # Playable-but-uninterruptible are independent facts.
    assert descriptor.is_playable is True
    assert descriptor.safe_interruption.is_no_interrupt is True
    assert descriptor.safe_interruption.mode is InterruptionMode.NO_INTERRUPT
    assert descriptor.transcript_segments == ()
    # No transcript, so duration falls back to duration_seconds.
    assert descriptor.duration_ms == 1500


# ---------------------------------------------------------------------------
# Article
# ---------------------------------------------------------------------------


def _write_article_manifest(item_id, *, status: str, paragraphs: list[dict]) -> None:
    cache_dir = wilted.AUDIO_DIR / str(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "article_id": item_id,
        "voice": "af_heart",
        "lang": "a",
        "speed": 1.0,
        "added": _now(),
        "status": status,
        "paragraphs": paragraphs,
    }
    (cache_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))


def _probe_duration_s(path) -> float:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(result.stdout.strip())


@pytest.mark.skipif(FFMPEG_MISSING, reason="ffmpeg not on PATH")
def test_normalize_article_is_playable_and_segments_come_from_assembly():
    item = _make_item(item_type="article", audio_file=None, transcript_file=None)
    item_id = item.id

    cache_dir = wilted.AUDIO_DIR / str(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    durations_s = [0.3, 0.2]
    paragraphs = []
    for idx, dur in enumerate(durations_s):
        filename = f"para_{idx:03d}.mp3"
        _make_tiny_mp3(cache_dir / filename, duration_s=dur)
        real_dur = _probe_duration_s(cache_dir / filename)
        paragraphs.append({"file": filename, "duration_seconds": round(real_dur, 3), "samples": 0})

    _write_article_manifest(item_id, status="complete", paragraphs=paragraphs)

    descriptor = normalize_item(item)

    assert descriptor.is_playable
    resolved = media_store.path_for(descriptor.sha256)
    assert resolved is not None
    assert resolved.exists()
    assert resolved.stat().st_size == descriptor.byte_size

    assert len(descriptor.transcript_segments) == 2
    assert descriptor.transcript_segments[0].text == "para_000.mp3"
    assert descriptor.transcript_segments[1].text == "para_001.mp3"
    assert descriptor.duration_ms == descriptor.transcript_segments[-1].end_ms

    # Article safe_interruption is WINDOWED (it always has segments).
    assert descriptor.safe_interruption.mode is InterruptionMode.WINDOWED


# ---------------------------------------------------------------------------
# Unfinalized items: refuse rather than fabricate
# ---------------------------------------------------------------------------


def test_normalize_article_with_incomplete_cache_raises():
    item = _make_item(item_type="article", audio_file=None, transcript_file=None)
    item_id = item.id
    cache_dir = wilted.AUDIO_DIR / str(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    # No manifest.json at all -> incomplete cache.

    with pytest.raises(ArticleCacheIncompleteError):
        normalize_item(item)

    assert _no_blobs_published()


def test_normalize_podcast_with_no_audio_file_raises_and_publishes_nothing():
    item = _make_item(item_type="podcast_episode", audio_file=None, transcript_file=None)

    with pytest.raises(ItemNotFinalizedError):
        normalize_item(item)

    assert _no_blobs_published()


def test_normalize_podcast_with_missing_audio_file_raises(tmp_path):
    missing_path = tmp_path / "does_not_exist.mp3"
    item = _make_item(
        item_type="podcast_episode",
        audio_file=str(missing_path),
        transcript_file=None,
    )

    with pytest.raises(ItemNotFinalizedError):
        normalize_item(item)

    assert _no_blobs_published()


def test_normalize_podcast_with_zero_byte_audio_file_raises(tmp_path):
    zero_byte_path = tmp_path / "empty.mp3"
    zero_byte_path.write_bytes(b"")
    item = _make_item(
        item_type="podcast_episode",
        audio_file=str(zero_byte_path),
        transcript_file=None,
    )

    with pytest.raises(ItemNotFinalizedError):
        normalize_item(item)

    assert _no_blobs_published()
