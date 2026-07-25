"""Pure transition functions for ProcessingJob and runner lifecycle."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from wilted.background_work.contracts import (
    ProcessingJobState,
    ReportDecision,
    ReportItem,
    RetentionFacts,
    RetentionState,
)


class ProcessingJobTransitionError(ValueError):
    """Raised when a ProcessingJob CAS transition is not permitted."""


# Valid CAS edges for ProcessingJob.state. Terminal states have no outgoing edges.
_PROCESSING_JOB_TRANSITIONS: dict[ProcessingJobState, frozenset[ProcessingJobState]] = {
    ProcessingJobState.QUEUED: frozenset(
        {
            ProcessingJobState.RUNNING,
            ProcessingJobState.CANCELLED,
            ProcessingJobState.DEFERRED,
        }
    ),
    ProcessingJobState.RUNNING: frozenset(
        {
            ProcessingJobState.COMPLETED,
            ProcessingJobState.FAILED,
            ProcessingJobState.CANCELLED,
            ProcessingJobState.RETRY,
            ProcessingJobState.DEFERRED,
        }
    ),
    ProcessingJobState.RETRY: frozenset(
        {
            ProcessingJobState.RUNNING,
            ProcessingJobState.FAILED,
            ProcessingJobState.CANCELLED,
            ProcessingJobState.DEFERRED,
        }
    ),
    ProcessingJobState.DEFERRED: frozenset(
        {
            ProcessingJobState.QUEUED,
            ProcessingJobState.RUNNING,
            ProcessingJobState.CANCELLED,
        }
    ),
    ProcessingJobState.COMPLETED: frozenset(),
    ProcessingJobState.FAILED: frozenset(),
    ProcessingJobState.CANCELLED: frozenset(),
}


def is_valid_processing_job_transition(
    current: ProcessingJobState,
    target: ProcessingJobState,
) -> bool:
    """Return True if ``current`` may CAS-advance to ``target``."""
    return target in _PROCESSING_JOB_TRANSITIONS.get(current, frozenset())


def all_processing_job_transition_pairs() -> tuple[tuple[ProcessingJobState, ProcessingJobState, bool], ...]:
    """Return every distinct ``(current, target, valid)`` pair for contract tests."""
    states = list(ProcessingJobState)
    pairs: list[tuple[ProcessingJobState, ProcessingJobState, bool]] = []
    for current in states:
        for target in states:
            if current is target:
                continue
            pairs.append((current, target, is_valid_processing_job_transition(current, target)))
    return tuple(pairs)


def transition_processing_job(
    current: ProcessingJobState,
    target: ProcessingJobState,
) -> ProcessingJobState:
    """CAS-advance a job state or raise :class:`ProcessingJobTransitionError`.

    Args:
        current: Observed current state.
        target: Desired next state.

    Returns:
        ``target`` when the edge is valid.

    Raises:
        ProcessingJobTransitionError: When the edge is not in the contract table.
    """
    if not is_valid_processing_job_transition(current, target):
        raise ProcessingJobTransitionError(f"Invalid ProcessingJob transition: {current.value} -> {target.value}")
    return target


class CancellationOutcome(StrEnum):
    """Deterministic cancellation resolution for a running job."""

    COMPLETED = "completed"
    CANCELLED = "cancelled"


@dataclass(frozen=True, slots=True)
class CancelRequest:
    """CAS cancel-request flag observed by the runner at safe boundaries.

    Attributes:
        requested: Whether cancellation has been requested.
        observed_at: UTC ISO-8601 ``Z`` timestamp of the request.
    """

    requested: bool
    observed_at: str


# States where cancellation is immediate (job not actively executing).
_UNCLAIMED_JOB_STATES = frozenset(
    {
        ProcessingJobState.QUEUED,
        ProcessingJobState.RETRY,
        ProcessingJobState.DEFERRED,
    }
)


def cancel_job(state: ProcessingJobState) -> ProcessingJobState:
    """Cancel an unclaimed job immediately or mark a running job for cooperative stop.

    Unclaimed jobs (``queued``, ``retry``, ``deferred``) transition directly to
    ``cancelled``. A ``running`` job does not change state here — the caller
    sets a :class:`CancelRequest` and the runner observes it at safe boundaries.

    Args:
        state: Current job state.

    Returns:
        ``cancelled`` for unclaimed jobs, otherwise ``state`` unchanged.

    Raises:
        ProcessingJobTransitionError: When cancellation is not permitted.
    """
    if state in _UNCLAIMED_JOB_STATES:
        return transition_processing_job(state, ProcessingJobState.CANCELLED)
    if state is ProcessingJobState.RUNNING:
        return state
    raise ProcessingJobTransitionError(f"Cannot cancel job in terminal or non-cancellable state: {state.value}")


def reconcile_running_cancel(
    *,
    cancel_requested: bool,
    artifact_published: bool,
    artifact_valid: bool,
) -> CancellationOutcome:
    """Resolve a running cancellation race deterministically.

    When cancellation is requested at a safe boundary, a published and validated
    artifact completes the job; otherwise it is cancelled.

    Args:
        cancel_requested: Whether a cancel flag is set.
        artifact_published: Whether the handler published output bytes.
        artifact_valid: Whether published output passed manifest validation.

    Returns:
        :class:`CancellationOutcome` — ``completed`` when a valid artifact
        exists despite the cancel request, otherwise ``cancelled``.
    """
    if not cancel_requested:
        raise ValueError("reconcile_running_cancel requires cancel_requested=True")
    if artifact_published and artifact_valid:
        return CancellationOutcome.COMPLETED
    return CancellationOutcome.CANCELLED


class RunnerLifecycle(StrEnum):
    """Bounded runner process lifecycle positions."""

    IDLE = "idle"
    ACQUIRING_FLOCK = "acquiring_flock"
    BOOTSTRAPPING = "bootstrapping"
    CLAIMING = "claiming"
    HANDLING = "handling"
    PUBLISHING = "publishing"
    ACKNOWLEDGING = "acknowledging"
    RELEASING = "releasing"
    STOPPING = "stopping"
    YIELDING = "yielding"


@dataclass(frozen=True, slots=True)
class RunnerState:
    """Immutable runner lifecycle state with cooperative stop flag.

    Attributes:
        lifecycle: Current lifecycle position.
        stop_requested: Set on SIGTERM/SIGHUP; observed at item boundaries.
    """

    lifecycle: RunnerLifecycle = RunnerLifecycle.IDLE
    stop_requested: bool = False


_RUNNER_TRANSITIONS: dict[RunnerLifecycle, frozenset[RunnerLifecycle]] = {
    RunnerLifecycle.IDLE: frozenset({RunnerLifecycle.ACQUIRING_FLOCK}),
    RunnerLifecycle.ACQUIRING_FLOCK: frozenset({RunnerLifecycle.BOOTSTRAPPING, RunnerLifecycle.IDLE}),
    RunnerLifecycle.BOOTSTRAPPING: frozenset({RunnerLifecycle.CLAIMING, RunnerLifecycle.STOPPING}),
    RunnerLifecycle.CLAIMING: frozenset(
        {
            RunnerLifecycle.HANDLING,
            RunnerLifecycle.RELEASING,
            RunnerLifecycle.YIELDING,
            RunnerLifecycle.STOPPING,
        }
    ),
    RunnerLifecycle.HANDLING: frozenset(
        {
            RunnerLifecycle.PUBLISHING,
            RunnerLifecycle.RELEASING,
            RunnerLifecycle.STOPPING,
        }
    ),
    RunnerLifecycle.PUBLISHING: frozenset({RunnerLifecycle.ACKNOWLEDGING, RunnerLifecycle.STOPPING}),
    RunnerLifecycle.ACKNOWLEDGING: frozenset({RunnerLifecycle.RELEASING, RunnerLifecycle.STOPPING}),
    RunnerLifecycle.RELEASING: frozenset({RunnerLifecycle.CLAIMING, RunnerLifecycle.STOPPING, RunnerLifecycle.IDLE}),
    RunnerLifecycle.YIELDING: frozenset({RunnerLifecycle.RELEASING, RunnerLifecycle.STOPPING}),
    RunnerLifecycle.STOPPING: frozenset({RunnerLifecycle.IDLE}),
}


def is_valid_runner_transition(current: RunnerLifecycle, target: RunnerLifecycle) -> bool:
    """Return True if ``current`` may advance to ``target``."""
    return target in _RUNNER_TRANSITIONS.get(current, frozenset())


def all_runner_transition_pairs() -> tuple[tuple[RunnerLifecycle, RunnerLifecycle, bool], ...]:
    """Return every distinct ``(current, target, valid)`` pair for contract tests."""
    states = list(RunnerLifecycle)
    pairs: list[tuple[RunnerLifecycle, RunnerLifecycle, bool]] = []
    for current in states:
        for target in states:
            if current is target:
                continue
            pairs.append((current, target, is_valid_runner_transition(current, target)))
    return tuple(pairs)


def transition_runner(
    current: RunnerLifecycle,
    target: RunnerLifecycle,
) -> RunnerLifecycle:
    """Advance runner lifecycle or raise :class:`ProcessingJobTransitionError`.

    SIGTERM/SIGHUP set ``stop_requested`` on :class:`RunnerState` and the
    runner moves to ``stopping`` at the next item boundary rather than
    mid-handler.
    """
    allowed = _RUNNER_TRANSITIONS.get(current, frozenset())
    if target not in allowed:
        raise ProcessingJobTransitionError(f"Invalid Runner transition: {current.value} -> {target.value}")
    return target


_REPORT_DECISION_TRANSITIONS: dict[ReportDecision, frozenset[ReportDecision]] = {
    ReportDecision.PENDING: frozenset(
        {
            ReportDecision.ACCEPTED,
            ReportDecision.DEFERRED,
            ReportDecision.DISMISSED,
        }
    ),
    ReportDecision.DEFERRED: frozenset(
        {
            ReportDecision.ACCEPTED,
            ReportDecision.DISMISSED,
        }
    ),
    ReportDecision.ACCEPTED: frozenset(),
    ReportDecision.DISMISSED: frozenset(),
}


def is_valid_report_decision_transition(
    current: ReportDecision,
    target: ReportDecision,
) -> bool:
    """Return True if ``current`` may advance to ``target``."""
    return target in _REPORT_DECISION_TRANSITIONS.get(current, frozenset())


def transition_report_decision(
    current: ReportDecision,
    target: ReportDecision,
    *,
    defer_until: str | None = None,
) -> ReportDecision:
    """Advance a report-scoped user decision or raise :class:`ProcessingJobTransitionError`.

    ``accepted`` and ``dismissed`` are terminal. ``deferred`` requires a
    non-empty ``defer_until`` timestamp; other decisions forbid ``defer_until``.

    Args:
        current: Observed decision.
        target: Desired next decision.
        defer_until: UTC ISO-8601 ``Z`` deferral deadline when ``target`` is ``deferred``.

    Returns:
        ``target`` when the edge is valid and deferral constraints hold.

    Raises:
        ProcessingJobTransitionError: When the edge is not permitted.
        ValueError: When ``defer_until`` constraints are violated.
    """
    if not is_valid_report_decision_transition(current, target):
        raise ProcessingJobTransitionError(f"Invalid ReportDecision transition: {current.value} -> {target.value}")
    if target is ReportDecision.DEFERRED:
        if not defer_until:
            raise ValueError("defer_until is required when transitioning to deferred")
    elif defer_until is not None:
        raise ValueError("defer_until is only valid when decision is deferred")
    return target


_RETENTION_TRANSITIONS: dict[RetentionState, frozenset[RetentionState]] = {
    RetentionState.ACTIVE: frozenset({RetentionState.EXPIRED}),
    RetentionState.EXPIRED: frozenset(),
}


def is_valid_retention_transition(current: RetentionState, target: RetentionState) -> bool:
    """Return True if ``current`` may advance to ``target``."""
    return target in _RETENTION_TRANSITIONS.get(current, frozenset())


def transition_retention(
    facts: RetentionFacts,
    target: RetentionState,
    *,
    expires_at: str,
    now: str,
) -> RetentionFacts:
    """Advance retention state when ``expires_at`` has passed.

    ``keep_override`` prevents the expiry effect: an otherwise due ``active``
    item remains ``active`` with no ``expired_at`` recorded.

    Args:
        facts: Current retention facts.
        target: Desired next retention state.
        expires_at: UTC ISO-8601 ``Z`` timestamp when retention eligibility expires.
        now: Current UTC ISO-8601 ``Z`` timestamp for the transition check.

    Returns:
        Updated :class:`RetentionFacts` reflecting the transition.

    Raises:
        ProcessingJobTransitionError: When the edge is not permitted.
        ValueError: When timestamps are missing or inconsistent.
    """
    if not expires_at:
        raise ValueError("expires_at must be non-empty")
    if not now:
        raise ValueError("now must be non-empty")
    if not is_valid_retention_transition(facts.state, target):
        raise ProcessingJobTransitionError(f"Invalid Retention transition: {facts.state.value} -> {target.value}")
    if target is RetentionState.EXPIRED:
        if now < expires_at:
            raise ValueError("cannot expire retention before expires_at")
        if facts.keep_override:
            return RetentionFacts(state=RetentionState.ACTIVE, keep_override=True, expired_at=None)
        return RetentionFacts(state=RetentionState.EXPIRED, keep_override=False, expired_at=expires_at)
    return RetentionFacts(state=target, keep_override=facts.keep_override, expired_at=facts.expired_at)


def apply_report_regeneration(
    existing: tuple[ReportItem, ...],
    proposed_pending: tuple[ReportItem, ...],
    *,
    report_id: int,
) -> tuple[ReportItem, ...]:
    """Same-day report regeneration: replace pending-only membership.

    Decided rows (``accepted``, ``deferred``, ``dismissed``) are preserved.
    Still-``pending`` rows for ``report_id`` are replaced transactionally by
    ``proposed_pending``. Historical reports (other ``report_id`` values) are
    never modified.

    Args:
        existing: Current report membership rows across all reports.
        proposed_pending: New pending candidates for ``report_id``.
        report_id: Report being regenerated.

    Returns:
        Updated membership tuple with pending replacement applied.
    """
    preserved = tuple(
        row for row in existing if row.report_id != report_id or row.decision is not ReportDecision.PENDING
    )
    historical_other_reports = tuple(row for row in preserved if row.report_id != report_id)
    decided_same_report = tuple(
        row for row in preserved if row.report_id == report_id and row.decision is not ReportDecision.PENDING
    )

    decided_item_ids = {row.item_id for row in decided_same_report}

    for row in proposed_pending:
        if row.report_id != report_id:
            raise ValueError("proposed_pending rows must match report_id")
        if row.decision is not ReportDecision.PENDING:
            raise ValueError("proposed_pending rows must all be pending")
        if row.item_id in decided_item_ids:
            raise ValueError(
                f"proposed_pending item_id {row.item_id!r} already has a decided row for report_id={report_id}"
            )

    # Stable ordering: decided rows keep their ranks; pending rows come from proposal.
    new_pending = tuple(
        ReportItem(
            report_id=report_id,
            item_id=row.item_id,
            rank=row.rank,
            decision=ReportDecision.PENDING,
            defer_until=None,
        )
        for row in proposed_pending
    )
    return historical_other_reports + decided_same_report + new_pending
