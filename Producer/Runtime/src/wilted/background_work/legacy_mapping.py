"""Exhaustive legacy Item.status cohort mapping table.

Maps every legacy ``status`` × ``item_type`` × ``artifact`` cohort (plus
``keep`` override for ``expired`` rows) to orthogonal content states, report
decisions, and quarantine outcomes.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from wilted.background_work.contracts import (
    AnalysisState,
    ContentState,
    FetchState,
    PlaybackState,
    PreparationState,
    ReportDecision,
    RetentionFacts,
    RetentionState,
)


class LegacyStatus(StrEnum):
    """Legacy monolithic Item.status values."""

    DISCOVERED = "discovered"
    FETCHED = "fetched"
    CLASSIFIED = "classified"
    SELECTED = "selected"
    PROCESSING = "processing"
    READY = "ready"
    COMPLETED = "completed"
    EXPIRED = "expired"
    SKIPPED = "skipped"
    ERROR = "error"


class ItemType(StrEnum):
    """Legacy item_type values."""

    ARTICLE = "article"
    PODCAST_EPISODE = "podcast_episode"


class ArtifactCohort(StrEnum):
    """Artifact-presence cohort for migration mapping."""

    NONE = "none"
    PARTIAL = "partial"
    COMPLETE = "complete"


@dataclass(frozen=True, slots=True)
class LegacyCohort:
    """One legacy migration input cohort.

    Attributes:
        status: Legacy status value.
        item_type: Article or podcast episode.
        artifacts: Observed artifact-presence cohort.
        keep_override: For ``expired`` rows only — explicit keep flag.
    """

    status: LegacyStatus
    item_type: ItemType
    artifacts: ArtifactCohort
    keep_override: bool = False


@dataclass(frozen=True, slots=True)
class MappingOutcome:
    """Result of mapping one legacy cohort.

    Attributes:
        content: Orthogonal content state, or None when quarantined.
        report_decision: Report-scoped decision when applicable.
        quarantine: When True, the row must be resolved before writers restart.
        quarantine_reason: Human-readable reason for quarantine rows.
    """

    content: ContentState | None
    report_decision: ReportDecision | None = None
    quarantine: bool = False
    quarantine_reason: str = ""

    def __post_init__(self) -> None:
        if self.quarantine and self.content is not None:
            raise ValueError("Quarantine outcomes must not include content state")
        if not self.quarantine and self.content is None:
            raise ValueError("Non-quarantine outcomes must include content state")


def _active_retention() -> RetentionFacts:
    return RetentionFacts(state=RetentionState.ACTIVE)


def _expired_retention(*, keep: bool) -> RetentionFacts:
    if keep:
        return RetentionFacts(state=RetentionState.ACTIVE, keep_override=True)
    return RetentionFacts(state=RetentionState.EXPIRED)


def _quarantine(reason: str) -> MappingOutcome:
    return MappingOutcome(content=None, quarantine=True, quarantine_reason=reason)


def _map_cohort(cohort: LegacyCohort) -> MappingOutcome:
    """Map one legacy cohort to orthogonal states or quarantine."""
    status = cohort.status
    item_type = cohort.item_type
    artifacts = cohort.artifacts

    if status is LegacyStatus.DISCOVERED:
        if artifacts is not ArtifactCohort.NONE:
            return _quarantine("discovered items must not have artifacts")
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.METADATA,
                analysis=AnalysisState.PENDING,
                preparation=PreparationState.NOT_QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            )
        )

    if status is LegacyStatus.FETCHED:
        if item_type is ItemType.PODCAST_EPISODE and artifacts is not ArtifactCohort.NONE:
            return _quarantine("fetched podcast episodes must not have artifacts")
        analysis = AnalysisState.READY if artifacts is ArtifactCohort.COMPLETE else AnalysisState.PENDING
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=analysis,
                preparation=PreparationState.NOT_QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            )
        )

    if status is LegacyStatus.CLASSIFIED:
        if artifacts is ArtifactCohort.NONE:
            return _quarantine("classified items must have transcript artifacts")
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.NOT_QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.PENDING,
        )

    if status is LegacyStatus.SELECTED:
        if item_type is ItemType.PODCAST_EPISODE:
            prep = PreparationState.READY if artifacts is ArtifactCohort.COMPLETE else PreparationState.QUEUED
            return MappingOutcome(
                content=ContentState(
                    fetch=FetchState.CONTENT_READY,
                    analysis=AnalysisState.READY,
                    preparation=prep,
                    playback=PlaybackState.UNPLAYED,
                    retention=_active_retention(),
                ),
                report_decision=ReportDecision.PENDING,
            )
        prep = PreparationState.READY if artifacts is ArtifactCohort.COMPLETE else PreparationState.QUEUED
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=prep,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.ACCEPTED,
        )

    if status is LegacyStatus.PROCESSING:
        if artifacts is ArtifactCohort.COMPLETE:
            prep = PreparationState.READY
        else:
            prep = PreparationState.QUEUED
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=prep,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.ACCEPTED if item_type is ItemType.ARTICLE else ReportDecision.PENDING,
        )

    if status is LegacyStatus.READY:
        if artifacts is not ArtifactCohort.COMPLETE:
            return _quarantine("ready items must have validated complete artifacts")
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.READY,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.ACCEPTED if item_type is ItemType.ARTICLE else ReportDecision.PENDING,
        )

    if status is LegacyStatus.COMPLETED:
        if artifacts is not ArtifactCohort.COMPLETE:
            return _quarantine("completed items must have validated complete artifacts")
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.READY,
                playback=PlaybackState.COMPLETED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.ACCEPTED if item_type is ItemType.ARTICLE else ReportDecision.PENDING,
        )

    if status is LegacyStatus.EXPIRED:
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.READY,
                playback=PlaybackState.UNPLAYED,
                retention=_expired_retention(keep=cohort.keep_override),
            ),
            report_decision=ReportDecision.DISMISSED,
        )

    if status is LegacyStatus.SKIPPED:
        return MappingOutcome(
            content=ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.NOT_QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            ),
            report_decision=ReportDecision.DISMISSED,
        )

    if status is LegacyStatus.ERROR:
        if artifacts is ArtifactCohort.NONE:
            fetch = FetchState.ERROR
            analysis = AnalysisState.PENDING
            prep = PreparationState.NOT_QUEUED
        elif artifacts is ArtifactCohort.PARTIAL:
            fetch = FetchState.CONTENT_READY
            analysis = AnalysisState.ERROR
            prep = PreparationState.NOT_QUEUED
        else:
            fetch = FetchState.CONTENT_READY
            analysis = AnalysisState.READY
            prep = PreparationState.ERROR
        return MappingOutcome(
            content=ContentState(
                fetch=fetch,
                analysis=analysis,
                preparation=prep,
                playback=PlaybackState.UNPLAYED,
                retention=_active_retention(),
            )
        )

    raise ValueError(f"Unhandled legacy status: {status}")


def all_legacy_cohorts() -> tuple[LegacyCohort, ...]:
    """Return every legacy cohort in the exhaustive truth table."""
    cohorts: list[LegacyCohort] = []
    for status in LegacyStatus:
        for item_type in ItemType:
            for artifacts in ArtifactCohort:
                if status is LegacyStatus.EXPIRED:
                    for keep in (False, True):
                        cohorts.append(
                            LegacyCohort(
                                status=status,
                                item_type=item_type,
                                artifacts=artifacts,
                                keep_override=keep,
                            )
                        )
                else:
                    cohorts.append(
                        LegacyCohort(
                            status=status,
                            item_type=item_type,
                            artifacts=artifacts,
                        )
                    )
    return tuple(cohorts)


# Precomputed authoritative table — one outcome per cohort.
_LEGACY_MAPPING_TABLE: dict[LegacyCohort, MappingOutcome] = {
    cohort: _map_cohort(cohort) for cohort in all_legacy_cohorts()
}


def map_legacy_cohort(cohort: LegacyCohort) -> MappingOutcome:
    """Return the authoritative mapping for one legacy cohort.

    Args:
        cohort: Legacy status/type/artifact cohort.

    Returns:
        :class:`MappingOutcome` with orthogonal states or quarantine.
    """
    try:
        return _LEGACY_MAPPING_TABLE[cohort]
    except KeyError as exc:
        raise KeyError(f"Unmapped legacy cohort: {cohort}") from exc
