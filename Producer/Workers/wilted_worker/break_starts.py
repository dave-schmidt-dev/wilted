"""Move a verified cut's start back to the cue where its break actually begins."""
from __future__ import annotations

import json

from . import reporting as _worker_reporting
from .constants import (
    BREAK_START_GAP_MIN_SECONDS,
    BREAK_START_MAX_SECONDS,
    BREAK_START_MAX_SEGMENTS,
    COMMERCIAL_RECOVERY_CONTEXT_CHARS,
    MAXIMUM_SINGLE_AD_SHARE,
    MAXIMUM_TOTAL_AD_SHARE,
)
from .interval_geometry import intervals_overlap
from .prompts import AD_BREAK_START_PROMPT

# The rendered lead-in marks the cut's own cues with this token, so the review
# can match a host-read setup to the sponsor it introduces. A cue the cut only
# partly overlaps is never marked: it may carry programme before the break.
_COMMERCIAL_MARKER = "verified commercial: "


def recover_late_break_starts(
    ads_module, backend, segments, detections, total_seconds, held_spans=None,
    protected_ids=frozenset(), released_heads=(),
):
    """Extend a surviving cut back to the cue after the pause that opens it.

    A confirmed cut often starts a cue or more after its break begins: a
    host-read lead-in, a postroll's first spot, or a mid-roll introduction.
    The cue that actually starts the break follows a pause at least
    `BREAK_START_GAP_MIN_SECONDS` long and longer than the pause before the
    cut's current first cue, and the model reviews those candidates. The
    window never reaches back past `BREAK_START_MAX_SEGMENTS` cues or
    `BREAK_START_MAX_SECONDS`, and stops before another cut, an explicit
    sponsor anchor, a positively identified programme cue, or a cue the edge
    trim just handed back to the programme.

    Args:
        ads_module: The archive ad module (AdSegment, render helpers).
        backend: The review backend; the auditing backend on the live path.
        segments: The episode's transcript cues.
        detections: The surviving cuts after the earlier recovery passes.
        total_seconds: The probed episode duration.
        held_spans: Held intervals; a `programme-boundary` hold is a stop.
        protected_ids: Cue IDs of explicit sponsor anchors.
        released_heads: (start, end) intervals the edge trim just handed back
            to the programme. They are intervals, not cut starts, so a later
            resize that moves the cut's start cannot lose them.

    Returns:
        The detections, with accepted starts moved back to the break's pause.
    """
    if not detections or len(segments) < 2 or not 0 < total_seconds < float("inf"):
        return detections
    protected_ids = frozenset(protected_ids or ())
    released_heads = tuple(released_heads or ())
    recovered = list(detections)
    for index, ad in enumerate(tuple(recovered)):
        ad_start, ad_end = float(ad.start_s), float(ad.end_s)
        overlap_ids = [
            segment_id for segment_id, segment in enumerate(segments)
            if intervals_overlap(float(segment.start_s), float(segment.end_s), ad_start, ad_end)
        ]
        if not overlap_ids or overlap_ids[0] == 0:
            continue
        first = overlap_ids[0]
        contained_ids = [
            segment_id for segment_id in overlap_ids
            if ad_start <= float(segments[segment_id].start_s)
            and float(segments[segment_id].end_s) <= ad_end
        ]
        if not contained_ids:
            # A cut that fully contains no cue is a fragment, and a fragment
            # cannot say where a passage begins (CR-2).
            continue

        def preceding_gap(segment_id):
            return float(segments[segment_id].start_s) - float(segments[segment_id - 1].end_s)

        gap_before_first = preceding_gap(first)
        window_ids = []
        for segment_id in range(first - 1, -1, -1):
            if len(window_ids) >= BREAK_START_MAX_SEGMENTS:
                break
            if ad_start - float(segments[segment_id].start_s) > BREAK_START_MAX_SECONDS:
                break
            if segment_id in protected_ids:
                break
            if any(
                intervals_overlap(
                    float(segments[segment_id].start_s), float(segments[segment_id].end_s),
                    float(start), float(end),
                )
                for start, end in released_heads
            ):
                # The edge trim just handed this cue back to the programme;
                # reaching past it would re-cut the sign-off it released.
                break
            if any(
                other is not ad and intervals_overlap(
                    float(segments[segment_id].start_s), float(segments[segment_id].end_s),
                    float(other.start_s), float(other.end_s),
                )
                for other in recovered
            ):
                break
            if any(
                held.reason == "programme-boundary" and intervals_overlap(
                    float(segments[segment_id].start_s), float(segments[segment_id].end_s),
                    float(held.start_s), float(held.end_s),
                )
                for held in held_spans or ()
            ):
                break
            window_ids.append(segment_id)
        window_ids.reverse()
        candidates = [
            segment_id for segment_id in window_ids
            if segment_id > 0
            and preceding_gap(segment_id) >= BREAK_START_GAP_MIN_SECONDS
            and preceding_gap(segment_id) > gap_before_first
        ]
        if not candidates:
            continue
        marked_ids = contained_ids[:2]
        render_ids = [*window_ids]
        if first not in marked_ids:
            render_ids.append(first)
        render_ids.extend(marked_ids)
        rendered = "\n".join(
            ads_module._segment_prefix(segment_id, segments[segment_id])  # noqa: SLF001
            + (_COMMERCIAL_MARKER if segment_id in marked_ids else "")
            + (segments[segment_id].text or "")
            for segment_id in render_ids
        )
        if len(rendered) > COMMERCIAL_RECOVERY_CONTEXT_CHARS:
            _worker_reporting.progress(
                "ads.detect.break-start.skipped",
                "the rendered lead-in exceeds the rendering budget; keeping the verified cut",
            )
            continue
        try:
            response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
                backend,
                AD_BREAK_START_PROMPT,
                rendered,
                ads_module._id_response_format("ad_start_id", [-1, *candidates]),  # noqa: SLF001
            )
            parsed = json.loads(response)
            if not isinstance(parsed, dict) or set(parsed) != {"ad_start_id"}:
                raise ValueError("ad_start_id response must contain exactly ad_start_id")
            ad_start_id = parsed["ad_start_id"]
            if (
                isinstance(ad_start_id, bool)
                or not isinstance(ad_start_id, int)
                or ad_start_id not in [-1, *candidates]
            ):
                raise ValueError("ad_start_id must be one of the supplied IDs")
            if ad_start_id == -1:
                continue
            extension_start = float(segments[ad_start_id].start_s)
            if extension_start >= ad_start:
                raise ValueError("late-start extension is not earlier than the verified cut")
            if any(
                other is not ad
                and float(other.start_s) < ad_start
                and float(other.end_s) > extension_start
                for other in recovered
            ):
                raise ValueError("late-start extension would cross another cut")
            proposed_share = (ad_end - extension_start) / total_seconds
            if proposed_share > MAXIMUM_SINGLE_AD_SHARE:
                _worker_reporting.progress(
                    "ads.detect.break-start.skipped",
                    f"late start at ID {ad_start_id} would make the cut {proposed_share:.0%} of "
                    f"the episode, over the {MAXIMUM_SINGLE_AD_SHARE:.0%} single-share ceiling; "
                    "keeping the verified cut",
                )
                continue
            total_removed = sum(float(item.end_s) - float(item.start_s) for item in recovered)
            total_removed += ad_start - extension_start
            if total_removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
                _worker_reporting.progress(
                    "ads.detect.break-start.skipped",
                    f"late start at ID {ad_start_id} would leave {total_removed / total_seconds:.0%} "
                    f"of the episode removed, over the {MAXIMUM_TOTAL_AD_SHARE:.0%} total-share "
                    "ceiling; keeping the verified cut",
                )
                continue
        except Exception as error:  # noqa: BLE001 - incomplete review preserves the verified cut
            _worker_reporting.progress(
                "ads.detect.break-start.skipped",
                f"late-start review preserved the existing cut: {type(error).__name__}: {error}",
            )
            continue
        recovered[index] = ads_module.AdSegment(
            extension_start, ad_end, float(ad.confidence), ad.label,
            kinds=tuple(getattr(ad, "kinds", ()) or ()),
        )
        _worker_reporting.progress(
            "ads.detect.break-start",
            f"{ad_start:.3f}-{ad_end:.3f} extended back to {extension_start:.3f} at cue ID {ad_start_id}",
        )
    return recovered
