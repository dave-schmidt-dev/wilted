"""Hand a break's edge cue back to the programme across a longer pause."""
from __future__ import annotations
from . import reporting as _worker_reporting
from .constants import BREAK_EDGE_GAP_MAX_SECONDS, BREAK_EDGE_GAP_MIN_SECONDS, BREAK_EDGE_MIN_CUES
from .interval_geometry import intervals_overlap


def trim_edge_cues_across_gaps(ads_module, segments, detections, protected_ids=frozenset()):
    """Drop a cut's first or last cue when the break's real pause sits inside it.

    A break usually starts and ends at a pause. When the pause after a cut's
    first cue is at least `BREAK_EDGE_GAP_MIN_SECONDS` and longer than the one
    before it, that cue belongs to the programme: The Headlines' sign-off
    ("those are the headlines ... a full month of free access") ahead of a
    7 s pause and the postroll. The last cue mirrors it. This only shrinks a
    cut, so its worst case is one advertising cue left audible; over the
    2026-10-22 rescan (102 labelled originals) it restored 8 programme cues
    and dropped no advertising cue. A cut shorter than `BREAK_EDGE_MIN_CUES`,
    the file's own first or last cue, a cue in `protected_ids` (explicit
    sponsor anchors, which the dropped-anchor audit tracks), and a silence
    over `BREAK_EDGE_GAP_MAX_SECONDS` (untranscribed audio, not a pause) leave
    the cut as it is.
    """
    def gap_before(cue_id):
        return float(segments[cue_id].start_s) - float(segments[cue_id - 1].end_s)

    trimmed = []
    for ad in detections:
        start_s, end_s = float(ad.start_s), float(ad.end_s)
        ids = [cue_id for cue_id, cue in enumerate(segments)
               if intervals_overlap(float(cue.start_s), float(cue.end_s), start_s, end_s)]
        if len(ids) >= BREAK_EDGE_MIN_CUES:
            first, last = ids[0], ids[-1]
            inner = gap_before(first + 1)
            if first > 0 and first not in protected_ids and BREAK_EDGE_GAP_MIN_SECONDS <= inner <= BREAK_EDGE_GAP_MAX_SECONDS and inner > gap_before(first):
                start_s = max(start_s, float(segments[first].end_s))
            inner = gap_before(last)
            if last < len(segments) - 1 and last not in protected_ids and BREAK_EDGE_GAP_MIN_SECONDS <= inner <= BREAK_EDGE_GAP_MAX_SECONDS and inner > gap_before(last + 1):
                end_s = min(end_s, float(segments[last].start_s))
        if (start_s, end_s) == (float(ad.start_s), float(ad.end_s)):
            trimmed.append(ad)
            continue
        _worker_reporting.progress(
            "ads.detect.edge-gap.trimmed",
            f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} -> {start_s:.3f}-{end_s:.3f} at the break's own pause",
        )
        trimmed.append(ads_module.AdSegment(start_s, end_s, float(ad.confidence), ad.label,
                                            kinds=tuple(getattr(ad, "kinds", ()) or ())))
    return trimmed
