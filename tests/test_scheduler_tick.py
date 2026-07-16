"""Tests for bounded scheduler tick (Task 6.1)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

import wilted
from wilted.background_work.contracts import JobKind
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.background_work.scheduler import SchedulerTickOutcome
from wilted.pipeline_runner import PipelineRunner
from wilted.processing_jobs import count_due_jobs, submit_job, try_acquire_execution_lock
from wilted.scheduler_tick import (
    SchedulerTickResult,
    check_dns_available,
    exit_code_for_outcome,
    run_scheduler_tick,
)
from wilted.station_runtime.coordinator import RuntimeBootstrap

pytestmark = pytest.mark.integration


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _submit_queued(*, item_id: str, kind: JobKind = JobKind.CLASSIFY) -> int:
    identity = logical_identity_for_kind(kind, item_id=item_id)
    key = build_idempotency_key(kind, operation_version=1, logical_identity=identity)
    return submit_job(key).job_id


class TestSchedulerTickHelpers:
    def test_exit_code_mapping(self) -> None:
        assert exit_code_for_outcome(SchedulerTickOutcome.NOTHING_DUE) == 0
        assert exit_code_for_outcome(SchedulerTickOutcome.RAN_BATCH) == 0
        assert exit_code_for_outcome(SchedulerTickOutcome.LOCK_BUSY) == 0
        assert exit_code_for_outcome(SchedulerTickOutcome.DNS_UNAVAILABLE) == 2
        assert exit_code_for_outcome(SchedulerTickOutcome.CHILD_FAILED) == 1
        assert exit_code_for_outcome(SchedulerTickOutcome.STOPPED) == 130

    def test_dns_preflight_success_and_failure(self) -> None:
        assert check_dns_available(resolver=lambda _host, _port: None) is True
        assert check_dns_available(resolver=lambda _host, _port: (_ for _ in ()).throw(OSError("dns down"))) is False


class TestSchedulerTickRun:
    def test_nothing_due_exits_without_runner(self, monkeypatch) -> None:
        runner = MagicMock()
        monkeypatch.setattr("wilted.scheduler_tick.PipelineRunner", lambda **kwargs: runner)

        result = run_scheduler_tick(data_dir=wilted.DATA_DIR, dns_check=lambda: True)

        assert result.outcome is SchedulerTickOutcome.NOTHING_DUE
        assert result.exit_code == 0
        runner.run_assuming_lock_held.assert_not_called()

    def test_dns_unavailable_skips_lock_and_runner(self, monkeypatch) -> None:
        runner = MagicMock()
        monkeypatch.setattr("wilted.scheduler_tick.PipelineRunner", lambda **kwargs: runner)

        result = run_scheduler_tick(data_dir=wilted.DATA_DIR, dns_check=lambda: False)

        assert result.outcome is SchedulerTickOutcome.DNS_UNAVAILABLE
        assert result.exit_code == 2
        runner.run_assuming_lock_held.assert_not_called()

    def test_lock_busy_when_execution_flock_held(self) -> None:
        _submit_queued(item_id="scheduler-lock-busy")
        with try_acquire_execution_lock(wilted.DATA_DIR):
            result = run_scheduler_tick(data_dir=wilted.DATA_DIR, dns_check=lambda: True)

        assert result.outcome is SchedulerTickOutcome.LOCK_BUSY
        assert result.exit_code == 0
        assert count_due_jobs() >= 1

    def test_drains_due_jobs_under_lock(self) -> None:
        job_id = _submit_queued(item_id="scheduler-drain")
        handled: list[int] = []

        def _complete(job, coordinator) -> None:
            handled.append(job.id)

        runner = PipelineRunner(
            data_dir=wilted.DATA_DIR,
            max_jobs_per_run=8,
            bootstrap=_ready_bootstrap(),
            handlers={JobKind.CLASSIFY: _complete},
        )

        result = run_scheduler_tick(
            data_dir=wilted.DATA_DIR,
            dns_check=lambda: True,
            runner_factory=lambda: runner,
        )

        assert result.outcome is SchedulerTickOutcome.RAN_BATCH
        assert result.jobs_ran == 1
        assert handled == [job_id]

    def test_child_failure_maps_to_nonzero_exit(self) -> None:
        _submit_queued(item_id="scheduler-child-fail")

        def _fail(job, coordinator) -> None:
            raise RuntimeError("handler failed")

        runner = PipelineRunner(
            data_dir=wilted.DATA_DIR,
            max_jobs_per_run=8,
            bootstrap=_ready_bootstrap(),
            handlers={JobKind.CLASSIFY: _fail},
        )

        result = run_scheduler_tick(
            data_dir=wilted.DATA_DIR,
            dns_check=lambda: True,
            runner_factory=lambda: runner,
        )

        assert result.outcome is SchedulerTickOutcome.CHILD_FAILED
        assert result.exit_code == 1

    def test_stop_requested_before_side_effects(self) -> None:
        result = run_scheduler_tick(
            data_dir=wilted.DATA_DIR,
            stop_requested=True,
            dns_check=lambda: False,
        )

        assert result.outcome is SchedulerTickOutcome.STOPPED
        assert result.exit_code == 130


_PROJECT_ROOT = Path(__file__).resolve().parent.parent


class TestSchedulerCliAndWrapper:
    def test_cmd_scheduler_tick_reaches_runner(self, monkeypatch, capsys) -> None:
        from wilted.cli import cmd_scheduler

        expected = SchedulerTickResult(
            outcome=SchedulerTickOutcome.NOTHING_DUE,
            exit_code=0,
            jobs_due=0,
            jobs_ran=0,
        )
        monkeypatch.setattr("wilted.scheduler_tick.run_scheduler_tick", lambda **kwargs: expected)

        with pytest.raises(SystemExit) as exc:
            cmd_scheduler(["tick"])

        assert exc.value.code == 0
        assert "outcome=nothing_due" in capsys.readouterr().out

    def test_scheduler_wrapper_has_no_shell_flock(self) -> None:
        script = (_PROJECT_ROOT / "scripts" / "wilted-scheduler.sh").read_text(encoding="utf-8")
        assert "flock -n" not in script
        assert "exec 200>" not in script
        assert "scheduler tick" in script

    def test_scheduler_plist_hourly_and_run_at_load(self) -> None:
        plist = (_PROJECT_ROOT / "scripts" / "local.wilted-scheduler.plist").read_text(encoding="utf-8")
        assert "local.wilted-scheduler" in plist
        assert "<true/>" in plist
        assert "<key>Minute</key>" in plist
        assert "<key>Hour</key>" not in plist
