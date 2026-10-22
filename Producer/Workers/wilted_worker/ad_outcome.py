"""The last word on an ad analysis: cut what it found, or keep the whole original.

`detect_and_cut` and the ad corpus replay both call `decide_ad_outcome` on the
analysis `analyze_ad_detections` returns, so a replay scores the same decision
the app commits rather than the detector's proposals before this check.
"""

from __future__ import annotations

from dataclasses import dataclass

from .ad_audit import AdAnalysisAudit, DeclinedCommercialEvidenceSeed
from .interval_geometry import interval_contains, intervals_overlap

UNRESOLVED_SPANS_REASON = (
    "ad review could not safely resolve all proposed commercial spans"
)

# Held spans that leave the whole episode in doubt: a share ceiling is a claim
# about every cut together, and an unresolved programme boundary is a claim
# about the edge of a cut that was proposed.
WHOLE_ORIGINAL_HOLD_REASONS = frozenset(
    {
        "total-share-ceiling",
        "programme-boundary-conflict",
        "boundary-review-unresolved",
        "credits-boundary-unresolved",
    }
)

# A held span that positively resolves the commercial evidence it contains.
_RESOLVING_HOLD_REASONS = frozenset(
    {"sponsor-prefix-programme-found", "programme-boundary"}
)

# The only unresolved seed that can stay audible on its own: review neither
# confirmed nor declined it, and no proposed cut reached it. A seed a proposed
# cut overlapped (`dropped-after-proposal`) is doubt about that cut's own
# extent, so it still keeps the whole original.
_LOCAL_SEED_REASON = "review-unresolved"


@dataclass(frozen=True)
class AdOutcome:
    """Either the reason the whole original is kept, or the cuts stand.

    `left_in` names the unresolved evidence spans that stay audible while the
    other cuts are applied. It is empty whenever `keep_whole_reason` is set.
    """

    keep_whole_reason: str | None
    left_in: tuple[DeclinedCommercialEvidenceSeed, ...] = ()


def _resolved_by_hold(
    seed: DeclinedCommercialEvidenceSeed, audit: AdAnalysisAudit
) -> bool:
    """A positively preserved mixed cue resolves its own CTA evidence."""
    return any(
        held.reason in _RESOLVING_HOLD_REASONS
        and interval_contains(held.start_s, held.end_s, seed.start_s, seed.end_s)
        for held in audit.held_spans
    )


def _touches_a_cut(seed: DeclinedCommercialEvidenceSeed, detections, segments) -> bool:
    """Whether a cut overlaps the seed or either cue beside it.

    A seed next to a cut may be that advertisement's unconfirmed edge, so the
    cut's own boundary is in doubt and the seed cannot be judged on its own.
    """
    first = max(seed.ids[0] - 1, 0)
    last = min(seed.ids[-1] + 1, len(segments) - 1)
    start = min(seed.start_s, float(segments[first].start_s))
    end = max(seed.end_s, float(segments[last].end_s))
    return any(
        intervals_overlap(float(ad.start_s), float(ad.end_s), start, end)
        for ad in detections
    )


def decide_ad_outcome(audit: AdAnalysisAudit, detections, segments) -> AdOutcome:
    """Decide whether the analysis may be cut.

    Args:
        audit: The analysis audit, with held spans and declined evidence seeds.
        detections: The final detections the cut would apply.
        segments: The aligned segments the analysis read, indexed by cue ID.

    Returns:
        The outcome. Any held span in `WHOLE_ORIGINAL_HOLD_REASONS` keeps the
        whole original, as does any unresolved seed unless every one is a
        `review-unresolved` seed that touches no cut and there is at least one
        cut to apply. Those seeds stay audible in `left_in` and the cuts stand.
    """
    if any(span.reason in WHOLE_ORIGINAL_HOLD_REASONS for span in audit.held_spans):
        return AdOutcome(UNRESOLVED_SPANS_REASON)
    unresolved = tuple(
        seed
        for seed in audit.declined_commercial_evidence_seeds
        if seed.reason != "review-declined" and not _resolved_by_hold(seed, audit)
    )
    if not unresolved:
        return AdOutcome(None)
    local = (
        bool(detections)
        and all(seed.reason == _LOCAL_SEED_REASON for seed in unresolved)
        and not any(_touches_a_cut(seed, detections, segments) for seed in unresolved)
    )
    if not local:
        return AdOutcome(UNRESOLVED_SPANS_REASON)
    return AdOutcome(None, left_in=unresolved)
