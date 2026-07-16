"""Scheduler tick contract — bounded due check, lock, batch drain, exit.

One scheduler tick acquires the per-``DATA_DIR`` ``fcntl`` runner lock, checks
persisted due state, drains at most :data:`MAX_JOBS_PER_TICK` jobs, releases
the lock, and exits. No orphan child process may survive tick exit.
"""

from __future__ import annotations

from enum import StrEnum

from wilted.background_work.transitions import ProcessingJobTransitionError


class SchedulerTickOutcome(StrEnum):
    """Terminal outcome vocabulary for one bounded scheduler tick."""

    NOTHING_DUE = "nothing_due"
    RAN_BATCH = "ran_batch"
    LOCK_BUSY = "lock_busy"
    DNS_UNAVAILABLE = "dns_unavailable"
    CHILD_FAILED = "child_failed"
    STOPPED = "stopped"


MAX_JOBS_PER_TICK = 8


class SchedulerTickPhase(StrEnum):
    """Ordered phases within one scheduler tick."""

    ACQUIRE_LOCK = "acquire_lock"
    CHECK_DUE = "check_due"
    DRAIN_BATCH = "drain_batch"
    RELEASE = "release"


_SCHEDULER_TICK_PHASE_TRANSITIONS: dict[SchedulerTickPhase, frozenset[SchedulerTickPhase]] = {
    SchedulerTickPhase.ACQUIRE_LOCK: frozenset({SchedulerTickPhase.CHECK_DUE, SchedulerTickPhase.RELEASE}),
    SchedulerTickPhase.CHECK_DUE: frozenset({SchedulerTickPhase.DRAIN_BATCH, SchedulerTickPhase.RELEASE}),
    SchedulerTickPhase.DRAIN_BATCH: frozenset({SchedulerTickPhase.RELEASE}),
    SchedulerTickPhase.RELEASE: frozenset(),
}


def is_valid_scheduler_tick_phase_transition(
    current: SchedulerTickPhase,
    target: SchedulerTickPhase,
) -> bool:
    """Return True if ``current`` may advance to ``target`` within one tick."""
    return target in _SCHEDULER_TICK_PHASE_TRANSITIONS.get(current, frozenset())


def transition_scheduler_tick_phase(
    current: SchedulerTickPhase,
    target: SchedulerTickPhase,
) -> SchedulerTickPhase:
    """Advance scheduler tick phase or raise :class:`ProcessingJobTransitionError`."""
    if not is_valid_scheduler_tick_phase_transition(current, target):
        raise ProcessingJobTransitionError(f"Invalid SchedulerTick phase transition: {current.value} -> {target.value}")
    return target


def bounded_batch_size(jobs_due: int) -> int:
    """Return the number of jobs a tick may drain (``0 .. MAX_JOBS_PER_TICK``)."""
    if jobs_due < 0:
        raise ValueError("jobs_due must be >= 0")
    return min(jobs_due, MAX_JOBS_PER_TICK)


def resolve_scheduler_tick_outcome(
    *,
    lock_acquired: bool,
    dns_available: bool,
    jobs_due: int,
    jobs_ran: int,
    child_failed: bool = False,
    stop_requested: bool = False,
) -> SchedulerTickOutcome:
    """Resolve the terminal outcome for one scheduler tick from boundary inputs.

    Contract order:
        1. Cooperative stop wins before side effects.
        2. DNS must be available before lock/drain work.
        3. Lock busy is observable without consuming due jobs.
        4. Nothing due exits cheaply after lock acquisition.
        5. Any child failure during drain is reported truthfully.

    Args:
        lock_acquired: Whether the per-``DATA_DIR`` ``fcntl`` lock was acquired.
        dns_available: Whether bounded DNS preflight succeeded.
        jobs_due: Count of persisted due jobs at check time.
        jobs_ran: Count of jobs actually drained this tick (``<= bounded_batch_size(jobs_due)``).
        child_failed: Whether a runner child exited non-zero during drain.
        stop_requested: Whether SIGTERM/SIGHUP requested stop before drain.

    Returns:
        Terminal :class:`SchedulerTickOutcome` for the tick.
    """
    if stop_requested:
        return SchedulerTickOutcome.STOPPED
    if not dns_available:
        return SchedulerTickOutcome.DNS_UNAVAILABLE
    if not lock_acquired:
        return SchedulerTickOutcome.LOCK_BUSY
    if jobs_due <= 0:
        return SchedulerTickOutcome.NOTHING_DUE
    if child_failed:
        return SchedulerTickOutcome.CHILD_FAILED
    if jobs_ran <= 0:
        return SchedulerTickOutcome.NOTHING_DUE
    return SchedulerTickOutcome.RAN_BATCH
