"""Speech-to-text refill for silent decoder holes.

parakeet-tdt-0.6b-v3, run by the speech-stack daemon in 120 s chunks with 15 s
overlap, sometimes emits no tokens for 40-55 s of clear speech inside one chunk.
Re-decoding the same audio in a short window placed over the hole recovers it.
This module identifies token gaps, plans padded transcription windows, and
refills missing segments into the aligned transcript.
"""
from __future__ import annotations

import dataclasses
import logging
import math
import re
import subprocess
import tempfile
from pathlib import Path

from . import reporting as _worker_reporting
from .cue_timing import in_time_order

try:
    from wilted.transcribe import TranscriptionError
except ImportError:
    class TranscriptionError(Exception):
        """Fallback transcription error when wilted.transcribe is unavailable."""

logger = logging.getLogger(__name__)

HOLE_MINIMUM_S = 8.0
LONGEST_TOKEN_S = 1.2
CONTEXT_S = 3.0
WINDOW_MAXIMUM_S = 60.0
# The re-decoded window hears the words either side of a hole too, timed a few
# hundred milliseconds differently, so one can land just inside the hole. A
# recovered word this close to an edge that repeats the word across it is dropped.
EDGE_REPEAT_S = 1.5
SHORT_OPENING_LIMIT_S = 300.0
SHORT_OPENING_GAP_MINIMUM_S = 2.0
SHORT_OPENING_GAP_MAXIMUM_S = 12.0
SHORT_OPENING_MAX_WINDOWS = 8


def find_holes(
    segments,
    duration_s: float,
    minimum_s: float = HOLE_MINIMUM_S,
) -> list[tuple[float, float]]:
    """Identify stretches of at least ``minimum_s`` with no transcript tokens.

    Searches for empty stretches before the first token, between tokens, and
    after the last token. Each token's end is capped at ``start + LONGEST_TOKEN_S``
    to counteract aligner stretching over pauses. A segment with ``tokens is None``
    counts as a single occupied span from its ``start_s`` to ``end_s``.

    Args:
        segments: Iterable of transcript segments.
        duration_s: Total audio duration in seconds.
        minimum_s: Minimum gap duration in seconds to classify as a hole.

    Returns:
        List of ``(start, end)`` hole coordinates in seconds.
    """
    duration = float(duration_s)
    if duration <= 0.0:
        return []

    spans: list[tuple[float, float]] = []
    for segment in segments or ():
        tokens = getattr(segment, "tokens", None)
        if tokens:
            for token in tokens:
                tok_start = float(token.start_s)
                tok_end = max(tok_start, min(float(token.end_s), tok_start + LONGEST_TOKEN_S))
                spans.append((tok_start, tok_end))
        else:
            seg_start = float(segment.start_s)
            seg_end = max(seg_start, float(segment.end_s))
            spans.append((seg_start, seg_end))

    merged_spans: list[tuple[float, float]] = []
    for start, end in sorted(spans, key=lambda s: (s[0], s[1])):
        if not merged_spans:
            merged_spans.append((start, end))
        else:
            prev_start, prev_end = merged_spans[-1]
            if start <= prev_end:
                merged_spans[-1] = (prev_start, max(prev_end, end))
            else:
                merged_spans.append((start, end))

    holes: list[tuple[float, float]] = []
    cursor = 0.0
    for span_start, span_end in merged_spans:
        gap_start = max(0.0, cursor)
        gap_end = min(duration, span_start)
        if gap_end - gap_start >= minimum_s:
            holes.append((gap_start, gap_end))
        cursor = max(cursor, span_end)

    gap_start = max(0.0, cursor)
    gap_end = duration
    if gap_end - gap_start >= minimum_s:
        holes.append((gap_start, gap_end))

    return holes


def refill_windows(
    holes: list[tuple[float, float]],
    duration_s: float,
) -> list[tuple[float, float]]:
    """Calculate transcription windows with context padding and size limits.

    Pads each hole by ``CONTEXT_S`` on either side, clamped to ``[0, duration_s]``.
    Windows that overlap or sit within ``CONTEXT_S`` of each other are merged.
    Any window longer than ``WINDOW_MAXIMUM_S`` is split into equal parts no
    longer than that limit.

    Args:
        holes: List of ``(start, end)`` hole coordinates.
        duration_s: Audio duration in seconds.

    Returns:
        List of ``(start, end)`` window coordinates in seconds.
    """
    duration = float(duration_s)
    if not holes or duration <= 0.0:
        return []

    padded: list[tuple[float, float]] = []
    for h_start, h_end in holes:
        w_start = max(0.0, float(h_start) - CONTEXT_S)
        w_end = min(duration, float(h_end) + CONTEXT_S)
        if w_end > w_start:
            padded.append((w_start, w_end))

    merged: list[tuple[float, float]] = []
    for start, end in sorted(padded, key=lambda w: (w[0], w[1])):
        if not merged:
            merged.append((start, end))
        else:
            prev_start, prev_end = merged[-1]
            if start <= prev_end + CONTEXT_S:
                merged[-1] = (prev_start, max(prev_end, end))
            else:
                merged.append((start, end))

    windows: list[tuple[float, float]] = []
    for start, end in merged:
        window_length = end - start
        if window_length <= WINDOW_MAXIMUM_S:
            windows.append((start, end))
        else:
            parts = math.ceil(window_length / WINDOW_MAXIMUM_S)
            part_len = window_length / parts
            for i in range(parts):
                part_start = start + i * part_len
                part_end = end if i == parts - 1 else start + (i + 1) * part_len
                windows.append((part_start, part_end))

    return windows


def _words(tokens) -> list[list]:
    """Group tokens into words: a token whose text starts with whitespace starts a new word."""
    words: list[list] = []
    for token in tokens:
        if not words or token.text[:1].isspace():
            words.append([token])
        else:
            words[-1].append(token)
    return words


def _word_key(word) -> str:
    """A word reduced to lowercase letters and digits."""
    return re.sub(r"[^a-z0-9]", "", "".join(token.text for token in word).lower())


def _hole_neighbours(segments, holes) -> list[tuple[str | None, str | None]]:
    """For each hole, the word just before it and the word just after it."""
    words = sorted(
        (word for segment in segments for word in _words(getattr(segment, "tokens", None) or ())),
        key=lambda word: float(word[0].start_s),
    )
    neighbours = []
    for start, end in holes:
        before = [word for word in words if float(word[0].start_s) < start]
        after = [word for word in words if float(word[0].start_s) >= end]
        neighbours.append((_word_key(before[-1]) if before else None, _word_key(after[0]) if after else None))
    return neighbours


def _drop_edge_repeats(tokens, holes, neighbours) -> list:
    """Drop recovered words that repeat the original word across a hole's edge."""
    kept = []
    for word in _words(tokens):
        start = float(word[0].start_s)
        key = _word_key(word)
        repeat = any(
            hole_start <= start < hole_end
            and (
                (key == before and start - hole_start < EDGE_REPEAT_S)
                or (key == after and hole_end - start < EDGE_REPEAT_S)
            )
            for (hole_start, hole_end), (before, after) in zip(holes, neighbours)
        )
        if not repeat:
            kept.extend(word)
    return kept


def find_short_opening_gaps(
    segments,
    duration_s: float,
    *,
    opening_limit_s: float = SHORT_OPENING_LIMIT_S,
) -> list[tuple[float, float]]:
    """Find bounded internal lexical gaps near the start of an audio source.

    Punctuation-only tokens do not count as speech coverage. Only valid timed
    lexical tokens can bound a gap; leading and trailing silence are excluded.
    Token spans are capped like the existing long-hole detector so a stretched
    alignment does not conceal missing speech.
    """
    try:
        duration = float(duration_s)
        opening_limit = min(float(opening_limit_s), duration)
    except (TypeError, ValueError, OverflowError):
        return []
    if not math.isfinite(duration) or not math.isfinite(opening_limit) or duration <= 0 or opening_limit <= 0:
        return []

    spans: list[tuple[float, float]] = []
    for segment in segments or ():
        for token in getattr(segment, "tokens", None) or ():
            if not any(character.isalnum() for character in str(getattr(token, "text", ""))):
                continue
            try:
                start = float(token.start_s)
                end = float(token.end_s)
            except (AttributeError, TypeError, ValueError, OverflowError):
                continue
            if (
                not math.isfinite(start)
                or not math.isfinite(end)
                or start < 0.0
                or end <= start
                or end > duration
                or start >= opening_limit
            ):
                continue
            spans.append((start, min(end, start + LONGEST_TOKEN_S)))

    if len(spans) < 2:
        return []
    merged: list[tuple[float, float]] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))

    gaps = []
    for (_, previous_end), (next_start, _) in zip(merged, merged[1:]):
        gap_start = max(0.0, previous_end)
        gap_end = min(opening_limit, next_start)
        gap_length = gap_end - gap_start
        within_minimum = gap_length >= SHORT_OPENING_GAP_MINIMUM_S or math.isclose(
            gap_length, SHORT_OPENING_GAP_MINIMUM_S, abs_tol=1e-9
        )
        within_maximum = gap_length <= SHORT_OPENING_GAP_MAXIMUM_S or math.isclose(
            gap_length, SHORT_OPENING_GAP_MAXIMUM_S, abs_tol=1e-9
        )
        if within_minimum and within_maximum:
            gaps.append((gap_start, gap_end))
            if len(gaps) >= SHORT_OPENING_MAX_WINDOWS:
                break
    return gaps


def refill_short_opening_gaps(
    audio_path: Path | str,
    segments,
    duration_s: float,
    transcribe_window,
) -> list:
    """Decode exact short lexical gaps within the first five minutes.

    Each source gap is one unpadded, unmerged decode window. Only returned
    tokens with valid timings inside that gap are added. Missing audio,
    failed decodes, empty output, and invalid timestamps leave the transcript
    unchanged. Work is bounded to eight windows per source.
    """
    original = list(segments or ())
    gaps = find_short_opening_gaps(original, duration_s)
    if not gaps:
        return original

    neighbours = _hole_neighbours(original, gaps)
    recovered_segments = []
    total_windows = len(gaps)
    for index, (gap_start, gap_end) in enumerate(gaps, 1):
        _worker_reporting.progress(
            "transcript.stt.short-opening-refill",
            f"{index}/{total_windows} {gap_start:.2f}-{gap_end:.2f}s",
        )
        try:
            with tempfile.TemporaryDirectory(prefix="wilted-stt-opening-refill-") as tmp_dir:
                wav_path = Path(tmp_dir) / "window.wav"
                cmd = [
                    "ffmpeg", "-nostdin", "-v", "error",
                    "-ss", str(gap_start), "-to", str(gap_end), "-i", str(audio_path),
                    "-ac", "1", "-ar", "16000", str(wav_path),
                ]
                subprocess.run(cmd, check=True, capture_output=True, timeout=30)
                window_segments = transcribe_window(wav_path)
        except (subprocess.SubprocessError, OSError, TranscriptionError) as error:
            logger.warning("Short opening STT refill window %.2f-%.2fs failed: %s", gap_start, gap_end, error)
            _worker_reporting.progress(
                "transcript.stt.short-opening-refill.failed",
                f"{gap_start:.2f}-{gap_end:.2f}s: {error}",
            )
            continue

        for segment in window_segments or ():
            kept_tokens = []
            for token in getattr(segment, "tokens", None) or ():
                try:
                    relative_start = float(token.start_s)
                    relative_end = float(token.end_s)
                except (AttributeError, TypeError, ValueError, OverflowError):
                    continue
                if (
                    not math.isfinite(relative_start)
                    or not math.isfinite(relative_end)
                    or relative_start < 0.0
                    or relative_end <= relative_start
                    or relative_end > gap_end - gap_start
                    or not any(character.isalnum() for character in str(getattr(token, "text", "")))
                ):
                    continue
                absolute_start = relative_start + gap_start
                absolute_end = relative_end + gap_start
                if gap_start <= absolute_start < gap_end and absolute_end <= gap_end:
                    kept_tokens.append(dataclasses.replace(token, start_s=absolute_start, end_s=absolute_end))

            kept_tokens = _drop_edge_repeats(kept_tokens, [(gap_start, gap_end)], [neighbours[index - 1]])
            if not kept_tokens:
                continue
            kept_tokens.sort(key=lambda token: (float(token.start_s), float(token.end_s)))
            rebuilt = dataclasses.replace(
                segment,
                start_s=float(kept_tokens[0].start_s),
                end_s=float(kept_tokens[-1].end_s),
                text="".join(token.text for token in kept_tokens).strip(),
                tokens=tuple(kept_tokens),
            )
            recovered_segments.append(rebuilt)

    _worker_reporting.progress(
        "transcript.stt.short-opening-refill.complete",
        f"{len(recovered_segments)} segments in {total_windows} windows",
    )
    return in_time_order(original + recovered_segments)


def refill_holes(
    audio_path: Path | str,
    segments,
    duration_s: float,
    transcribe_window,
) -> list:
    """Refill speech-to-text gaps by transcribing short windows over holes.

    For each window, cuts audio to a 16 kHz mono WAV, calls ``transcribe_window``,
    shifts timestamps to absolute coordinates, filters tokens to keep only those
    strictly inside the original holes, and rebuilds kept segments.

    Args:
        audio_path: Path to the input audio file.
        segments: Existing transcript segments.
        duration_s: Audio duration in seconds.
        transcribe_window: Callable taking a WAV path and returning segments
            with window-relative timing.

    Returns:
        Original and recovered segments combined in time order.
    """
    duration = float(duration_s)
    holes = find_holes(segments, duration)
    if not holes:
        return list(segments)

    windows = refill_windows(holes, duration)
    if not windows:
        return list(segments)

    total_windows = len(windows)
    neighbours = _hole_neighbours(segments, holes)
    recovered_segments = []

    for idx, (w_start, w_end) in enumerate(windows, 1):
        _worker_reporting.progress("transcript.stt.refill", f"{idx}/{total_windows} {w_start:.0f}-{w_end:.0f}s")
        try:
            with tempfile.TemporaryDirectory(prefix="wilted-stt-refill-") as tmp_dir:
                wav_path = Path(tmp_dir) / "window.wav"
                cmd = [
                    "ffmpeg",
                    "-nostdin",
                    "-v", "error",
                    "-ss", str(w_start),
                    "-to", str(w_end),
                    "-i", str(audio_path),
                    "-ac", "1",
                    "-ar", "16000",
                    str(wav_path),
                ]
                subprocess.run(cmd, check=True, capture_output=True)
                window_segments = transcribe_window(wav_path)
        except (subprocess.SubprocessError, OSError, TranscriptionError) as error:
            logger.warning("STT refill window %.1f-%.1fs failed: %s", w_start, w_end, error)
            _worker_reporting.progress("transcript.stt.refill.failed", f"{w_start:.0f}-{w_end:.0f}s: {error}")
            continue

        if not window_segments:
            continue

        for seg in window_segments:
            tokens = getattr(seg, "tokens", None)
            if not tokens:
                continue

            kept_tokens = []
            for tok in tokens:
                abs_start = float(tok.start_s) + w_start
                abs_end = float(tok.end_s) + w_start
                if any(h_start < abs_start < h_end for h_start, h_end in holes):
                    shifted_tok = dataclasses.replace(tok, start_s=abs_start, end_s=abs_end)
                    kept_tokens.append(shifted_tok)

            kept_tokens = _drop_edge_repeats(kept_tokens, holes, neighbours)
            if not kept_tokens:
                continue

            new_start = kept_tokens[0].start_s
            new_end = kept_tokens[-1].end_s
            new_text = "".join(t.text for t in kept_tokens).strip()
            rebuilt_seg = dataclasses.replace(
                seg,
                start_s=new_start,
                end_s=new_end,
                text=new_text,
                tokens=tuple(kept_tokens),
            )
            recovered_segments.append(rebuilt_seg)

    _worker_reporting.progress(
        "transcript.stt.refill.complete",
        f"{len(recovered_segments)} segments in {total_windows} windows",
    )
    return in_time_order(list(segments) + recovered_segments)
