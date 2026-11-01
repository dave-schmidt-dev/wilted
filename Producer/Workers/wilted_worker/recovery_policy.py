"""Known ad-kind safeguards for commercial recovery."""
from __future__ import annotations

from typing import Any, Sequence

from . import reporting as _worker_reporting
from .interval_geometry import intervals_overlap


_DISABLED_HOUSE_REASON = "house-promotion-disabled"


def _subtract_intervals(pieces, excluded_start: float, excluded_end: float):
    """Subtract an existing cut from a proposed held interval."""
    remaining = []
    for start_s, end_s in pieces:
        if not intervals_overlap(start_s, end_s, excluded_start, excluded_end):
            remaining.append((start_s, end_s))
            continue
        if start_s < excluded_start:
            remaining.append((start_s, min(end_s, excluded_start)))
        if excluded_end < end_s:
            remaining.append((max(start_s, excluded_end), end_s))
    return remaining


def overlaps_blocked_house_region(held_spans, start_s: float, end_s: float) -> bool:
    """Return whether a candidate overlaps known house audio kept by policy."""
    return any(
        held.reason == _DISABLED_HOUSE_REASON
        and intervals_overlap(
            float(start_s), float(end_s), float(held.start_s), float(held.end_s)
        )
        for held in held_spans or ()
    )


def project_detections_around_blocked_house_regions(detections, ads_module, held_spans):
    """Clip later spans at known house regions while preserving paid cuts."""
    blocked = tuple(
        (float(held.start_s), float(held.end_s))
        for held in held_spans or ()
        if held.reason == _DISABLED_HOUSE_REASON
    )
    if not blocked:
        return list(detections)

    projected = []
    for ad in detections:
        pieces = [(float(ad.start_s), float(ad.end_s))]
        for blocked_start, blocked_end in blocked:
            pieces = _subtract_intervals(pieces, blocked_start, blocked_end)
        if len(pieces) != 1 or pieces[0] != (float(ad.start_s), float(ad.end_s)):
            _worker_reporting.progress(
                "ads.detect.recovery.projected",
                "later recovery was clipped at known house material",
            )
        kinds = tuple(ads_module.ad_segment_kinds(ad))
        for start_s, end_s in pieces:
            if end_s > start_s:
                projected.append(ads_module.AdSegment(
                    start_s, end_s, float(ad.confidence), ad.label, kinds=kinds,
                ))
    return sorted(projected, key=lambda ad: float(ad.start_s))


def enforce_known_house_kind_policy(
    detections: Sequence[Any],
    ads_module: Any,
    total_seconds: float,
    remove_self_promotion: bool,
    held_spans: list[Any] | None = None,
) -> list[Any]:
    """Keep detected house promotions when the feed setting disables their removal.

    Held regions exclude other established cuts, so a known house span cannot
    erase a separate paid cut that overlaps its original interval.
    """
    if remove_self_promotion:
        return list(detections)

    house_kind = ads_module.AD_KIND_HOUSE

    def is_house(ad):
        return (
            house_kind in ads_module.ad_segment_kinds(ad)
            or getattr(ad, "label", None) in {"self_promo", "newsletter_pitch"}
        )

    surviving = []
    for ad in detections:
        if not is_house(ad):
            surviving.append(ad)
            continue

        _worker_reporting.progress(
            "ads.detect.policy.rejected",
            "known house promotion is disabled; preserving its audio",
        )
        protected = [
            (float(other.start_s), float(other.end_s))
            for other in detections
            if other is not ad and not is_house(other)
        ]
        pieces = [(float(ad.start_s), float(ad.end_s))]
        for paid_start, paid_end in protected:
            pieces = _subtract_intervals(pieces, paid_start, paid_end)
        if held_spans is not None:
            from .boundary_review import record_held_span

            for start_s, end_s in pieces:
                if end_s > start_s:
                    record_held_span(
                        held_spans, start_s, end_s, _DISABLED_HOUSE_REASON, total_seconds
                    )
    return surviving
