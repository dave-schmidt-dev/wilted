"""Pure resource-cost estimation for background processing jobs.

Cost is derived from job kind and (for ``PREPARE``) available job metadata —
it is never stored, so this module performs no I/O, DB access, or clock reads.
"""

from __future__ import annotations

from enum import StrEnum

from wilted.background_work.contracts import JobKind
from wilted.speech_ready import job_requires_speech

_CHEAP_KINDS = frozenset({JobKind.DISCOVER, JobKind.REPORT_ASSEMBLY})
_MEDIUM_KINDS = frozenset({JobKind.CLASSIFY})
_ALWAYS_EXPENSIVE_KINDS = frozenset({JobKind.ARTICLE_CACHE, JobKind.COMPACT_BRIEFING})


class JobCostClass(StrEnum):
    """Coarse relative resource-cost tier for one processing job."""

    CHEAP = "cheap"
    MEDIUM = "medium"
    EXPENSIVE = "expensive"


def estimate_cost_class(
    kind: JobKind | str,
    *,
    item_type: str | None = None,
    checkpoint_json: str | None = None,
) -> JobCostClass:
    """Estimate the relative resource cost of running one processing job.

    Pure function: no I/O, no DB, no clock. Reuses
    :func:`wilted.speech_ready.job_requires_speech` for the ``PREPARE``
    branch instead of re-deriving speech policy.

    Args:
        kind: Job kind value or enum.
        item_type: Optional item type (``article`` / ``podcast_episode``),
            forwarded to the ``PREPARE`` speech-policy check.
        checkpoint_json: Serialized job checkpoint metadata, forwarded to
            the ``PREPARE`` speech-policy check.

    Returns:
        The estimated :class:`JobCostClass` for the job.
    """
    resolved_kind = JobKind(kind) if not isinstance(kind, JobKind) else kind

    if resolved_kind in _CHEAP_KINDS:
        return JobCostClass.CHEAP
    if resolved_kind in _MEDIUM_KINDS:
        return JobCostClass.MEDIUM
    if resolved_kind in _ALWAYS_EXPENSIVE_KINDS:
        return JobCostClass.EXPENSIVE

    # Only JobKind.PREPARE remains: expensive when the speech stack (TTS or
    # tier-3 STT) may be invoked; skip-TTS article prepare is cheap text work.
    if job_requires_speech(kind=resolved_kind, checkpoint_json=checkpoint_json, item_type=item_type):
        return JobCostClass.EXPENSIVE
    return JobCostClass.CHEAP


__all__ = ["JobCostClass", "estimate_cost_class"]
