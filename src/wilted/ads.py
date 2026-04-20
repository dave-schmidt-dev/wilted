"""Ad detection and removal for audio and article content.

Tasks 4.4-4.6: Sliding-window LLM-based ad detection in transcripts,
ffmpeg-based ad segment cutting, and article promotional content removal.

Usage:
    from wilted.ads import detect_ads, cut_ads, remove_promos

    # Detect ads in a podcast transcript
    ad_segments = detect_ads(segments, backend)

    # Cut detected ads from an audio file
    cut_ads(audio_path, ad_segments, output_path)

    # Remove promotional paragraphs from article text
    cleaned = remove_promos(article_text, backend)
"""

from __future__ import annotations

import logging
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from wilted.cache import check_ffmpeg
from wilted.llm import LLMBackend, parse_json_response

logger = logging.getLogger(__name__)

# Import TranscriptSegment from transcribe.py when available;
# fall back to local definition during parallel development.
try:
    from wilted.transcribe import TranscriptSegment
except ImportError:
    from dataclasses import dataclass as _dc

    @_dc
    class TranscriptSegment:  # type: ignore[no-redef]
        """Temporary local definition until transcribe.py is merged."""

        start_s: float
        end_s: float
        text: str


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class AdSegment:
    """A detected advertisement segment in an audio transcript."""

    start_s: float
    end_s: float
    confidence: float
    label: str  # "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"


# ---------------------------------------------------------------------------
# Ad detection prompts
# ---------------------------------------------------------------------------

_AD_DETECT_SYSTEM_PROMPT = """\
You are an ad detection system. Analyze the transcript and identify advertisement segments.
Return a JSON array of ad segments. Each segment has: start_s (float), end_s (float), \
confidence (0.0-1.0), label (one of: "sponsor_read", "self_promo", "ad_break", "newsletter_pitch").
If no ads found, return an empty array []."""

_PROMO_DETECT_SYSTEM_PROMPT = """\
You are a content filter. Identify promotional paragraphs in this article.
Promotional content includes: newsletter signup pitches, "related articles" sections, \
author bio/social media plugs, affiliate disclaimers, and "subscribe for more" calls to action.
Return a JSON object: {"promo_indices": [0, 5, 12]} listing the 0-based paragraph indices \
that are promotional. If none, return {"promo_indices": []}."""

_VALID_LABELS = {"sponsor_read", "self_promo", "ad_break", "newsletter_pitch"}


# ---------------------------------------------------------------------------
# Helpers — chunking
# ---------------------------------------------------------------------------


def _chunk_segments(
    segments: list[TranscriptSegment],
    chunk_minutes: float,
    overlap_minutes: float,
) -> list[list[TranscriptSegment]]:
    """Split transcript segments into overlapping time-based chunks.

    Args:
        segments: Ordered list of transcript segments.
        chunk_minutes: Duration of each chunk window in minutes.
        overlap_minutes: Overlap between consecutive windows in minutes.

    Returns:
        List of segment groups, one per chunk window.
    """
    if not segments:
        return []

    chunk_s = chunk_minutes * 60.0
    overlap_s = overlap_minutes * 60.0
    step_s = chunk_s - overlap_s

    if step_s <= 0:
        raise ValueError("chunk_minutes must be greater than overlap_minutes")

    # Determine total time span
    total_end = max(seg.end_s for seg in segments)

    chunks: list[list[TranscriptSegment]] = []
    window_start = 0.0

    while window_start < total_end:
        window_end = window_start + chunk_s
        # Collect all segments that overlap this window
        chunk = [seg for seg in segments if seg.end_s > window_start and seg.start_s < window_end]
        if chunk:
            chunks.append(chunk)
        window_start += step_s

    return chunks


# ---------------------------------------------------------------------------
# Ad detection — sliding window
# ---------------------------------------------------------------------------


def detect_ads(
    segments: list[TranscriptSegment],
    backend: LLMBackend,
    chunk_minutes: float = 10.0,
    overlap_minutes: float = 2.0,
    confidence_threshold: float = 0.8,
) -> list[AdSegment]:
    """Detect advertisements in a transcript using LLM-based sliding window analysis.

    Args:
        segments: Ordered transcript segments with timing info.
        backend: A loaded LLM backend for inference.
        chunk_minutes: Size of each analysis window in minutes.
        overlap_minutes: Overlap between consecutive windows.
        confidence_threshold: Minimum confidence to keep a detection.

    Returns:
        Sorted list of AdSegment detections, merged and filtered.
    """
    if not segments:
        return []

    chunks = _chunk_segments(segments, chunk_minutes, overlap_minutes)
    if not chunks:
        return []

    # Collect raw detections from each chunk
    raw_detections: list[list[AdSegment]] = []

    for i, chunk in enumerate(chunks):
        transcript_text = "\n".join(f"[{seg.start_s:.1f}s - {seg.end_s:.1f}s] {seg.text}" for seg in chunk)

        try:
            response, _tokens = backend.generate(_AD_DETECT_SYSTEM_PROMPT, transcript_text)
            parsed = parse_json_response(response)
        except Exception:
            logger.exception("Ad detection failed for chunk %d", i)
            raw_detections.append([])
            continue

        # Parse the array of ad segments
        if not isinstance(parsed, list):
            # Tolerate {"ads": [...]} wrapper
            if isinstance(parsed, dict) and "ads" in parsed:
                parsed = parsed["ads"]
            else:
                logger.warning("Chunk %d: expected array, got %s", i, type(parsed).__name__)
                raw_detections.append([])
                continue

        chunk_ads: list[AdSegment] = []
        for item in parsed:
            if not isinstance(item, dict):
                continue
            try:
                label = str(item.get("label", "ad_break"))
                if label not in _VALID_LABELS:
                    label = "ad_break"
                chunk_ads.append(
                    AdSegment(
                        start_s=float(item["start_s"]),
                        end_s=float(item["end_s"]),
                        confidence=float(item.get("confidence", 0.5)),
                        label=label,
                    )
                )
            except (KeyError, TypeError, ValueError) as exc:
                logger.warning("Skipping malformed ad segment in chunk %d: %s", i, exc)

        raw_detections.append(chunk_ads)
        logger.debug("Chunk %d: detected %d ad segments", i, len(chunk_ads))

    # Resolve overlaps via majority vote, then filter and merge
    resolved = _resolve_overlaps(raw_detections, chunks, chunk_minutes, overlap_minutes)
    filtered = [ad for ad in resolved if ad.confidence >= confidence_threshold]
    merged = _merge_adjacent(filtered)
    return merged


def _resolve_overlaps(
    raw_detections: list[list[AdSegment]],
    chunks: list[list[TranscriptSegment]],
    chunk_minutes: float,
    overlap_minutes: float,
) -> list[AdSegment]:
    """Resolve detections in overlap zones via majority vote.

    For each second in an overlap zone, count how many chunks flagged it
    as an ad. If >50% flagged it, keep the detection.

    Args:
        raw_detections: Per-chunk ad detection results.
        chunks: The chunk windows (used to determine boundaries).
        chunk_minutes: Chunk window size in minutes.
        overlap_minutes: Overlap size in minutes.

    Returns:
        De-duplicated list of AdSegment.
    """
    if not raw_detections:
        return []

    chunk_s = chunk_minutes * 60.0
    overlap_s = overlap_minutes * 60.0
    step_s = chunk_s - overlap_s

    # Determine total time span
    total_end = 0.0
    for chunk in chunks:
        if chunk:
            total_end = max(total_end, max(seg.end_s for seg in chunk))

    if total_end <= 0:
        return []

    # Build per-second ad vote map: second -> list of (chunk_idx, is_ad, confidence, label)
    n_seconds = int(total_end) + 2
    ad_votes: list[list[tuple[float, str]]] = [[] for _ in range(n_seconds)]

    for chunk_idx, detections in enumerate(raw_detections):
        for det in detections:
            start_sec = max(0, int(det.start_s))
            end_sec = min(n_seconds - 1, int(det.end_s) + 1)
            for s in range(start_sec, end_sec):
                ad_votes[s].append((det.confidence, det.label))

    # For non-overlap zones, any detection passes through.
    # For overlap zones (covered by >1 chunk), require majority.
    chunk_coverage: list[int] = [0] * n_seconds
    for chunk_idx in range(len(chunks)):
        ws = int(chunk_idx * step_s)
        we = min(n_seconds, int(ws + chunk_s) + 1)
        for s in range(max(0, ws), we):
            chunk_coverage[s] += 1

    # Determine which seconds are "ad" after voting
    is_ad_second: list[bool] = [False] * n_seconds
    second_confidence: list[float] = [0.0] * n_seconds
    second_label: list[str] = ["ad_break"] * n_seconds

    for s in range(n_seconds):
        if not ad_votes[s]:
            continue
        coverage = max(1, chunk_coverage[s])
        vote_count = len(ad_votes[s])
        if vote_count / coverage > 0.5:
            is_ad_second[s] = True
            # Use max confidence and most common label
            second_confidence[s] = max(c for c, _l in ad_votes[s])
            labels = [lbl for _c, lbl in ad_votes[s]]
            second_label[s] = max(set(labels), key=labels.count)

    # Convert second-level flags back to AdSegment ranges
    result: list[AdSegment] = []
    i = 0
    while i < n_seconds:
        if is_ad_second[i]:
            start = i
            confidences: list[float] = []
            labels: list[str] = []
            while i < n_seconds and is_ad_second[i]:
                confidences.append(second_confidence[i])
                labels.append(second_label[i])
                i += 1
            end = i
            avg_conf = sum(confidences) / len(confidences)
            dominant_label = max(set(labels), key=labels.count)
            result.append(
                AdSegment(
                    start_s=float(start),
                    end_s=float(end),
                    confidence=avg_conf,
                    label=dominant_label,
                )
            )
        else:
            i += 1

    return result


def _merge_adjacent(segments: list[AdSegment], gap_threshold: float = 2.0) -> list[AdSegment]:
    """Merge adjacent or overlapping ad segments.

    Args:
        segments: Sorted list of ad segments.
        gap_threshold: Maximum gap in seconds between segments to merge.

    Returns:
        Merged list of AdSegment, sorted by start time.
    """
    if not segments:
        return []

    sorted_segs = sorted(segments, key=lambda s: s.start_s)
    merged: list[AdSegment] = [sorted_segs[0]]

    for seg in sorted_segs[1:]:
        prev = merged[-1]
        if seg.start_s <= prev.end_s + gap_threshold:
            # Merge: extend end, average confidence, keep dominant label
            labels = [prev.label, seg.label]
            merged[-1] = AdSegment(
                start_s=prev.start_s,
                end_s=max(prev.end_s, seg.end_s),
                confidence=(prev.confidence + seg.confidence) / 2.0,
                label=max(set(labels), key=labels.count),
            )
        else:
            merged.append(seg)

    return merged


# ---------------------------------------------------------------------------
# Audio ad cutting with ffmpeg
# ---------------------------------------------------------------------------


def _compute_keep_segments(
    total_duration: float,
    ad_segments: list[AdSegment],
    buffer_s: float,
) -> list[tuple[float, float]]:
    """Compute content segments to keep (inverse of ad segments).

    Args:
        total_duration: Total audio duration in seconds.
        ad_segments: Sorted list of ad segments to remove.
        buffer_s: Padding in seconds around cuts for smooth transitions.

    Returns:
        List of (start, end) tuples representing content to keep,
        clamped to [0, total_duration].
    """
    if not ad_segments:
        return [(0.0, total_duration)]

    sorted_ads = sorted(ad_segments, key=lambda s: s.start_s)
    keeps: list[tuple[float, float]] = []
    current_start = 0.0

    for ad in sorted_ads:
        ad_start = max(0.0, ad.start_s - buffer_s)
        ad_end = min(total_duration, ad.end_s + buffer_s)

        if current_start < ad_start:
            keeps.append((current_start, ad_start))
        current_start = max(current_start, ad_end)

    # Keep content after last ad
    if current_start < total_duration:
        keeps.append((current_start, total_duration))

    return keeps


def cut_ads(
    audio_path: Path,
    ad_segments: list[AdSegment],
    output_path: Path,
    buffer_seconds: float = 0.5,
) -> Path:
    """Cut detected ad segments from an audio file using ffmpeg.

    Args:
        audio_path: Path to the input audio file.
        ad_segments: List of ad segments to remove.
        output_path: Path for the output audio file.
        buffer_seconds: Padding around cuts for smooth transitions.

    Returns:
        The output_path.

    Raises:
        RuntimeError: If ffmpeg is not available.
        FileNotFoundError: If audio_path does not exist.
        subprocess.CalledProcessError: If ffmpeg fails.
    """
    check_ffmpeg()

    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    # No ads to cut — copy the file directly
    if not ad_segments:
        shutil.copy2(audio_path, output_path)
        logger.info("No ads to cut, copied %s to %s", audio_path, output_path)
        return output_path

    # Get total duration via ffprobe
    probe_result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(audio_path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    total_duration = float(probe_result.stdout.strip())

    keep_segments = _compute_keep_segments(total_duration, ad_segments, buffer_seconds)

    if not keep_segments:
        logger.warning("All content marked as ads, creating empty output")
        output_path.touch()
        return output_path

    tmpdir = None
    try:
        tmpdir = tempfile.mkdtemp(prefix="wilted_adcut_")
        tmp = Path(tmpdir)
        segment_files: list[Path] = []

        # Extract each keep-segment
        for i, (start, end) in enumerate(keep_segments):
            duration = end - start
            if duration <= 0:
                continue
            seg_path = tmp / f"segment_{i:03d}.mp3"
            subprocess.run(
                [
                    "ffmpeg",
                    "-i",
                    str(audio_path),
                    "-ss",
                    str(start),
                    "-t",
                    str(duration),
                    "-c:a",
                    "copy",
                    "-avoid_negative_ts",
                    "make_zero",
                    str(seg_path),
                ],
                capture_output=True,
                check=True,
            )
            segment_files.append(seg_path)

        if not segment_files:
            output_path.touch()
            return output_path

        # If only one segment, just move it
        if len(segment_files) == 1:
            shutil.move(str(segment_files[0]), str(output_path))
            return output_path

        # Create concat demuxer file
        concat_path = tmp / "concat_list.txt"
        with open(concat_path, "w") as f:
            for seg_path in segment_files:
                f.write(f"file '{seg_path}'\n")

        # Concatenate
        subprocess.run(
            [
                "ffmpeg",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(concat_path),
                "-c:a",
                "copy",
                str(output_path),
            ],
            capture_output=True,
            check=True,
        )

        logger.info(
            "Cut %d ad segments, kept %d segments -> %s",
            len(ad_segments),
            len(keep_segments),
            output_path,
        )
        return output_path

    finally:
        # Clean up temp files
        if tmpdir is not None:
            shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Article promotional content removal
# ---------------------------------------------------------------------------


def remove_promos(text: str, backend: LLMBackend) -> str:
    """Remove promotional paragraphs from article text.

    Args:
        text: Full article text with paragraph breaks.
        backend: A loaded LLM backend for inference.

    Returns:
        Cleaned text with promotional paragraphs removed.
    """
    if not text.strip():
        return ""

    paragraphs = [p for p in text.split("\n\n") if p.strip()]
    if not paragraphs:
        return ""

    # Build numbered paragraph list for LLM
    numbered = "\n\n".join(f"[{i}] {para}" for i, para in enumerate(paragraphs))

    try:
        response, _tokens = backend.generate(_PROMO_DETECT_SYSTEM_PROMPT, numbered)
        parsed = parse_json_response(response)
    except Exception:
        logger.exception("Promo detection failed, returning original text")
        return text

    if not isinstance(parsed, dict):
        logger.warning("Expected JSON object, got %s", type(parsed).__name__)
        return text

    promo_indices = parsed.get("promo_indices", [])
    if not isinstance(promo_indices, list):
        logger.warning("promo_indices is not a list: %s", type(promo_indices).__name__)
        return text

    # Validate indices
    valid_indices = set()
    for idx in promo_indices:
        try:
            idx_int = int(idx)
            if 0 <= idx_int < len(paragraphs):
                valid_indices.add(idx_int)
        except (TypeError, ValueError):
            logger.warning("Skipping invalid promo index: %s", idx)

    if not valid_indices:
        return text

    # Remove promotional paragraphs
    kept = [para for i, para in enumerate(paragraphs) if i not in valid_indices]
    result = "\n\n".join(kept)

    logger.info(
        "Removed %d promotional paragraphs out of %d",
        len(valid_indices),
        len(paragraphs),
    )
    return result


def remove_promos_batch(
    items: list[tuple[int, str]],
    backend: LLMBackend,
) -> dict[int, str]:
    """Remove promotional content from multiple articles.

    Args:
        items: List of (item_id, article_text) tuples.
        backend: A loaded LLM backend (already loaded, shared across calls).

    Returns:
        Dict mapping item_id to cleaned text.
    """
    results: dict[int, str] = {}

    for item_id, text in items:
        try:
            results[item_id] = remove_promos(text, backend)
        except Exception:
            logger.exception("Promo removal failed for item %d", item_id)
            results[item_id] = text  # Fall back to original text

    return results
