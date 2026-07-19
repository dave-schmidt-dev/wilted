"""Bounded pipeline runner — one flock, one coordinator, per-job isolation.

Task 5.1 routes classify/prepare through real handlers. Callers must initialize
:class:`~wilted.station_runtime.coordinator.RuntimeBootstrap` on the main
thread before :meth:`PipelineRunner.run` (``init_tqdm_lock()`` then
``require_ready()``).
"""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Any

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.background_work.transitions import transition_processing_job
from wilted.db import ProcessingJob, ensure_db, now_utc
from wilted.execution_capability import (
    _RUNNER_ISSUER,
    clear_execution_capability,
    create_model_coordinator,
    issue_execution_capability,
)
from wilted.handlers import (
    handle_article_cache,
    handle_briefing,
    handle_classify,
    handle_discover,
    handle_prepare,
    handle_report,
)
from wilted.processing_jobs import (
    ExecutionLockBusy,
    _claim_next_job_under_lock,
    apply_running_cancel,
    recover_stale_jobs,
    redact_metadata,
    try_acquire_execution_lock,
)
from wilted.station_runtime.coordinator import ModelCoordinator, RuntimeBootstrap

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

    from wilted.db import ProcessingJob as ProcessingJobModel

logger = logging.getLogger(__name__)

_DEFAULT_LEASE_SECONDS = 300
_STATION_ACTIVE_ENV = "WILTED_STATION_ACTIVE"


class RunExitReason(StrEnum):
    """Terminal exit vocabulary for one bounded runner invocation."""

    COMPLETED = "completed"
    LOCK_BUSY = "lock_busy"
    STOPPED = "stopped"
    ERROR = "error"
    DEFERRED_YIELD = "deferred_yield"


@dataclass(frozen=True, slots=True)
class RunStats:
    """Per-run counters surfaced to CLI/TUI/launchd callers."""

    submitted_handled: int = 0
    failed: int = 0
    cancelled: int = 0
    deferred_yield: int = 0


@dataclass(frozen=True, slots=True)
class RunResult:
    """Outcome of one bounded :meth:`PipelineRunner.run` invocation."""

    stats: RunStats
    exit_reason: RunExitReason


@dataclass
class _MutableRunStats:
    submitted_handled: int = 0
    failed: int = 0
    cancelled: int = 0
    deferred_yield: int = 0

    def freeze(self) -> RunStats:
        return RunStats(
            submitted_handled=self.submitted_handled,
            failed=self.failed,
            cancelled=self.cancelled,
            deferred_yield=self.deferred_yield,
        )


def is_station_active() -> bool:
    """Return True when foreground station work owns the yield seam.

    Production uses ``WILTED_STATION_ACTIVE=1`` as an explicit override.
    Tests inject a callable on :class:`PipelineRunner` instead.
    """
    return os.environ.get(_STATION_ACTIVE_ENV) == "1"


def _default_owner_id() -> str:
    return f"runner-{os.getpid()}"


def _stub_handler(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Typed placeholder until Task 5.2 routes remaining stage handlers."""
    logger.info(
        "Stub processing handler for kind=%s job_id=%s (coordinator=%s)",
        job.kind,
        job.id,
        id(coordinator),
    )


HANDLERS: dict[JobKind, Callable[[ProcessingJobModel, ModelCoordinator], None]] = {
    JobKind.DISCOVER: handle_discover,
    JobKind.CLASSIFY: handle_classify,
    JobKind.PREPARE: handle_prepare,
    JobKind.ARTICLE_CACHE: handle_article_cache,
    JobKind.REPORT_ASSEMBLY: handle_report,
    JobKind.COMPACT_BRIEFING: handle_briefing,
}


def _encode_error_json(exc: BaseException) -> str:
    payload = redact_metadata(
        {
            "error_type": type(exc).__name__,
            "message": str(exc),
        },
    )
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)


def _record_handler_failure(job_id: int, owner_id: str, exc: BaseException) -> ProcessingJobState:
    """CAS-advance a running job to retry or failed after a handler exception."""
    ensure_db()
    job = ProcessingJob.get_or_none(ProcessingJob.id == job_id)
    if job is None or job.state != ProcessingJobState.RUNNING.value or job.lease_owner != owner_id:
        raise ValueError(f"job {job_id} is not a running job owned by {owner_id!r}")

    target = ProcessingJobState.FAILED if job.attempt_count >= job.max_attempts else ProcessingJobState.RETRY
    transition_processing_job(ProcessingJobState.RUNNING, target)
    now = now_utc()
    error_json = _encode_error_json(exc)
    updated = (
        ProcessingJob.update(
            state=target.value,
            updated_at=now,
            completed_at=now if target is ProcessingJobState.FAILED else None,
            error_json=error_json,
            lease_owner=None,
            lease_expires_at=None,
            started_at=None if target is ProcessingJobState.RETRY else job.started_at,
        )
        .where(
            (ProcessingJob.id == job_id)
            & (ProcessingJob.state == ProcessingJobState.RUNNING.value)
            & (ProcessingJob.lease_owner == owner_id),
        )
        .execute()
    )
    if updated != 1:
        raise ValueError(f"failed to record handler failure for job {job_id}")
    return target


def _reconcile_cancelled_job(job_id: int) -> bool:
    """Apply a cooperative running cancel at a job boundary."""
    try:
        terminal = apply_running_cancel(job_id, artifact_complete=False)
    except ValueError:
        return False
    return terminal is ProcessingJobState.CANCELLED


class PipelineRunner:
    """One bounded drain of the durable processing-job ledger."""

    def __init__(
        self,
        *,
        data_dir: Path | None = None,
        max_jobs_per_run: int = 8,
        station_active_check: Callable[[], bool] | None = None,
        bootstrap: RuntimeBootstrap | None = None,
        coordinator_factory: Callable[[RuntimeBootstrap], ModelCoordinator] | None = None,
        handlers: dict[JobKind, Callable[[ProcessingJobModel, ModelCoordinator], None]] | None = None,
    ) -> None:
        if max_jobs_per_run <= 0:
            raise ValueError(f"max_jobs_per_run must be > 0, got {max_jobs_per_run}")
        self._data_dir = data_dir
        self._max_jobs_per_run = max_jobs_per_run
        self._station_active_check = station_active_check
        self._bootstrap = bootstrap
        self._coordinator_factory = coordinator_factory
        self._handlers = handlers if handlers is not None else HANDLERS
        self._stop_requested = False
        self._stop_lock = threading.Lock()

    def inject_stop(self) -> None:
        """Test seam mirroring SIGTERM/SIGHUP cooperative stop."""
        with self._stop_lock:
            self._stop_requested = True

    def _stop_flag(self) -> bool:
        with self._stop_lock:
            return self._stop_requested

    def _resolve_data_dir(self) -> Path:
        return self._data_dir if self._data_dir is not None else wilted.DATA_DIR

    def _station_active(self) -> bool:
        if self._station_active_check is not None:
            return self._station_active_check()
        return is_station_active()

    def run(self, *, owner_id: str | None = None) -> RunResult:
        """Acquire the execution flock, drain up to ``max_jobs_per_run`` jobs, release.

        Requires ``RuntimeBootstrap.init_tqdm_lock()`` to have already run on the
        main thread (the runner only ``require_ready()``-checks it here — INV-1).
        May itself be called from a worker thread: signal handlers are installed
        only when running on the main thread (``_install_signal_handlers`` no-ops
        off-main, since ``signal.signal()`` is main-thread-only), so the TUI
        article-cache drain can invoke this from its ``@work(thread=True)`` worker.

        Args:
            owner_id: Opaque runner identity recorded on claimed leases.

        Returns:
            :class:`RunResult` with per-run stats and a terminal exit reason.
        """
        resolved_owner = owner_id or _default_owner_id()
        if not resolved_owner:
            raise ValueError("owner_id must be non-empty")

        stats = _MutableRunStats()
        data_dir = self._resolve_data_dir()

        try:
            with try_acquire_execution_lock(data_dir):
                return self._run_under_lock(
                    data_dir=data_dir,
                    owner_id=resolved_owner,
                    stats=stats,
                )
        except ExecutionLockBusy:
            logger.info("Processing runner lock busy for %s", data_dir)
            return RunResult(stats=stats.freeze(), exit_reason=RunExitReason.LOCK_BUSY)
        except Exception:
            logger.exception("Processing runner failed for %s", data_dir)
            return RunResult(stats=stats.freeze(), exit_reason=RunExitReason.ERROR)

    def run_assuming_lock_held(self, *, owner_id: str | None = None) -> RunResult:
        """Drain jobs while the per-``DATA_DIR`` execution flock is already held.

        Used by :mod:`wilted.scheduler_tick` so the tick owns one lock acquisition
        for the due-check and bounded drain phases.
        """
        resolved_owner = owner_id or _default_owner_id()
        if not resolved_owner:
            raise ValueError("owner_id must be non-empty")

        stats = _MutableRunStats()
        data_dir = self._resolve_data_dir()
        try:
            return self._run_under_lock(
                data_dir=data_dir,
                owner_id=resolved_owner,
                stats=stats,
            )
        except Exception:
            logger.exception("Processing runner failed while holding lock for %s", data_dir)
            return RunResult(stats=stats.freeze(), exit_reason=RunExitReason.ERROR)

    def _run_under_lock(
        self,
        *,
        data_dir: Path,
        owner_id: str,
        stats: _MutableRunStats,
    ) -> RunResult:
        bootstrap = self._bootstrap or RuntimeBootstrap()
        bootstrap.require_ready()

        issue_execution_capability(owner_id, data_dir, _issuer=_RUNNER_ISSUER)
        coordinator_factory = self._coordinator_factory or (
            lambda resolved_bootstrap: create_model_coordinator(bootstrap=resolved_bootstrap)
        )
        coordinator: ModelCoordinator | None = None
        previous_handlers = self._install_signal_handlers()
        exit_reason = RunExitReason.COMPLETED

        try:
            coordinator = coordinator_factory(bootstrap)
            now = now_utc()
            recovered = recover_stale_jobs(data_dir=data_dir, owner_id=owner_id, now=now)
            if recovered:
                logger.info("Recovered %s stale processing job(s) before drain", recovered)

            for _ in range(self._max_jobs_per_run):
                if self._stop_flag():
                    exit_reason = RunExitReason.STOPPED
                    break

                if self._station_active():
                    stats.deferred_yield += 1
                    exit_reason = RunExitReason.DEFERRED_YIELD
                    break

                job = _claim_next_job_under_lock(owner_id=owner_id, lease_seconds=_DEFAULT_LEASE_SECONDS)
                if job is None:
                    break

                self._handle_claimed_job(job, owner_id=owner_id, coordinator=coordinator, stats=stats)

                if self._stop_flag():
                    exit_reason = RunExitReason.STOPPED
                    break

            return RunResult(stats=stats.freeze(), exit_reason=exit_reason)
        except Exception:
            logger.exception("Processing runner failed while holding lock for %s", data_dir)
            return RunResult(stats=stats.freeze(), exit_reason=RunExitReason.ERROR)
        finally:
            self._restore_signal_handlers(previous_handlers)
            if coordinator is not None:
                coordinator.close()
            clear_execution_capability()

    def _handle_claimed_job(
        self,
        job: ProcessingJobModel,
        *,
        owner_id: str,
        coordinator: ModelCoordinator,
        stats: _MutableRunStats,
    ) -> None:
        if _reconcile_cancelled_job(job.id):
            stats.cancelled += 1
            return

        handler = self._handlers.get(JobKind(job.kind))
        if handler is None:
            exc = ValueError(f"No handler registered for job kind {job.kind!r}")
            logger.error("Missing handler for job %s kind=%s", job.id, job.kind)
            _record_handler_failure(job.id, owner_id, exc)
            stats.failed += 1
            return

        try:
            handler(job, coordinator)
        except Exception as exc:
            logger.exception("Handler failed for processing job %s", job.id)
            try:
                _record_handler_failure(job.id, owner_id, exc)
            except Exception:
                logger.exception("Failed to record handler failure for job %s", job.id)
            stats.failed += 1
            return

        if _reconcile_cancelled_job(job.id):
            stats.cancelled += 1
            return

        stats.submitted_handled += 1

    def _install_signal_handlers(self) -> dict[int, Any]:
        previous: dict[int, Any] = {}

        # ``signal.signal()`` only works on the main thread. The TUI drains the
        # article-cache runner from a Textual worker thread (the BUG-2 UI-freeze
        # fix): there, process-level SIGTERM/SIGHUP are already owned by the
        # main thread's own handlers (see ``cli._launch_tui``) and the drain is
        # stopped cooperatively via ``worker.is_cancelled`` / the
        # ``station_active_check`` yield seam, so installing here is neither
        # possible nor needed. Off-main, ``signal.signal`` raises ``ValueError``;
        # skip it and return an empty map (restore then no-ops). CLI and
        # scheduler-tick callers run on their own main thread and are unaffected.
        if threading.current_thread() is not threading.main_thread():
            return previous

        def _request_stop(signum: int, _frame: Any) -> None:
            logger.warning("Processing runner received stop signal %s", signum)
            self.inject_stop()

        for sig in (signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, _request_stop)
        return previous

    def _restore_signal_handlers(self, previous: dict[int, Any]) -> None:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
