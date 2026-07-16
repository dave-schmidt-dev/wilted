"""Recovery campaign integration tests (Task 7.1).

Subprocess and multiprocessing coverage for stale-job recovery after a
simulated runner crash, handler-failure retry, briefing artifact adoption
idempotency, and scheduler lock-busy behavior.
"""

from __future__ import annotations

import json
import multiprocessing
import os
import subprocess
import sys
import time
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING

import pytest

import wilted
from wilted.background_work.contracts import ArtifactManifest, JobKind, ProcessingJobState, SubmissionOutcome
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.background_work.scheduler import SchedulerTickOutcome
from wilted.briefing_artifacts import (
    load_newest_owed_briefing,
    mark_briefing_adopted,
    persist_briefing_artifact,
)
from wilted.db import ProcessingJob, now_utc
from wilted.pipeline_runner import HANDLERS, PipelineRunner, RunExitReason
from wilted.processing_jobs import (
    claim_next_job,
    record_job_completion,
    submit_job,
    try_acquire_execution_lock,
)
from wilted.scheduler_tick import exit_code_for_outcome, run_scheduler_tick
from wilted.station_runtime.briefing import Briefing, BriefingAudio, BriefingItem
from wilted.station_runtime.coordinator import ModelCoordinator, RuntimeBootstrap

if TYPE_CHECKING:
    from pathlib import Path

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _classify_key(*, item_id: str) -> object:
    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=item_id)
    return build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)


def _submit_queued(*, item_id: str) -> int:
    key = _classify_key(item_id=item_id)
    return submit_job(key).job_id


def _manifest(*, item_id: str = "42") -> ArtifactManifest:
    return ArtifactManifest(
        item_id=item_id,
        input_digest="a" * 64,
        operation_version=1,
        output_digests=("b" * 64,),
        completeness_checks=("non_empty",),
    )


def _offset_utc(base: str, *, seconds: int) -> str:
    dt = datetime.fromisoformat(base.replace("Z", "+00:00"))
    return (dt.astimezone(UTC) + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _subprocess_env(project_root: Path) -> dict[str, str]:
    (project_root / "pyproject.toml").write_text('[project]\nname = "wilted"\n', encoding="utf-8")
    env = os.environ.copy()
    env["WILTED_PROJECT_ROOT"] = str(project_root)
    return env


def _run_cli(*, args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys; sys.argv[0] = 'wilted'; from wilted.cli import main; main()",
            *args,
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def _sample_briefing() -> Briefing:
    return Briefing(
        generated_at=datetime.now(UTC),
        max_age_s=3600.0,
        max_duration_s=300.0,
        items=(
            BriefingItem(
                item_id="1",
                title="Headline",
                summary="Summary",
                source_name="Src",
                relevance_score=0.8,
                playlist="Work",
            ),
        ),
        weather=None,
        script="Good morning.",
        word_count=2,
        estimated_duration_s=1.0,
        synth_result=BriefingAudio(audio_bytes=b"RIFFfake", duration_ms=500),
    )


# ---------------------------------------------------------------------------
# Module-level multiprocessing workers (spawn-safe)
# ---------------------------------------------------------------------------


def _mp_hold_execution_lock(
    data_dir: str,
    hold_event: object,
    release_event: object,
) -> None:
    import pathlib

    import wilted as wilted_mod
    from wilted.db import connect_db
    from wilted.processing_jobs import try_acquire_execution_lock

    data_path = pathlib.Path(data_dir)
    wilted_mod.DATA_DIR = data_path
    connect_db(data_path / "wilted.db")
    with try_acquire_execution_lock(data_path):
        hold_event.set()
        release_event.wait(timeout=10.0)


def _mp_run_recovery_runner(data_dir: str, result_queue: object) -> None:
    import pathlib

    import wilted as wilted_mod
    from wilted.background_work.contracts import ArtifactManifest, JobKind
    from wilted.db import ProcessingJob, connect_db
    from wilted.pipeline_runner import HANDLERS, PipelineRunner
    from wilted.processing_jobs import record_job_completion
    from wilted.station_runtime.coordinator import ModelCoordinator, RuntimeBootstrap

    data_path = pathlib.Path(data_dir)
    wilted_mod.DATA_DIR = data_path
    connect_db(data_path / "wilted.db")

    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()

    def _complete(job, coordinator) -> None:
        assert isinstance(coordinator, ModelCoordinator)
        manifest = ArtifactManifest(
            item_id="42",
            input_digest="a" * 64,
            operation_version=1,
            output_digests=("b" * 64,),
            completeness_checks=("non_empty",),
        )
        record_job_completion(job.id, "recovery-subproc", manifest)

    runner = PipelineRunner(
        data_dir=data_path,
        max_jobs_per_run=4,
        bootstrap=bootstrap,
        handlers={**HANDLERS, JobKind.CLASSIFY: _complete},
    )
    result = runner.run(owner_id="recovery-subproc")
    job = ProcessingJob.get()
    result_queue.put(
        (
            result.exit_reason.value,
            result.stats.submitted_handled,
            job.state,
        ),
    )


# ---------------------------------------------------------------------------
# Stale recovery after simulated crash
# ---------------------------------------------------------------------------


class TestStaleJobRecovery:
    def test_crash_lease_expiry_recovered_by_subprocess_runner(self, tmp_path) -> None:
        """A dead runner's expired lease is reconciled when a new runner starts."""
        job_id = _submit_queued(item_id="crash-recover")
        now = now_utc()
        expired = _offset_utc(now, seconds=-30)

        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="dead-runner")
        ProcessingJob.update(
            lease_expires_at=expired,
            updated_at=now,
        ).where(ProcessingJob.id == job_id).execute()

        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.RUNNING.value

        ctx = multiprocessing.get_context("spawn")
        result_queue = ctx.Queue()
        process = ctx.Process(
            target=_mp_run_recovery_runner,
            args=(str(wilted.DATA_DIR), result_queue),
        )
        process.start()
        process.join(timeout=20.0)
        assert process.exitcode == 0

        exit_reason, handled, terminal_state = result_queue.get(timeout=2.0)
        assert exit_reason == RunExitReason.COMPLETED.value
        assert handled == 1
        assert terminal_state == ProcessingJobState.COMPLETED.value

    def test_in_process_runner_recovers_stale_job_before_retry_claim(self) -> None:
        """PipelineRunner calls recover_stale_jobs before claiming retried work."""
        job_id = _submit_queued(item_id="stale-before-claim")
        now = now_utc()
        expired = _offset_utc(now, seconds=-30)

        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="dead-runner")
        ProcessingJob.update(
            lease_expires_at=expired,
            updated_at=now,
        ).where(ProcessingJob.id == job_id).execute()

        def _complete(job, coordinator) -> None:
            assert isinstance(coordinator, ModelCoordinator)
            record_job_completion(job.id, "recovery-runner", _manifest())

        runner = PipelineRunner(
            max_jobs_per_run=4,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _complete},
        )
        result = runner.run(owner_id="recovery-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 1
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.COMPLETED.value
        assert job.lease_owner is None


# ---------------------------------------------------------------------------
# Handler failure → retry path
# ---------------------------------------------------------------------------


class TestHandlerFailureRetry:
    def test_failed_handler_then_successful_rerun_completes(self) -> None:
        job_id = _submit_queued(item_id="retry-after-fail")
        attempts: list[int] = []

        def _flaky(job, coordinator) -> None:
            attempts.append(job.id)
            if len(attempts) == 1:
                raise RuntimeError("simulated handler failure")
            record_job_completion(job.id, "retry-runner", _manifest())

        runner = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _flaky},
        )

        first = runner.run(owner_id="retry-runner")
        assert first.stats.failed == 1
        assert first.stats.submitted_handled == 0
        retry_job = ProcessingJob.get_by_id(job_id)
        assert retry_job.state == ProcessingJobState.RETRY.value
        assert retry_job.error_json is not None

        second = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _flaky},
        ).run(owner_id="retry-runner")
        assert second.stats.failed == 0
        assert second.stats.submitted_handled == 1
        assert attempts == [job_id, job_id]
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.COMPLETED.value

    def test_resubmit_after_terminal_failure_requeues_and_completes(self) -> None:
        key = _classify_key(item_id="resubmit-failed")
        job_id = submit_job(key, max_attempts=1).job_id

        def _fail(job, coordinator) -> None:
            raise RuntimeError("terminal failure")

        runner = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _fail},
        )
        failed_run = runner.run(owner_id="fail-runner")
        assert failed_run.stats.failed == 1
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.FAILED.value

        resubmit = submit_job(key)
        assert resubmit.outcome is SubmissionOutcome.SUBMITTED
        assert resubmit.job_id == job_id
        assert resubmit.created is False
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.QUEUED.value

        def _complete(job, coordinator) -> None:
            record_job_completion(job.id, "retry-runner", _manifest())

        success_run = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _complete},
        ).run(owner_id="retry-runner")
        assert success_run.stats.submitted_handled == 1
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.COMPLETED.value


# ---------------------------------------------------------------------------
# Briefing artifact adoption idempotency
# ---------------------------------------------------------------------------


class TestBriefingArtifactAdoption:
    def test_mark_adopted_once_excludes_artifact_from_owed_queue(self) -> None:
        today = datetime.now(UTC).strftime("%Y-%m-%d")
        briefing = _sample_briefing()
        artifact_id = persist_briefing_artifact(briefing, window_start=today, window_end=today)

        owed = load_newest_owed_briefing()
        assert owed is not None
        assert owed.artifact_id == artifact_id
        assert owed.adopted_at is None

        adopted_at = "2026-07-16T10:00:00Z"
        mark_briefing_adopted(artifact_id, adopted_at=adopted_at)

        assert load_newest_owed_briefing() is None
        manifest_path = wilted.DATA_DIR / "briefings" / artifact_id / "manifest.json"
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert payload["adopted_at"] == adopted_at

    def test_repeat_mark_adopted_is_idempotent(self) -> None:
        today = datetime.now(UTC).strftime("%Y-%m-%d")
        artifact_id = persist_briefing_artifact(_sample_briefing(), window_start=today, window_end=today)
        adopted_at = "2026-07-16T10:00:00Z"

        mark_briefing_adopted(artifact_id, adopted_at=adopted_at)
        mark_briefing_adopted(artifact_id, adopted_at=adopted_at)

        manifest_path = wilted.DATA_DIR / "briefings" / artifact_id / "manifest.json"
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert payload["adopted_at"] == adopted_at
        assert load_newest_owed_briefing() is None


# ---------------------------------------------------------------------------
# Scheduler lock busy
# ---------------------------------------------------------------------------


class TestSchedulerLockBusy:
    def test_scheduler_tick_reports_lock_busy_outcome(self) -> None:
        _submit_queued(item_id="scheduler-lock-busy-recovery")
        with try_acquire_execution_lock(wilted.DATA_DIR):
            result = run_scheduler_tick(data_dir=wilted.DATA_DIR, dns_check=lambda: True)

        assert result.outcome is SchedulerTickOutcome.LOCK_BUSY
        assert result.exit_code == exit_code_for_outcome(SchedulerTickOutcome.LOCK_BUSY)
        assert result.exit_code == 0

    def test_scheduler_cli_tick_returns_lock_busy_while_lock_held_cross_process(self, tmp_path) -> None:
        _submit_queued(item_id="scheduler-cli-lock-busy")
        project_root = tmp_path
        env = _subprocess_env(project_root)
        data_dir = project_root / "data"
        assert data_dir == wilted.DATA_DIR

        ctx = multiprocessing.get_context("spawn")
        hold_event = ctx.Event()
        release_event = ctx.Event()
        holder = ctx.Process(
            target=_mp_hold_execution_lock,
            args=(str(data_dir), hold_event, release_event),
        )
        holder.start()
        assert hold_event.wait(timeout=5.0)

        try:
            time.sleep(0.05)
            result = _run_cli(args=["scheduler", "tick"], env=env)
        finally:
            release_event.set()
            holder.join(timeout=10.0)
            assert holder.exitcode == 0

        assert result.returncode == exit_code_for_outcome(SchedulerTickOutcome.LOCK_BUSY)
        assert "outcome=lock_busy" in result.stdout
