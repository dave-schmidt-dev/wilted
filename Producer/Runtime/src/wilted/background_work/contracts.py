"""Immutable value objects for the background-work contract.

All types in this module are frozen dataclasses or enums. None import
anything outside the Python standard library.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class FetchState(StrEnum):
    """Whether durable content bytes exist for an item."""

    METADATA = "metadata"
    CONTENT_READY = "content_ready"
    ERROR = "error"


class AnalysisState(StrEnum):
    """Whether classification/analysis has completed."""

    PENDING = "pending"
    READY = "ready"
    ERROR = "error"


class PreparationState(StrEnum):
    """Whether playable media preparation has completed."""

    NOT_QUEUED = "not_queued"
    QUEUED = "queued"
    READY = "ready"
    ERROR = "error"


class PlaybackState(StrEnum):
    """User playback progress for prepared media."""

    UNPLAYED = "unplayed"
    PLAYING = "playing"
    PAUSED = "paused"
    COMPLETED = "completed"


class RetentionState(StrEnum):
    """Whether an item is eligible for retention-policy expiry."""

    ACTIVE = "active"
    EXPIRED = "expired"


class ReportDecision(StrEnum):
    """Report-scoped user decision — never mixed into content-state enums."""

    PENDING = "pending"
    ACCEPTED = "accepted"
    DEFERRED = "deferred"
    DISMISSED = "dismissed"


class ProcessingJobState(StrEnum):
    """Durable work-queue job lifecycle."""

    QUEUED = "queued"
    RUNNING = "running"
    RETRY = "retry"
    DEFERRED = "deferred"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class JobKind(StrEnum):
    """Typed background-work handler kinds."""

    DISCOVER = "discover"
    CLASSIFY = "classify"
    PREPARE = "prepare"
    ARTICLE_CACHE = "article_cache"
    REPORT_ASSEMBLY = "report_assembly"
    COMPACT_BRIEFING = "compact_briefing"


class SubmissionOutcome(StrEnum):
    """Truthful submission vocabulary for CLI/TUI/launchd surfaces."""

    SUBMITTED = "submitted"
    COMPLETED = "completed"
    PARTIAL = "partial"
    FAILED = "failed"
    BUSY = "busy"


@dataclass(frozen=True, slots=True)
class RetentionFacts:
    """Retention eligibility with explicit keep override.

    Attributes:
        state: Active or expired retention classification.
        keep_override: When True, an otherwise expired item remains active.
        expired_at: UTC ISO-8601 ``Z`` timestamp when retention expired, if any.
    """

    state: RetentionState
    keep_override: bool = False
    expired_at: str | None = None

    def __post_init__(self) -> None:
        if self.keep_override and self.state is RetentionState.EXPIRED:
            raise ValueError("RetentionFacts cannot be expired with keep_override=True")


@dataclass(frozen=True, slots=True)
class ContentState:
    """Orthogonal durable facts about one item's pipeline position."""

    fetch: FetchState
    analysis: AnalysisState
    preparation: PreparationState
    playback: PlaybackState
    retention: RetentionFacts


@dataclass(frozen=True, slots=True)
class ReportItem:
    """One report membership row with presentation order and user decision.

    Replaces the legacy ``SelectionHistory`` concept with a single
    report/item association.

    Attributes:
        report_id: Owning report identifier.
        item_id: Stable durable item identifier (INV-3).
        rank: Presentation order within the report (lower = earlier).
        decision: Report-scoped user decision.
        defer_until: Optional UTC ISO-8601 ``Z`` deferral deadline.
    """

    report_id: int
    item_id: str
    rank: int
    decision: ReportDecision
    defer_until: str | None = None

    def __post_init__(self) -> None:
        if not self.item_id:
            raise ValueError("ReportItem.item_id must be non-empty")
        if self.rank < 0:
            raise ValueError(f"ReportItem.rank must be >= 0, got {self.rank}")
        if self.decision is not ReportDecision.DEFERRED and self.defer_until is not None:
            raise ValueError("defer_until is only valid when decision is deferred")


@dataclass(frozen=True, slots=True)
class ProcessingJobLease:
    """Observability lease for a claimed job — OS flock is execution authority.

    Attributes:
        owner_id: Opaque runner identity (e.g. PID-derived string).
        expires_at: UTC ISO-8601 ``Z`` lease expiry for stale-running evidence.
    """

    owner_id: str
    expires_at: str

    def __post_init__(self) -> None:
        if not self.owner_id:
            raise ValueError("ProcessingJobLease.owner_id must be non-empty")
        if not self.expires_at:
            raise ValueError("ProcessingJobLease.expires_at must be non-empty")


@dataclass(frozen=True, slots=True)
class ArtifactManifest:
    """Validated handler output metadata for retry reconciliation.

    Attributes:
        item_id: Stable item identity, if item-scoped.
        source_id: Feed/source identity, if source-scoped.
        input_digest: SHA-256 hex digest of canonical handler inputs.
        operation_version: Integer bumped when handler semantics change.
        model_identity: Model name/checkpoint id, when applicable.
        prompt_identity: Prompt template id/version, when applicable.
        output_digests: Tuple of SHA-256 hex digests for published outputs.
        completeness_checks: Tuple of named checks that all passed.
    """

    item_id: str | None = None
    source_id: str | None = None
    input_digest: str = ""
    operation_version: int = 1
    model_identity: str | None = None
    prompt_identity: str | None = None
    output_digests: tuple[str, ...] = field(default_factory=tuple)
    completeness_checks: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if self.operation_version < 1:
            raise ValueError("ArtifactManifest.operation_version must be >= 1")
        if not self.item_id and not self.source_id:
            raise ValueError("ArtifactManifest requires item_id and/or source_id")
        if not self.input_digest:
            raise ValueError("ArtifactManifest.input_digest must be non-empty")
        if not self.output_digests:
            raise ValueError("ArtifactManifest.output_digests must be non-empty (INV-4)")
        if not self.completeness_checks:
            raise ValueError("ArtifactManifest.completeness_checks must be non-empty")

    @property
    def is_complete(self) -> bool:
        """True when output digests and completeness checks are both present."""
        return bool(self.output_digests) and bool(self.completeness_checks)
