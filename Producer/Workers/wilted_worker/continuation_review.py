"""Independent proof for an adjacent commercial continuation."""
from __future__ import annotations

import json

from .boundary_review import overlaps_programme_boundary, record_programme_boundary
from .commercial_preservation import (
    _generate_review,
    _measure_review_request,
)
from .constants import COMMERCIAL_PRESERVATION_FLANK_IDS
from .prompts import COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT
from .review_formats import (
    _commercial_preservation_labels,
    _commercial_preservation_response_format,
)
from .sponsor_evidence import _commercial_recovery_context


def _commercial_label_ids(context_ids, proposed_ids):
    """Select only the existing local commercial-preservation label window."""
    first, last = proposed_ids[0], proposed_ids[-1]
    return tuple(
        segment_id for segment_id in context_ids
        if first - COMMERCIAL_PRESERVATION_FLANK_IDS
        <= segment_id
        <= last + COMMERCIAL_PRESERVATION_FLANK_IDS
    )


def _record_parseable_boundaries(response, context_ids, segments, total_seconds, held_spans):
    """Keep positive per-ID evidence even when the complete reply is invalid."""
    try:
        parsed = json.loads(response)
    except (TypeError, ValueError):
        return False
    labels = parsed.get("labels") if isinstance(parsed, dict) else None
    if not isinstance(labels, dict):
        return True
    recorded = True
    for segment_id in context_ids:
        label = labels.get(str(segment_id))
        if isinstance(label, str) and label in {"programme", "mixed"}:
            try:
                record_programme_boundary(
                    held_spans, segments[segment_id], total_seconds
                )
            except Exception:  # noqa: BLE001 - keep scanning independent positive IDs
                recorded = False
    return recorded


def verify_adjacent_commercial_extension(
    ads_module, backend, segments, total_seconds, proposed_ids, held_spans=None,
):
    """Return whether every cue in one nominated extension is commercial.

    The nomination remains only a boundary suggestion.  This review sees the
    complete candidate and bounded complete-cue context on both sides, then
    requires a commercial label for every candidate cue.
    """
    proposed_ids = tuple(proposed_ids)
    if (
        not proposed_ids
        or proposed_ids != tuple(range(proposed_ids[0], proposed_ids[-1] + 1))
        or any(segment_id < 0 or segment_id >= len(segments) for segment_id in proposed_ids)
        or any(
            overlaps_programme_boundary(
                held_spans,
                segments[segment_id].start_s,
                segments[segment_id].end_s,
            )
            for segment_id in proposed_ids
        )
    ):
        return False

    def fit(context_ids, rendered):
        labelled_ids = _commercial_label_ids(context_ids, proposed_ids)
        user_content = (
            f"IDs to classify: {', '.join(map(str, labelled_ids))}\n{rendered}"
        )
        return _measure_review_request(
            backend,
            COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            user_content,
            _commercial_preservation_response_format(labelled_ids),
        )

    try:
        _candidate, context_ids, rendered = _commercial_recovery_context(
            ads_module,
            segments,
            proposed_ids[0],
            proposed_ids[-1],
            total_seconds,
            fit=fit,
        )
        labelled_ids = _commercial_label_ids(context_ids, proposed_ids)
        response, _tokens = _generate_review(
            backend,
            COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            f"IDs to classify: {', '.join(map(str, labelled_ids))}\n{rendered}",
            response_format=_commercial_preservation_response_format(labelled_ids),
        )
        boundaries_recorded = _record_parseable_boundaries(
            response, context_ids, segments, total_seconds, held_spans
        )
        labels = _commercial_preservation_labels(response, labelled_ids)
        return boundaries_recorded and all(
            labels[str(segment_id)] == "commercial" for segment_id in proposed_ids
        )
    except Exception:  # noqa: BLE001 - optional proof failure preserves the core cut
        return False
