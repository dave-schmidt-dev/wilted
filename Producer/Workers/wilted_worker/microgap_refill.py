"""Source-grounded recovery for short gaps between opening transcript cues."""
from __future__ import annotations

import logging
import math
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import reporting as _worker_reporting
from .cue_timing import in_time_order, join_split_words
from .constants import SPLIT_WORD_CONTIGUITY_TOLERANCE_S
from .microgap_reconcile import (
    MICROGAP_ALIGNMENT_FRAME_S,
    InterCueGap,
    _lexical,
    apply_decisions,
    reconcile_gap,
    words_from_segments,
)

try:
    from wilted.transcribe import TranscriptionError
except ImportError:
    class TranscriptionError(Exception):
        """Fallback transcription error when wilted.transcribe is unavailable."""

logger = logging.getLogger(__name__)

MICROGAP_OPENING_LIMIT_S = 300.0
MICROGAP_MAXIMUM_S = 2.0
MICROGAP_CONTEXT_S = 3.0
MICROGAP_WINDOW_MAXIMUM_S = 30.0
MICROGAP_MAX_WINDOWS = 8


@dataclass(frozen=True)
class ContextWindow:
    """One padded decode window and the original gaps it covers."""

    start_s: float
    end_s: float
    gap_indexes: tuple[int, ...]


def find_intercue_microgaps(
    segments,
    duration_s: float,
    *,
    opening_limit_s: float = MICROGAP_OPENING_LIMIT_S,
) -> list[InterCueGap]:
    """Find positive gaps under two seconds between lexical cues near the opening.

    Punctuation-only cues do not act as lexical anchors. A malformed lexical
    cue inside the scan window stops pairing across the unknown timing.
    """
    try:
        duration = float(duration_s)
        opening_limit = min(float(opening_limit_s), duration)
    except (TypeError, ValueError, OverflowError):
        return []
    if not math.isfinite(duration) or not math.isfinite(opening_limit) or duration <= 0 or opening_limit <= 0:
        return []

    lexical_cues = []
    for index, segment in enumerate(segments or ()):
        text = getattr(segment, "text", "")
        if not _lexical(text):
            continue
        try:
            start, end = float(segment.start_s), float(segment.end_s)
        except (AttributeError, TypeError, ValueError, OverflowError):
            return []
        if start >= opening_limit:
            break
        if not (
            math.isfinite(start)
            and math.isfinite(end)
            and 0.0 <= start < end <= duration
        ):
            return []
        lexical_cues.append((start, end, index))

    # Preserve owner order; sorting could manufacture adjacency.
    gaps: list[InterCueGap] = []
    previous: tuple[float, float, int] | None = None
    for start, end, index in lexical_cues:
        if previous is not None:
            if start < previous[0]:
                previous = (start, end, index)
                continue
            gap_start = previous[1]
            gap_end = start
            gap_width = gap_end - gap_start
            if SPLIT_WORD_CONTIGUITY_TOLERANCE_S < gap_width < MICROGAP_MAXIMUM_S:
                gaps.append(InterCueGap(gap_start, gap_end, previous[2], index))
        previous = (start, end, index)
    return gaps


def plan_microgap_windows(
    gaps: list[InterCueGap],
    duration_s: float,
    segments,
) -> tuple[list[ContextWindow], int, int]:
    """Include complete adjacent cues, pad gaps, merge, and cap the windows."""
    try:
        duration = float(duration_s)
    except (TypeError, ValueError, OverflowError):
        return [], len(gaps), 0
    if not math.isfinite(duration) or duration <= 0.0:
        return [], len(gaps), 0

    windows: list[ContextWindow] = []
    skipped_gap_indexes: set[int] = set()
    for gap_index, gap in enumerate(gaps):
        if not (0 <= gap.left_segment_index < len(segments) and 0 <= gap.right_segment_index < len(segments)):
            skipped_gap_indexes.add(gap_index)
            continue
        left, right = segments[gap.left_segment_index], segments[gap.right_segment_index]
        try:
            left_start, left_end = float(left.start_s), float(left.end_s)
            right_start, right_end = float(right.start_s), float(right.end_s)
        except (AttributeError, TypeError, ValueError, OverflowError):
            skipped_gap_indexes.add(gap_index)
            continue
        cue_intervals = ((left_start, left_end), (right_start, right_end))
        if any(
            not (math.isfinite(start_s) and math.isfinite(end_s) and 0.0 <= start_s < end_s <= duration)
            for start_s, end_s in cue_intervals
        ):
            skipped_gap_indexes.add(gap_index)
            continue
        start = max(0.0, min(gap.start_s - MICROGAP_CONTEXT_S, left_start, right_start))
        end = min(duration, max(gap.end_s + MICROGAP_CONTEXT_S, left_end, right_end))
        if not (math.isfinite(start) and math.isfinite(end) and start < end):
            skipped_gap_indexes.add(gap_index)
            continue
        if end - start > MICROGAP_WINDOW_MAXIMUM_S:
            skipped_gap_indexes.add(gap_index)
            continue
        if windows and start < windows[-1].end_s and max(end, windows[-1].end_s) - windows[-1].start_s <= MICROGAP_WINDOW_MAXIMUM_S:
            previous = windows[-1]
            windows[-1] = ContextWindow(
                previous.start_s,
                max(previous.end_s, end),
                previous.gap_indexes + (gap_index,),
            )
        else:
            windows.append(ContextWindow(start, end, (gap_index,)))

    selected = windows[:MICROGAP_MAX_WINDOWS]
    cap_skipped = sum(len(window.gap_indexes) for window in windows[MICROGAP_MAX_WINDOWS:])
    return selected, len(skipped_gap_indexes), cap_skipped


def refill_intercue_microgaps(
    audio_path: Path | str,
    segments,
    duration_s: float,
    transcribe_window,
    *,
    frame_tolerance_s: float = MICROGAP_ALIGNMENT_FRAME_S,
) -> list:
    """Recheck short opening cue gaps once and reconcile only anchored full words.

    The pre-pass transcript is immutable for matching. Recheck words outside an
    original gap are context only; no segment labels or audio-cut decisions are
    created here. One crop failure, ambiguous match, or empty response leaves
    the corresponding audio unchanged.
    """
    original = list(segments or ())
    gaps = find_intercue_microgaps(original, duration_s)
    windows, unresolved_skipped_gaps, cap_skipped_gaps = plan_microgap_windows(gaps, duration_s, original)
    selected_gap_indexes = {index for window in windows for index in window.gap_indexes}
    selected_gaps = [gap for index, gap in enumerate(gaps) if index in selected_gap_indexes]
    _worker_reporting.progress(
        "transcript.stt.microgap.plan",
        f"gaps={len(gaps)} selected={len(selected_gaps)} windows={len(windows)} "
        f"unresolvedSkipped={unresolved_skipped_gaps} capSkipped={cap_skipped_gaps} "
        f"cap={MICROGAP_MAX_WINDOWS} windowMax={MICROGAP_WINDOW_MAXIMUM_S:.0f}s",
    )
    if not windows:
        return original

    baseline = words_from_segments(original, offset_s=0.0, duration_s=float(duration_s))
    decisions = []
    counts = {"accepted": 0, "ambiguous": 0, "unchanged": 0, "failed": 0}
    total = len(windows)
    for window_index, window in enumerate(windows, 1):
        _worker_reporting.progress(
            "transcript.stt.microgap.window",
            f"{window_index}/{total} {window.start_s:.2f}-{window.end_s:.2f}s gaps={len(window.gap_indexes)}",
        )
        try:
            with tempfile.TemporaryDirectory(prefix="wilted-stt-microgap-") as tmp_dir:
                wav_path = Path(tmp_dir) / "window.wav"
                command = [
                    "ffmpeg", "-nostdin", "-v", "error",
                    "-ss", str(window.start_s), "-to", str(window.end_s), "-i", str(audio_path),
                    "-ac", "1", "-ar", "16000", str(wav_path),
                ]
                subprocess.run(command, check=True, capture_output=True, timeout=30)
                decoded_segments = join_split_words(transcribe_window(wav_path) or ())
        except (subprocess.SubprocessError, OSError, TranscriptionError) as error:
            logger.warning("Opening microgap window %.2f-%.2fs failed: %s", window.start_s, window.end_s, type(error).__name__)
            _worker_reporting.progress(
                "transcript.stt.microgap.failed",
                f"{window_index}/{total} {type(error).__name__}",
            )
            counts["failed"] += len(window.gap_indexes)
            continue

        decoded = words_from_segments(
            decoded_segments,
            offset_s=window.start_s,
            duration_s=float(duration_s),
            window_duration_s=window.end_s - window.start_s,
        )
        for gap_index in window.gap_indexes:
            decision = reconcile_gap(
                baseline,
                decoded,
                gaps[gap_index],
                frame_tolerance_s=frame_tolerance_s,
            )
            if decision.state.startswith("accepted"):
                decisions.append(decision)
                counts["accepted"] += 1
            elif decision.state.startswith("ambiguous"):
                counts["ambiguous"] += 1
            else:
                counts["unchanged"] += 1

    result = apply_decisions(original, baseline, decisions, in_time_order) if decisions else original
    inserted = sum(len(decision.additions) for decision in decisions)
    matched = sum(len(decision.updates) for decision in decisions)
    completed = sum(len(decision.replacements) for decision in decisions)
    _worker_reporting.progress(
        "transcript.stt.microgap.complete",
        f"windows={total} acceptedGaps={counts['accepted']} insertedWords={inserted} "
        f"matchedBoundaryWords={matched} completedFragments={completed} ambiguousGaps={counts['ambiguous']} "
        f"unchangedGaps={counts['unchanged']} failedGaps={counts['failed']} "
        f"unresolvedSkippedGaps={unresolved_skipped_gaps} capSkippedGaps={cap_skipped_gaps}",
    )
    return result
