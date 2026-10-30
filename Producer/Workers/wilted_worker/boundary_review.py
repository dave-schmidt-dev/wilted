"""Boundary review and rebase loop for candidate advertising spans."""
from __future__ import annotations

from typing import Any

from . import reporting as _worker_reporting
from .ad_audit import HeldAdSpan
from .commercial_seeds import _constrained_id
from .constants import OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS
from .edge_recovery import _program_starts_inside
from .interval_geometry import intervals_overlap
from .reporting import WorkerError
from .prompts import OVERSIZED_SPAN_CONFIRM_PROMPT, OVERSIZED_SPAN_PROGRAM_START_PROMPT


def record_programme_boundary(
    held_spans: list[HeldAdSpan] | None, cue: Any, total_seconds: float | None = None,
) -> None:
    """Retain a positively identified programme/mixed cue for later passes.

    This records evidence, not a model verdict: callers retain their own
    review and malformed-timing policies. Unknown reviews and advisory seeds
    must not call this. Optional reporting preserves each caller's journal.
    """
    start_s, end_s = float(cue.start_s), float(cue.end_s)
    if total_seconds is not None:
        record_held_span(held_spans, start_s, end_s, "programme-boundary", total_seconds)
    elif held_spans is not None:
        held_spans.append(HeldAdSpan(start_s, end_s, "programme-boundary"))


def overlaps_programme_boundary(
    held_spans: list[HeldAdSpan] | tuple[HeldAdSpan, ...] | None,
    start_s: float, end_s: float,
) -> bool:
    """Test positive keep evidence using the shared interval geometry.

    Other holds describe uncertainty or a refused proposal, not a positively
    identified programme cue. Touching endpoints and one-ULP drift do not
    cross a barrier; point cues keep the geometry owner's existing semantics.
    Read the current ledger each time, so later passes see newly found cues.
    """
    return any(
        held.reason == "programme-boundary" and intervals_overlap(
            float(start_s), float(end_s), float(held.start_s), float(held.end_s)
        )
        for held in held_spans or ()
    )


def record_held_span(
    held_spans: list[HeldAdSpan] | None,
    start_s: float,
    end_s: float,
    reason: str,
    total_seconds: float,
) -> None:
    """Record an uncut interval and report its share of the episode."""
    start_s, end_s = float(start_s), float(end_s)
    if held_spans is not None:
        held_spans.append(HeldAdSpan(start_s, end_s, reason))
    share = (end_s - start_s) / total_seconds if total_seconds > 0 else 0.0
    _worker_reporting.progress(
        "ads.detect.span.held",
        f"{start_s:.3f}-{end_s:.3f} is held: {reason} ({share:.0%} of the episode)",
    )


def complete_fragment_visible(ads_module, ids, segments):
    """Require the independent preservation question to see every proposed word."""
    expected = "\n".join(
        ads_module._segment_prefix(i, segments[i]) + (segments[i].text or "")
        for i in ids
    )
    try:
        return ads_module._render_segments_bounded(ids, segments) == expected
    except Exception:  # A renderer failure cannot authorize removal.
        return False


def review_candidate_span(
    ads_module: Any,
    backend: Any,
    segments: list[Any],
    ad: Any,
    total_seconds: float,
    rebase_anchor_ids: frozenset[int] = frozenset(),
    held_spans: list[HeldAdSpan] | None = None,
) -> tuple[str, Any | None]:
    """Review one candidate span through a strictly shrink-only review loop.

    Positive programme and mixed cues are immutable keep barriers. Candidate
    fragments clip or rebase around them, requiring a fresh independent
    confirmation on the entire remaining proposed fragment before cutting.
    """
    span_ids = [
        segment_id
        for segment_id, segment in enumerate(segments)
        if intervals_overlap(
            float(segment.start_s), float(segment.end_s),
            float(ad.start_s), float(ad.end_s),
        )
    ]
    if len(span_ids) < 2:
        return ("unanswered", None)

    if len(span_ids) > OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS:
        _worker_reporting.progress("ads.detect.span.resize.skipped", "complete span exceeds the cue budget")
        return ("unanswered", None)
    current_ids = span_ids
    barriers = {
        i for i, cue in enumerate(segments)
        if overlaps_programme_boundary(held_spans, cue.start_s, cue.end_s)
    }

    def preserve(cue_id):
        barriers.add(cue_id)
        cue = segments[cue_id]
        if float(cue.end_s) <= float(cue.start_s):
            raise WorkerError("ads-recovery-audit-failed", "programme cue has no positive timing interval")
        record_programme_boundary(held_spans, cue, total_seconds)

    def hold(reason="boundary-review-unresolved", cause="boundary review unresolved"):
        _worker_reporting.progress("ads.detect.span.resize.skipped",
                                   "the program starts at the first segment; preserving audio"
                                   if reason == "sponsor-prefix-programme-found" else
                                   f"{cause}; preserving audio")
        record_held_span(held_spans, ad.start_s, ad.end_s,
                         reason, total_seconds)
        return ("program_found" if any(i in barriers for i in span_ids) else "unanswered", None)

    try:
        program_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_PROGRAM_START_PROMPT, "program_start_id",
            current_ids, [-1, *current_ids], segments,
        )
    except Exception as error:  # An unanswered boundary cannot authorize a cut.
        return hold(cause=f"resize review failed: {error}")
    boundary_id = program_id
    if program_id != -1:
        preserve(program_id)
        if program_id > current_ids[0]:
            previous = program_id - 1
            if previous > current_ids[0] and _program_starts_inside(
                ads_module, backend, segments, previous
            ):
                preserve(previous)
                _worker_reporting.progress("ads.detect.boundary.shortened", f"the program starts inside segment {previous}")
                boundary_id = previous
            current_ids = [i for i in current_ids if i < boundary_id]
    visited = set()
    rebased = False
    for _ in range(4):
        first_barrier = next((i for i in current_ids if i in barriers), None)
        if first_barrier is not None:
            if first_barrier > current_ids[0]:
                current_ids = [i for i in current_ids if i < first_barrier]
            else:
                anchor = next((i for i in sorted(rebase_anchor_ids)
                               if i in current_ids and i > first_barrier and i not in barriers), None)
                if anchor is None:
                    return hold("sponsor-prefix-programme-found")
                current_ids = [i for i in current_ids if i >= anchor]
                rebased = True
        if not current_ids or tuple(current_ids) in visited:
            return hold()
        visited.add(tuple(current_ids))
        if not complete_fragment_visible(ads_module, current_ids, segments):
            return hold()
        try:
            confirm_id = _constrained_id(
                ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
                current_ids, [-1, *current_ids], segments,
            )
        except Exception as error:
            _worker_reporting.progress("ads.detect.span.resize.skipped", f"confirmation failed: {type(error).__name__}")
            return hold()
        if confirm_id != -1:
            preserve(confirm_id)
            boundary_id = confirm_id
            continue
        start_s = max(float(ad.start_s), float(segments[current_ids[0]].start_s))
        end_s = min(float(ad.end_s), float(segments[current_ids[-1]].end_s))
        if end_s <= start_s or any(i in barriers for i in current_ids):
            return hold()
        stage = "rebased" if rebased else ("resized" if boundary_id != -1 else "confirmed")
        _worker_reporting.progress(
            "ads.detect.span." + stage,
            f"advertising throughout {start_s:.3f}-{end_s:.3f} before program ID {boundary_id}",
        )
        return ("confirmed", ads_module.AdSegment(start_s, end_s, float(ad.confidence), ad.label))
    return hold()


def reject_programme_conflicts(detections, held_spans):
    """Keep the episode whole if later recovery crosses a positive keep cue."""
    conflicts = [ad for ad in detections
                 if overlaps_programme_boundary(held_spans, ad.start_s, ad.end_s)]
    if conflicts:
        if held_spans is not None:
            held_spans.extend(HeldAdSpan(float(ad.start_s), float(ad.end_s), "programme-boundary-conflict")
                              for ad in conflicts)
        _worker_reporting.progress("ads.detect.refused", "recovery crosses a positively identified programme cue")
        return []
    return detections
