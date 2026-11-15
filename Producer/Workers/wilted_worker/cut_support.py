"""Cut-stage support, copied unchanged from the local finder's modules.

The labelled cut stage needs these helpers; the originals leave with the local
finder, so the cut stage owns its own copies and keeps their progress stages.
"""
from __future__ import annotations

import math
import os
import shutil
from dataclasses import dataclass

from . import reporting as _worker_reporting
from .constants import CUT_TOOLS, MAXIMUM_TOTAL_AD_SHARE
from .cue_timing import effective_removed_intervals
from .reporting import WorkerError


AD_KIND_PAID = "paid advertising"
AD_KIND_HOUSE = "house promotion"
AD_KIND_CREDITS = "credits"

UNRESOLVED_SPANS_REASON = (
    "ad review could not safely resolve all proposed commercial spans"
)


@dataclass(frozen=True)
class HeldAdSpan:
    """A detected span preserved to enforce an episode-level safety bound."""

    start_s: float
    end_s: float
    reason: str


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


def _union_ad_seconds(detections, total_seconds):
    """Count removed source time once even when nominations overlap."""
    intervals = []
    for ad in detections:
        try:
            start_s, end_s = float(ad.start_s), float(ad.end_s)
        except (AttributeError, TypeError, ValueError):
            return math.inf
        if not (math.isfinite(start_s) and math.isfinite(end_s)
                and 0 <= start_s < end_s and start_s < total_seconds):
            return math.inf
        intervals.append((start_s, min(end_s, total_seconds)))
    if not intervals:
        return 0.0

    intervals.sort()
    total = 0.0
    start_s, end_s = intervals[0]
    for next_start, next_end in intervals[1:]:
        if next_start <= end_s:
            end_s = max(end_s, next_end)
        else:
            total += end_s - start_s
            start_s, end_s = next_start, next_end
    return total + end_s - start_s


def enforce_total_ad_share_ceiling(detections, total_seconds, held_spans=None, retired_detections=None):
    """Hold every final detection if recovery leaves the total over its ceiling.

    An optional ledger records every supplied cut only when this guard's actual
    over-ceiling decision clears them all.
    """
    if total_seconds <= 0 or not detections:
        return detections
    total_removed = _union_ad_seconds(detections, total_seconds)
    share = total_removed / total_seconds
    if share <= MAXIMUM_TOTAL_AD_SHARE:
        return detections
    if retired_detections is not None:
        retired_detections.extend(detections)
    for ad in detections:
        record_held_span(
            held_spans, ad.start_s, ad.end_s, "total-share-ceiling", total_seconds
        )
    _worker_reporting.progress(
        "ads.detect.refused",
        f"final recovered detections total {total_removed:.1f}s of {total_seconds:.1f}s "
        f"({share:.0%}), over the {MAXIMUM_TOTAL_AD_SHARE:.0%} total-share ceiling; "
        "keeping the episode whole",
    )
    return []


def _ad_kind_fields(kinds) -> dict:
    """The kind fields every published span carries.

    `kind` is the single strongest kind for the span -- paid advertising,
    house promotion, or credits -- while `kinds` is the full set a merged span
    can carry, so two adjacent differently labelled runs report both rather
    than attributing the whole run to the survivor's label. `disposition` is
    the corpus's scoring vocabulary: `must-cut` for a span that contains paid
    advertising, `acceptable-cut` for house promotion and credits, which David
    decided on 2026-09-17 are not advertising.
    """
    if AD_KIND_PAID in kinds:
        disposition = "must-cut"
    else:
        disposition = "acceptable-cut"
    for kind in (AD_KIND_PAID, AD_KIND_HOUSE, AD_KIND_CREDITS):
        if kind in kinds:
            return {"kind": kind, "kinds": list(kinds), "disposition": disposition}
    # An unknown vocabulary is paid advertising by default: cutting a sold
    # placement is required, leaving programme in is not.
    return {"kind": AD_KIND_PAID, "kinds": list(kinds), "disposition": "must-cut"}


def effective_ad_spans(raw_nominations, keeps, total_seconds) -> list[dict]:
    """The removed intervals the keep map actually cuts, with their kinds.

    Effective-cut selection is the keep map's complement, not the nomination
    list: a nomination can be cut down or absorbed by its neighbour. Every
    nomination overlapping an interval contributes its kind, so a cut that
    removes a paid read and a house promotion together still reports both and
    is treated as a paid removal. An interval no nomination overlaps reports
    the label `advertisement` and a paid kind, the conservative reading.
    """
    spans = []
    for start, end in effective_removed_intervals(keeps, total_seconds):
        overlapping = [
            ad for ad in raw_nominations
            if ad["endSeconds"] > start and ad["startSeconds"] < end
        ]
        kinds = tuple(sorted({kind for ad in overlapping for kind in ad["kinds"]}))
        if not kinds:
            kinds = (AD_KIND_PAID,)
        spans.append({
            "startSeconds": round(start, 3), "endSeconds": round(end, 3),
            "label": overlapping[0]["label"] if overlapping else "advertisement",
            **_ad_kind_fields(kinds),
            "confidence": max((ad["confidence"] for ad in overlapping), default=0.0),
        })
    return spans


def preflight_cut_tools() -> None:
    """Fail before any work if the required audio tools are missing."""
    missing = [tool for tool in CUT_TOOLS if shutil.which(tool) is None]
    if missing:
        raise WorkerError(
            "cut-tools-missing",
            f"{', '.join(missing)} not on PATH ({os.environ.get('PATH', '')}); install ffmpeg",
        )

