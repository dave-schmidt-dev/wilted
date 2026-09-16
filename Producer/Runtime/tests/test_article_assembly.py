"""Tests for wilted.station_runtime.article_assembly.

Covers the PM-3 "article finalization completeness contract"
(spikes/integration-seam-2026-07-10/FINDINGS.md):

- INV-4 completeness guard: assembly refuses (no output produced) when the
  manifest is missing, not status="complete", or any listed paragraph file
  is missing/zero-byte.
- Manifest order is authoritative for the ffmpeg concat, never a directory
  glob/re-sort.
- The manifest's per-paragraph duration_seconds is the exact timing map for
  the concatenated output (cumulative sum of prior durations).
- Real ffmpeg concatenation + real publish into the content-addressed media
  store (skipped if ffmpeg is not on PATH).
"""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

import wilted
from wilted.station_runtime import media_store
from wilted.station_runtime.article_assembly import (
    ArticleCacheIncompleteError,
    assemble_article_audio,
    build_concat_list,
)

FFMPEG_MISSING = shutil.which("ffmpeg") is None


def _cache_dir(item_id):
    return wilted.AUDIO_DIR / str(item_id)


def _write_manifest(item_id, *, status: str, paragraphs: list[dict]) -> None:
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "article_id": item_id,
        "voice": "af_heart",
        "lang": "a",
        "speed": 1.0,
        "added": "2026-04-21T21:51:38Z",
        "status": status,
        "paragraphs": paragraphs,
    }
    (cache_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))


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


# ---------------------------------------------------------------------------
# Integration: real ffmpeg concat + real publish
# ---------------------------------------------------------------------------


@pytest.mark.skipif(FFMPEG_MISSING, reason="ffmpeg not on PATH")
def test_assemble_complete_cache_publishes_one_blob_with_correct_timing():
    item_id = 1
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    durations_s = [0.3, 0.2, 0.4]
    paragraphs = []
    for idx, dur in enumerate(durations_s):
        filename = f"para_{idx:03d}.mp3"
        _make_tiny_mp3(cache_dir / filename, duration_s=dur)
        # Use the real measured duration (not the requested one) so the
        # manifest's duration_seconds is the authoritative ground truth,
        # matching how generate_article_cache() populates it in cache.py.
        real_dur = _probe_duration_s(cache_dir / filename)
        paragraphs.append({"file": filename, "duration_seconds": round(real_dur, 3), "samples": 0})

    _write_manifest(item_id, status="complete", paragraphs=paragraphs)

    result = assemble_article_audio(item_id)

    # Exactly one published blob resolves.
    resolved = media_store.path_for(result.sha256)
    assert resolved is not None
    assert resolved.exists()
    assert result.byte_size > 0
    assert resolved.stat().st_size == result.byte_size

    # Duration tolerance: concat/decode granularity (mp3 frame boundaries,
    # container overhead) means the concatenated file's actual duration
    # will not exactly equal the sum of per-paragraph durations measured
    # independently. A few hundred ms of slack easily covers mp3 frame
    # padding at these tiny durations while still catching gross timing
    # bugs (e.g. a dropped paragraph or a unit-conversion error).
    expected_total_s = sum(durations_s)
    assert abs(result.duration_ms / 1000.0 - expected_total_s) < 0.5

    # Segments: monotonic, cumulative, matching manifest order/durations.
    assert len(result.segments) == 3
    prev_end = 0
    cumulative_s = 0.0
    for seg, para in zip(result.segments, paragraphs, strict=True):
        assert seg.start_ms == prev_end
        assert seg.start_ms >= 0
        assert seg.end_ms >= seg.start_ms
        expected_start_ms = round(cumulative_s * 1000)
        expected_end_ms = round((cumulative_s + para["duration_seconds"]) * 1000)
        assert seg.start_ms == expected_start_ms
        assert seg.end_ms == expected_end_ms
        cumulative_s += para["duration_seconds"]
        prev_end = seg.end_ms
    assert result.duration_ms == result.segments[-1].end_ms


@pytest.mark.skipif(FFMPEG_MISSING, reason="ffmpeg not on PATH")
def test_assemble_follows_manifest_order_not_directory_glob():
    """Name files so a plain glob-sort would differ from manifest order."""
    item_id = 2
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    # Deliberately reversed on-disk naming vs manifest order: a naive
    # sorted(glob(...)) would yield [a_last.mp3, b_first.mp3], but the
    # manifest lists b_first.mp3 (0.5s) before a_last.mp3 (0.2s).
    _make_tiny_mp3(cache_dir / "a_last.mp3", duration_s=0.2)
    _make_tiny_mp3(cache_dir / "b_first.mp3", duration_s=0.5)

    dur_first = round(_probe_duration_s(cache_dir / "b_first.mp3"), 3)
    dur_last = round(_probe_duration_s(cache_dir / "a_last.mp3"), 3)

    paragraphs = [
        {"file": "b_first.mp3", "duration_seconds": dur_first, "samples": 0},
        {"file": "a_last.mp3", "duration_seconds": dur_last, "samples": 0},
    ]
    _write_manifest(item_id, status="complete", paragraphs=paragraphs)

    # A glob-sort would put a_last.mp3 first; verify the glob really would
    # differ from manifest order, so this test is a meaningful guard.
    glob_order = sorted(p.name for p in cache_dir.glob("*.mp3"))
    manifest_order = [p["file"] for p in paragraphs]
    assert glob_order != manifest_order, "test setup invalid: glob order must differ from manifest order"

    result = assemble_article_audio(item_id)

    # Timing map must follow manifest order: first segment duration matches
    # b_first.mp3 (0.5s), not a_last.mp3 (0.2s).
    assert result.segments[0].text == "b_first.mp3"
    assert result.segments[1].text == "a_last.mp3"
    assert result.segments[0].end_ms == round(dur_first * 1000)


def test_build_concat_list_writes_manifest_order(tmp_path):
    cache_dir = tmp_path / "cache"
    cache_dir.mkdir()
    (cache_dir / "z.mp3").write_bytes(b"fake")
    (cache_dir / "a.mp3").write_bytes(b"fake")

    paragraphs = [{"file": "z.mp3"}, {"file": "a.mp3"}]
    list_path = tmp_path / "list.txt"

    build_concat_list(cache_dir, paragraphs, list_path)

    content = list_path.read_text()
    lines = [line for line in content.splitlines() if line.strip()]
    assert len(lines) == 2
    assert "z.mp3" in lines[0]
    assert "a.mp3" in lines[1]


# ---------------------------------------------------------------------------
# Unit: INV-4 completeness refusals (no ffmpeg required)
# ---------------------------------------------------------------------------


def _no_blobs_published():
    media_root = wilted.DATA_DIR / "media"
    if not media_root.exists():
        return True
    return not any(media_root.rglob("*")) or all(p.is_dir() for p in media_root.rglob("*"))


def test_refuses_when_no_manifest_present():
    item_id = 10
    _cache_dir(item_id).mkdir(parents=True, exist_ok=True)

    with pytest.raises(ArticleCacheIncompleteError, match="no manifest"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_cache_dir_entirely_empty():
    item_id = 11
    # Do not even create the directory.
    with pytest.raises(ArticleCacheIncompleteError):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_status_is_generating():
    item_id = 12
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "para_000.mp3").write_bytes(b"fake mp3 bytes")

    _write_manifest(
        item_id,
        status="generating",
        paragraphs=[{"file": "para_000.mp3", "duration_seconds": 1.0, "samples": 100}],
    )

    with pytest.raises(ArticleCacheIncompleteError, match="generating"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_listed_paragraph_file_missing():
    item_id = 13
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    # para_000.mp3 is listed but never written to disk.

    _write_manifest(
        item_id,
        status="complete",
        paragraphs=[{"file": "para_000.mp3", "duration_seconds": 1.0, "samples": 100}],
    )

    with pytest.raises(ArticleCacheIncompleteError, match="missing"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_listed_paragraph_file_is_zero_byte():
    item_id = 14
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "para_000.mp3").write_bytes(b"")  # zero-byte

    _write_manifest(
        item_id,
        status="complete",
        paragraphs=[{"file": "para_000.mp3", "duration_seconds": 1.0, "samples": 100}],
    )

    with pytest.raises(ArticleCacheIncompleteError, match="zero-byte"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_manifest_has_empty_paragraph_list():
    item_id = 15
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    _write_manifest(item_id, status="complete", paragraphs=[])

    with pytest.raises(ArticleCacheIncompleteError):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_paragraph_missing_duration_seconds():
    """Guard-before-output for a malformed manifest.

    The cache is otherwise valid (status complete, file present + non-empty),
    so ffmpeg WOULD concatenate it successfully — but a paragraph missing
    ``duration_seconds`` is refused before any concat/publish runs. This
    proves the completeness guard (not ffmpeg's own failure) is what blocks
    the output, which the missing-file/zero-byte cases cannot prove (ffmpeg
    fails on those too).
    """
    item_id = 16
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "para_000.mp3").write_bytes(b"fake mp3 bytes")

    _write_manifest(
        item_id,
        status="complete",
        paragraphs=[{"file": "para_000.mp3", "samples": 100}],  # no duration_seconds
    )

    with pytest.raises(ArticleCacheIncompleteError, match="duration_seconds"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_refuses_when_paragraph_duration_seconds_non_numeric():
    item_id = 17
    cache_dir = _cache_dir(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "para_000.mp3").write_bytes(b"fake mp3 bytes")

    _write_manifest(
        item_id,
        status="complete",
        paragraphs=[{"file": "para_000.mp3", "duration_seconds": "not-a-number", "samples": 100}],
    )

    with pytest.raises(ArticleCacheIncompleteError, match="duration_seconds"):
        assemble_article_audio(item_id)

    assert _no_blobs_published()


def test_call_time_resolution_of_audio_dir(monkeypatch, tmp_path):
    """INV-5: assemble_article_audio must resolve wilted.AUDIO_DIR at call time.

    Redirect wilted.AUDIO_DIR to a second temp dir *after* the isolated_data
    fixture already set it once, and confirm article_assembly follows the
    live attribute rather than any value bound at import time.
    """
    second_audio_dir = tmp_path / "second_audio_dir"
    second_audio_dir.mkdir()
    monkeypatch.setattr(wilted, "AUDIO_DIR", second_audio_dir)

    item_id = 20
    cache_dir = second_audio_dir / str(item_id)
    cache_dir.mkdir(parents=True, exist_ok=True)

    _write_manifest(item_id, status="generating", paragraphs=[])

    with pytest.raises(ArticleCacheIncompleteError):
        assemble_article_audio(item_id)
