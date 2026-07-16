"""Bounded scheduler tick — DNS preflight, flock, due check, batch drain.

One tick acquires the per-``DATA_DIR`` Python ``fcntl`` runner lock, checks
persisted due state, drains at most :data:`~wilted.background_work.scheduler.MAX_JOBS_PER_TICK`
jobs via :class:`~wilted.pipeline_runner.PipelineRunner`, releases the lock, and
exits. Shell wrappers must not use ``flock``; locking stays in Python only.
"""

from __future__ import annotations

import logging
import socket
from dataclasses import dataclass
from typing import TYPE_CHECKING

import wilted
from wilted.background_work.scheduler import (
    MAX_JOBS_PER_TICK,
    SchedulerTickOutcome,
    resolve_scheduler_tick_outcome,
)
from wilted.pipeline_runner import PipelineRunner, RunExitReason
from wilted.processing_jobs import ExecutionLockBusy, count_due_jobs, try_acquire_execution_lock
from wilted.station_runtime.coordinator import RuntimeBootstrap

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

logger = logging.getLogger(__name__)

_DEFAULT_DNS_HOST = "one.one.one.one"
_DEFAULT_DNS_PORT = 53
_DEFAULT_OWNER_PREFIX = "scheduler"


@dataclass(frozen=True, slots=True)
class SchedulerTickResult:
    """Outcome of one bounded scheduler tick."""

    outcome: SchedulerTickOutcome
    exit_code: int
    jobs_due: int = 0
    jobs_ran: int = 0


def exit_code_for_outcome(outcome: SchedulerTickOutcome) -> int:
    """Map a terminal tick outcome to a process exit code."""
    if outcome is SchedulerTickOutcome.CHILD_FAILED:
        return 1
    if outcome is SchedulerTickOutcome.DNS_UNAVAILABLE:
        return 2
    if outcome is SchedulerTickOutcome.STOPPED:
        return 130
    return 0


def check_dns_available(
    *,
    host: str = _DEFAULT_DNS_HOST,
    port: int = _DEFAULT_DNS_PORT,
    resolver: Callable[[str, int], None] | None = None,
) -> bool:
    """Return True when a bounded DNS/socket preflight succeeds."""
    probe = resolver or (lambda resolved_host, resolved_port: socket.getaddrinfo(resolved_host, resolved_port))
    try:
        probe(host, port)
        return True
    except OSError:
        logger.warning("Scheduler DNS preflight failed for %s:%s", host, port)
        return False


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _default_owner_id() -> str:
    import os

    return f"{_DEFAULT_OWNER_PREFIX}-{os.getpid()}"


def run_scheduler_tick(
    *,
    data_dir: Path | None = None,
    owner_id: str | None = None,
    stop_requested: bool = False,
    dns_check: Callable[[], bool] | None = None,
    runner_factory: Callable[[], PipelineRunner] | None = None,
) -> SchedulerTickResult:
    """Execute one bounded scheduler tick.

    Args:
        data_dir: Optional data directory override (defaults to live ``wilted.DATA_DIR``).
        owner_id: Opaque scheduler identity recorded on claimed leases.
        stop_requested: Cooperative stop before side effects (tests/signals).
        dns_check: Optional DNS preflight seam for tests.
        runner_factory: Optional :class:`PipelineRunner` factory seam for tests.

    Returns:
        :class:`SchedulerTickResult` with terminal outcome and exit code.
    """
    resolved_dir = data_dir if data_dir is not None else wilted.DATA_DIR
    resolved_owner = owner_id or _default_owner_id()
    dns_available = check_dns_available() if dns_check is None else dns_check()

    if stop_requested:
        outcome = resolve_scheduler_tick_outcome(
            lock_acquired=False,
            dns_available=dns_available,
            jobs_due=0,
            jobs_ran=0,
            stop_requested=True,
        )
        return SchedulerTickResult(outcome=outcome, exit_code=exit_code_for_outcome(outcome))

    if not dns_available:
        outcome = SchedulerTickOutcome.DNS_UNAVAILABLE
        return SchedulerTickResult(outcome=outcome, exit_code=exit_code_for_outcome(outcome))

    jobs_due = 0
    jobs_ran = 0
    child_failed = False

    try:
        with try_acquire_execution_lock(resolved_dir):
            jobs_due = count_due_jobs()
            if jobs_due <= 0:
                outcome = resolve_scheduler_tick_outcome(
                    lock_acquired=True,
                    dns_available=True,
                    jobs_due=0,
                    jobs_ran=0,
                )
                return SchedulerTickResult(
                    outcome=outcome,
                    exit_code=exit_code_for_outcome(outcome),
                    jobs_due=0,
                    jobs_ran=0,
                )

            runner = (
                runner_factory()
                if runner_factory is not None
                else PipelineRunner(
                    data_dir=resolved_dir,
                    max_jobs_per_run=MAX_JOBS_PER_TICK,
                    bootstrap=_ready_bootstrap(),
                )
            )
            run_result = runner.run_assuming_lock_held(owner_id=resolved_owner)
            jobs_ran = run_result.stats.submitted_handled
            child_failed = run_result.stats.failed > 0 or run_result.exit_reason is RunExitReason.ERROR

            if run_result.exit_reason is RunExitReason.STOPPED:
                outcome = SchedulerTickOutcome.STOPPED
            elif child_failed:
                outcome = SchedulerTickOutcome.CHILD_FAILED
            else:
                outcome = resolve_scheduler_tick_outcome(
                    lock_acquired=True,
                    dns_available=True,
                    jobs_due=jobs_due,
                    jobs_ran=jobs_ran,
                    child_failed=child_failed,
                )
            return SchedulerTickResult(
                outcome=outcome,
                exit_code=exit_code_for_outcome(outcome),
                jobs_due=jobs_due,
                jobs_ran=jobs_ran,
            )
    except ExecutionLockBusy:
        outcome = resolve_scheduler_tick_outcome(
            lock_acquired=False,
            dns_available=True,
            jobs_due=count_due_jobs(),
            jobs_ran=0,
        )
        return SchedulerTickResult(
            outcome=outcome,
            exit_code=exit_code_for_outcome(outcome),
            jobs_due=count_due_jobs(),
            jobs_ran=0,
        )
