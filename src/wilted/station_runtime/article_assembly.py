"""Assemble a complete per-paragraph article audio cache into one playable file.

Article TTS audio is cached as a per-paragraph directory
(``wilted.AUDIO_DIR/<item_id>/para_NNN.mp3`` + ``manifest.json``), never as a
single file the way podcast ``Item.audio_file`` is — see
``spikes/integration-seam-2026-07-10/FINDINGS.md`` (PM-3) for the full
contract this module implements. To play an article through the same
``engine.play_file(path=...)`` call a podcast uses, the paragraphs must
first be concatenated into one canonical artifact, published into the
content-addressed media store, and given a cumulative timing map.

Scope decision (PM-3 A.2): this module ASSEMBLES an already-complete cache.
It does not itself run TTS to *complete* a partial or missing cache — that
stays upstream, in ``wilted.prepare`` / ``wilted.cache.generate_article_cache``,
which requires a loaded model and is out of scope for a pure assembly step.
:func:`assemble_article_audio` refuses (raises
:class:`ArticleCacheIncompleteError`) rather than coupling itself to model
loading. Callers that need "complete the cache first if necessary, then
assemble" own that two-step orchestration themselves.

``FinalizationState`` mapping (PM-3 section 4): this module produces the
raw materials for ``timing_map_created``, ``hashed``, and ``published`` —
callers are expected to set those three fields from :class:`AssembledArticle`.
``ads_cut`` is NOT set here (that is Task 2.3's normalization concern), but
per the PM-3 spike finding, ad/promo removal for articles happens as a
pre-TTS TEXT operation (``wilted.prepare``'s promo-removal step), not a
post-synthesis audio-domain edit the way ad-cutting is for podcasts. By the
time a paragraph cache reaches this module it has already been synthesized
from already-promo-filtered text, so ``ads_cut`` is vacuously satisfied for
every article and downstream code should treat it as ``True``.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import wilted
from wilted import cache as article_cache
from wilted.station.models import TranscriptSegment
from wilted.station_runtime import media_store

if TYPE_CHECKING:
    from collections.abc import Sequence

__all__ = [
    "AssembledArticle",
    "ArticleCacheIncompleteError",
    "assemble_article_audio",
    "build_concat_list",
]


class ArticleCacheIncompleteError(Exception):
    """Raised when an article's per-paragraph audio cache is not yet complete.

    INV-4: assembly must refuse to produce any output (partial or empty)
    rather than concatenate a partial/missing cache. Covers: no manifest,
    ``manifest["status"] != "complete"``, a manifest-listed paragraph file
    missing on disk, or a manifest-listed paragraph file present but
    zero-byte.
    """


@dataclass(frozen=True, slots=True)
class AssembledArticle:
    """Result of assembling a complete per-paragraph article cache.

    Attributes:
        sha256: Content hash of the final concatenated audio, as published
            into :mod:`wilted.station_runtime.media_store`.
        byte_size: Size in bytes of the published blob.
        duration_ms: Total duration of the concatenated audio, in
            milliseconds (equal to the last segment's ``end_ms``).
        segments: Cumulative per-paragraph timing map, in manifest order,
            as :class:`~wilted.station.models.TranscriptSegment` (ms units).
    """

    sha256: str
    byte_size: int
    duration_ms: int
    segments: tuple[TranscriptSegment, ...]


def _cache_dir(item_id) -> Path:
    """Return the article's per-paragraph cache directory (INV-5: call-time)."""
    return wilted.AUDIO_DIR / str(item_id)


def _require_complete_cache(item_id) -> tuple[Path, list[dict]]:
    """Load and validate the manifest, enforcing the INV-4 completeness guard.

    Returns:
        The cache directory and the manifest's ``paragraphs`` list, in
        manifest order, once every completeness check has passed.

    Raises:
        ArticleCacheIncompleteError: If the manifest is missing, its status
            is not ``"complete"``, or any listed paragraph file is missing
            or zero-byte. No output is produced in any of these cases.
    """
    cache_dir = _cache_dir(item_id)

    manifest = article_cache.load_manifest(item_id)
    if manifest is None:
        raise ArticleCacheIncompleteError(f"article {item_id!r}: no manifest.json found in {cache_dir}")

    status = manifest.get("status")
    if status != "complete":
        raise ArticleCacheIncompleteError(f"article {item_id!r}: manifest status is {status!r}, not 'complete'")

    paragraphs: list[dict] = manifest.get("paragraphs", [])
    if not paragraphs:
        raise ArticleCacheIncompleteError(f"article {item_id!r}: manifest has no paragraphs listed")

    for para in paragraphs:
        filename = para.get("file")
        if not filename:
            raise ArticleCacheIncompleteError(f"article {item_id!r}: manifest paragraph entry missing 'file' key")
        para_path = cache_dir / filename
        if not para_path.exists():
            raise ArticleCacheIncompleteError(f"article {item_id!r}: paragraph file missing: {para_path}")
        if para_path.stat().st_size == 0:
            raise ArticleCacheIncompleteError(f"article {item_id!r}: paragraph file is zero-byte: {para_path}")
        # duration_seconds is the sole source for the timing map (_build_timing_map);
        # validate it HERE so the guard is the single trust boundary for a
        # malformed manifest, rather than letting a raw KeyError/ValueError
        # escape from timing-map construction after the completeness check
        # has already "passed".
        duration = para.get("duration_seconds")
        try:
            duration_s = float(duration)
        except (TypeError, ValueError):
            raise ArticleCacheIncompleteError(
                f"article {item_id!r}: paragraph {filename} has missing/non-numeric "
                f"duration_seconds ({duration!r}); manifest is malformed, not complete"
            ) from None
        if duration_s < 0:
            raise ArticleCacheIncompleteError(
                f"article {item_id!r}: paragraph {filename} has negative duration_seconds ({duration_s})"
            )

    return cache_dir, paragraphs


def build_concat_list(cache_dir: Path, paragraphs: Sequence[dict], list_path: Path) -> None:
    """Write an ffmpeg concat-demuxer list file in manifest order.

    Manifest order (``paragraphs[]`` as read from ``manifest.json``) is
    authoritative and must NEVER be replaced by a directory glob/sort — a
    glob-sort happens to agree with manifest order for zero-padded filenames
    up to 999 paragraphs, but the manifest is the source of truth regardless
    (see PM-3 finding, FINDINGS.md section 3).

    Args:
        cache_dir: The article's per-paragraph cache directory.
        paragraphs: The manifest's ``paragraphs`` list, in manifest order.
        list_path: Path to write the concat-list file to.

    ffmpeg's concat demuxer requires each entry as ``file '<absolute-path>'``
    with any single quotes in the path escaped, one per line.
    """
    lines = []
    for para in paragraphs:
        para_path = cache_dir / para["file"]
        escaped = str(para_path.resolve()).replace("'", "'\\''")
        lines.append(f"file '{escaped}'")
    list_path.write_text("\n".join(lines) + "\n")


def _concat_paragraphs(cache_dir: Path, paragraphs: Sequence[dict]) -> Path:
    """Concatenate paragraph mp3s (stream copy) into a new tempfile, returning its path.

    Runs ``ffmpeg -f concat -safe 0 -i <list> -c copy <tmp_out>``. Both the
    concat-list file and the output file are tempfiles; on ANY failure (a
    non-zero ffmpeg exit, ffmpeg missing from PATH, or a concat-list write
    error) both tempfiles are removed — no partial or orphaned artifact is
    ever left behind or returned to the caller. Only on success is the
    output tempfile handed back (the caller owns unlinking it once published).

    Stream copy (``-c copy``, no re-encode) is safe here because every
    paragraph in a single article cache is synthesized by the same TTS engine
    under the one ``voice``/``lang``/``speed`` recorded at the manifest's top
    level (there is no per-paragraph override), so all paragraph mp3s share
    identical stream parameters (sample rate, channel layout, codec). ``-c
    copy`` across *mismatched* parameters can exit 0 while producing a
    mis-timed file; that cannot arise from a valid single-cache manifest, but
    the precondition is stated because this function concatenates whatever the
    manifest lists.
    """
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as list_file:
        list_path = Path(list_file.name)
    out_fd, out_name = tempfile.mkstemp(suffix=".mp3")
    os.close(out_fd)
    out_path = Path(out_name)

    success = False
    try:
        build_concat_list(cache_dir, paragraphs, list_path)

        result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(list_path),
                "-c",
                "copy",
                str(out_path),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"ffmpeg concat failed (exit {result.returncode}) concatenating {len(paragraphs)} "
                f"paragraph(s) from {cache_dir}:\n{result.stderr}"
            )
        success = True
        return out_path
    finally:
        list_path.unlink(missing_ok=True)
        if not success:
            out_path.unlink(missing_ok=True)


def _build_timing_map(paragraphs: Sequence[dict]) -> tuple[TranscriptSegment, ...]:
    """Build the cumulative per-paragraph timing map from manifest durations.

    Paragraph N's ``start_ms`` is the cumulative sum of all prior paragraphs'
    ``duration_seconds`` (converted to ms and rounded); its ``end_ms`` is that
    sum plus its own ``duration_seconds``. ``text`` is a synthetic label
    (the paragraph filename) since no real transcript text exists per
    paragraph at this layer.
    """
    segments: list[TranscriptSegment] = []
    cumulative_s = 0.0
    for para in paragraphs:
        duration_s = float(para["duration_seconds"])
        start_ms = round(cumulative_s * 1000)
        end_ms = round((cumulative_s + duration_s) * 1000)
        label = para.get("file") or f"para_{len(segments):03d}"
        segments.append(TranscriptSegment(start_ms=start_ms, end_ms=end_ms, text=label))
        cumulative_s += duration_s
    return tuple(segments)


def assemble_article_audio(item_id) -> AssembledArticle:
    """Assemble a complete per-paragraph article cache into one published artifact.

    Resolves the article's cache directory at CALL time
    (``wilted.AUDIO_DIR / str(item_id)``, INV-5), so tests that monkeypatch
    the live ``wilted.AUDIO_DIR`` attribute redirect this function's I/O.

    Steps:
        1. Load and validate the manifest (INV-4 completeness guard) —
           refuses without producing any output if the cache is incomplete.
        2. Concatenate the paragraph mp3s, in manifest order, via ffmpeg
           stream copy (``-c copy``, no re-encode).
        3. Publish the concatenated bytes into the content-addressed media
           store (:func:`wilted.station_runtime.media_store.publish_file`),
           which itself enforces INV-4 (refuses zero-byte input) and INV-5.
        4. Build the cumulative timing map from the manifest's per-paragraph
           ``duration_seconds`` (the exact timing map — no re-probing).

    Args:
        item_id: The article's item id (used to resolve its cache directory
            and passed through to :mod:`wilted.cache`'s manifest helpers).

    Returns:
        An :class:`AssembledArticle` describing the published artifact and
        its timing map.

    Raises:
        ArticleCacheIncompleteError: If the cache is not complete (see
            :func:`_require_complete_cache`). No output is produced.
        RuntimeError: If ffmpeg fails to concatenate the paragraphs.
        wilted.station_runtime.media_store.EmptyMediaError: Should never
            actually trigger here (the INV-4 guard above already refuses
            empty paragraphs before ffmpeg runs), but is not swallowed if
            ffmpeg somehow produces a zero-byte file despite exiting 0.
    """
    cache_dir, paragraphs = _require_complete_cache(item_id)

    concat_output = _concat_paragraphs(cache_dir, paragraphs)
    try:
        sha256 = media_store.publish_file(concat_output)
    finally:
        concat_output.unlink(missing_ok=True)

    published_path = media_store.path_for(sha256)
    if published_path is None:
        # publish_file os.replace's the blob to exactly the content-addressed
        # path path_for checks, so this is unreachable from this module's own
        # flow — but surface it as a real error (not a -O-strippable assert)
        # in case an external actor deletes the blob in the interim.
        raise RuntimeError(
            f"media_store.publish_file reported {sha256} but path_for returned None "
            "(published blob vanished immediately after publish)"
        )
    byte_size = published_path.stat().st_size

    segments = _build_timing_map(paragraphs)
    duration_ms = segments[-1].end_ms if segments else 0

    return AssembledArticle(
        sha256=sha256,
        byte_size=byte_size,
        duration_ms=duration_ms,
        segments=segments,
    )
