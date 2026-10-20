"""Shorten every pause in prepared audio to half a second.

One extra ffmpeg pass (``silencedetect``) finds the pauses, and the trim is
applied to the keep map, so the render, the cue remap and the saved-position
map all follow from the same intervals. Silence is never reported as an ad:
ad spans come from the ad-only keep map before trimming, and the silence the
final map drops is reported separately as ``silenceTrims``. Trimming is best
effort: any failure keeps the untrimmed map and reports an
``audio.silence.skipped`` warning record, so it never fails a preparation.
The warning goes through the worker's own progress channel, where the app
journals it, rather than Python logging, so stderr stays one JSON record per
line even where no log handler is installed.
"""
from __future__ import annotations

import math
import re
from bisect import bisect_right
from pathlib import Path

from . import cue_timing as _worker_cue_timing
from . import reporting as _worker_reporting
from .constants import (
    SILENCE_DETECT_MIN_S,
    SILENCE_DETECT_TIMEOUT_S,
    SILENCE_EDGE_TOLERANCE_S,
    SILENCE_KEPT_PAUSE_S,
    SILENCE_MAX_KEEP_INTERVALS,
    SILENCE_MIN_KEEP_S,
    SILENCE_MIN_TRIM_S,
    SILENCE_NOISE_FLOOR_DB,
)
from .cue_timing import KeepInterval, build_keep_map
from .reporting import WorkerError

_SILENCE_EVENT = re.compile(r"silence_(start|end):\s*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)")


def parse_silences(stderr: str, total_s: float) -> list[tuple[float, float]]:
    """Read ``silencedetect``'s report as ordered spans inside ``[0, total_s]``.

    A silence still open when the stream ends runs to ``total_s``.
    """
    spans: list[tuple[float, float]] = []
    start: float | None = None
    for kind, value in _SILENCE_EVENT.findall(stderr):
        seconds = float(value)
        if not math.isfinite(seconds):
            start = None
        elif kind == "start":
            start = max(0.0, seconds)
        elif start is not None:
            end = min(seconds, total_s)
            if end > start:
                spans.append((start, end))
            start = None
    if start is not None and start < total_s:
        spans.append((start, total_s))
    spans.sort()
    return spans


def detect_silences(audio_path: Path, total_s: float) -> list[tuple[float, float]]:
    """Find the source's silences in one bounded ffmpeg pass with a heartbeat."""
    command = ["ffmpeg", "-hide_banner", "-nostats", "-v", "info", "-i", str(audio_path), "-map", "0:a:0",
               "-af", f"silencedetect=noise={SILENCE_NOISE_FLOOR_DB}dB:d={SILENCE_DETECT_MIN_S}",
               "-f", "null", "-"]
    _worker_reporting.progress("audio.silence.detect", f"finding pauses longer than {SILENCE_KEPT_PAUSE_S:g}s")
    stderr = _worker_cue_timing._run_render_with_progress(
        command, timeout_s=SILENCE_DETECT_TIMEOUT_S, stage="audio.silence.detect.progress"
    )
    return parse_silences(stderr, total_s)


def _output_pauses(keeps: list[KeepInterval], silences) -> list[list[float]]:
    """Silences inside ``keeps``, on the output clock, with touching ones joined.

    The output clock is where an ad cut has already joined the audio either
    side of it, so a pause that straddles a cut is measured whole.
    """
    pauses: list[list[float]] = []
    first = 0
    for keep in keeps:
        while first < len(silences) and silences[first][1] <= keep.start_s:
            first += 1
        index = first
        while index < len(silences) and silences[index][0] < keep.end_s:
            low, high = max(silences[index][0], keep.start_s), min(silences[index][1], keep.end_s)
            index += 1
            if high <= low:
                continue
            start = keep.output_start_s + (low - keep.start_s)
            end = keep.output_start_s + (high - keep.start_s)
            if pauses and start - pauses[-1][1] <= SILENCE_EDGE_TOLERANCE_S:
                pauses[-1][1] = max(pauses[-1][1], end)
            else:
                pauses.append([start, end])
    return pauses


def plan_trims(keeps: list[KeepInterval], silences) -> list[KeepInterval]:
    """Shorten every pause in ``keeps`` longer than the kept pause to it.

    Pauses at the very start and end of the output are removed entirely.
    Each trimmed pause inside one kept interval splits it in two, so once the
    map would pass ``SILENCE_MAX_KEEP_INTERVALS`` the shorter pauses are left
    as they are. Returns ``keeps`` itself when there is nothing to trim.
    """
    if not keeps:
        return keeps
    total = keeps[-1].output_start_s + keeps[-1].duration_s
    half = SILENCE_KEPT_PAUSE_S / 2
    chosen: list[tuple[float, float]] = []
    interior: list[tuple[float, float]] = []
    for start, end in _output_pauses(keeps, silences):
        at_start, at_end = start <= SILENCE_EDGE_TOLERANCE_S, end >= total - SILENCE_EDGE_TOLERANCE_S
        if at_start or at_end:
            chosen.append((0.0 if at_start else start, total if at_end else end))
        elif end - start - SILENCE_KEPT_PAUSE_S >= SILENCE_MIN_TRIM_S:
            interior.append((start + half, end - half))
    starts = [keep.output_start_s for keep in keeps]
    budget = SILENCE_MAX_KEEP_INTERVALS - len(keeps)
    for start, end in sorted(interior, key=lambda removal: removal[1] - removal[0], reverse=True):
        # Only a removal inside a single kept interval adds one; a removal
        # across an ad cut shortens both sides instead.
        keep = keeps[bisect_right(starts, start) - 1]
        splits = int(start > keep.output_start_s and end < keep.output_start_s + keep.duration_s)
        if splits and splits > budget:
            continue
        budget -= splits
        chosen.append((start, end))
    if not chosen:
        return keeps
    chosen.sort()
    pieces: list[tuple[float, float]] = []
    first = 0
    for keep in keeps:
        output_end = keep.output_start_s + keep.duration_s
        while first < len(chosen) and chosen[first][1] <= keep.output_start_s:
            first += 1
        cursor = keep.start_s
        index = first
        while index < len(chosen) and chosen[index][0] < output_end:
            start, end = chosen[index]
            index += 1
            low = keep.start_s + (max(start, keep.output_start_s) - keep.output_start_s)
            high = keep.start_s + (min(end, output_end) - keep.output_start_s)
            if low > cursor:
                pieces.append((cursor, low))
            cursor = max(cursor, high)
        if keep.end_s > cursor:
            pieces.append((cursor, keep.end_s))
    return build_keep_map([(start, end) for start, end in pieces if end - start >= SILENCE_MIN_KEEP_S])


def _reason(error: Exception) -> str:
    """A failure's code or type, never its message: ffmpeg's stderr names local paths."""
    return error.code if isinstance(error, WorkerError) else type(error).__name__


def _skipped(reason: str) -> None:
    """Report that the untrimmed audio stands, and why."""
    _worker_reporting.progress("audio.silence.skipped", f"warning: silence not trimmed, {reason}")


def trimmed_keeps(audio_path: Path, keeps: list[KeepInterval]) -> list[KeepInterval]:
    """``keeps`` with long pauses shortened, or ``keeps`` itself when nothing is trimmed."""
    if not keeps:
        return keeps
    try:
        trimmed = plan_trims(keeps, detect_silences(audio_path, keeps[-1].end_s))
    except Exception as error:  # noqa: BLE001 - trimming is best effort and never fails a preparation
        _skipped(f"detection failed: {_reason(error)}")
        return keeps
    if trimmed is keeps:
        _worker_reporting.progress("audio.silence.none", f"no pause longer than {SILENCE_KEPT_PAUSE_S:g}s")
        return keeps
    if not trimmed:
        _skipped("trimming would leave no audio")
        return keeps
    removed = sum(keep.duration_s for keep in keeps) - sum(keep.duration_s for keep in trimmed)
    _worker_reporting.progress("audio.silence.trimmed", f"{removed:.1f}s of silence removed")
    return trimmed


def trim_unedited(audio_path: Path, output_path: Path | None,
                  total_s: float | None) -> tuple[Path, list[KeepInterval]]:
    """Trim long pauses from audio no ad cut touched.

    Returns ``(path, keeps)``: the rendered file and its keep map, or
    ``(audio_path, [])`` when nothing was trimmed, which callers already read
    as "timing unchanged". A container the cut path cannot write, or a render
    that fails, leaves the original in place.
    """
    try:
        if output_path is None or output_path.resolve() == audio_path.resolve():
            raise WorkerError("cut-output-alias", "no separate prepared output to write")
        _worker_cue_timing._render_codec_arguments(output_path)
        total = total_s if total_s is not None else _worker_cue_timing.probe_duration(audio_path)
        if not (total > 0 and math.isfinite(total)):
            raise WorkerError("cut-unsafe", "source duration is not finite and positive")
    except Exception as error:  # noqa: BLE001 - not applicable here; the original stands
        _worker_reporting.progress("audio.silence.skipped", _reason(error))
        return audio_path, []
    whole = build_keep_map([(0.0, total)])
    keeps = trimmed_keeps(audio_path, whole)
    if keeps is whole:
        return audio_path, []
    try:
        _worker_cue_timing.render_keep_segments(audio_path, output_path, keeps)
        if not output_path.is_file() or output_path.stat().st_size == 0:
            raise WorkerError("cut-output-empty", "ffmpeg produced no playable audio")
    except Exception as error:  # noqa: BLE001 - the untrimmed original is still a valid result
        _skipped(f"render failed: {_reason(error)}")
        return audio_path, []
    return output_path, keeps


def silence_trim_spans(serialized_keeps: list[dict], ad_spans: list[dict], total_s: float | None) -> list[dict]:
    """The spans the serialized keep map drops that are not ads.

    Computed from the same rounded numbers the result carries, so the ads,
    these spans and the kept intervals tile the original exactly for the app.
    """
    if not serialized_keeps:
        return []
    ads = sorted((ad["startSeconds"], ad["endSeconds"]) for ad in ad_spans)
    gaps: list[tuple[float, float]] = []
    cursor = 0.0
    for keep in serialized_keeps:
        if keep["startSeconds"] > cursor:
            gaps.append((cursor, keep["startSeconds"]))
        cursor = keep["endSeconds"]
    end = cursor if total_s is None else max(cursor, round(total_s, 3))
    if ads:
        end = max(end, ads[-1][1])
    if end > cursor:
        gaps.append((cursor, end))
    spans: list[tuple[float, float]] = []
    for gap_start, gap_end in gaps:
        cursor = gap_start
        for ad_start, ad_end in ads:
            if ad_end <= gap_start or ad_start >= gap_end:
                continue
            if ad_start > cursor:
                spans.append((cursor, ad_start))
            cursor = max(cursor, ad_end)
        if gap_end > cursor:
            spans.append((cursor, gap_end))
    return [{"startSeconds": round(start, 3), "endSeconds": round(end, 3)}
            for start, end in spans if end - start > 0.0005]
