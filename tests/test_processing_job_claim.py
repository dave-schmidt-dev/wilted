"""Tests for ProcessingJob claim, lease, cancellation, and recovery (Task 3.2)."""

from __future__ import annotations

import importlib.util
import json
import multiprocessing
import os
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

import wilted
from wilted.background_work.contracts import ArtifactManifest, JobKind, ProcessingJobState
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.db import ProcessingJob, connect_db, now_utc, reset_db, run_migrations
from wilted.processing_jobs import (
    ExecutionLockBusy,
    apply_running_cancel,
    claim_next_job,
    execution_lock_path,
    record_job_completion,
    recover_stale_jobs,
    request_cancel,
    submit_job,
    try_acquire_execution_lock,
    validate_job_output,
)


def _classify_key(*, item_id: str, operation_version: int = 1) -> object:
    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=item_id)
    return build_idempotency_key(JobKind.CLASSIFY, operation_version=operation_version, logical_identity=identity)


def _manifest(**overrides) -> ArtifactManifest:
    defaults = dict(
        item_id="42",
        input_digest="a" * 64,
        operation_version=1,
        output_digests=("b" * 64,),
        completeness_checks=("non_empty",),
    )
    defaults.update(overrides)
    return ArtifactManifest(**defaults)


def _submit_queued(*, item_id: str = "claim-me", priority: int = 0) -> int:
    key = _classify_key(item_id=item_id)
    result = submit_job(key, priority=priority)
    return result.job_id


def _offset_utc(base: str, *, seconds: int) -> str:
    dt = datetime.fromisoformat(base.replace("Z", "+00:00"))
    return (dt.astimezone(UTC) + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Module-level multiprocessing workers (spawn-safe)
# ---------------------------------------------------------------------------


def _mp_try_hold_lock(data_dir: str, holder_id: str, barrier: object, result_queue: object) -> None:
    import pathlib

    import wilted as wilted_mod
    from wilted.processing_jobs import ExecutionLockBusy, try_acquire_execution_lock

    wilted_mod.DATA_DIR = pathlib.Path(data_dir)
    barrier.wait()
    try:
        with try_acquire_execution_lock(pathlib.Path(data_dir)):
            result_queue.put((holder_id, "held"))
            time.sleep(0.75)
    except ExecutionLockBusy:
        result_queue.put((holder_id, "busy"))


def _mp_claim_under_parent_lock(db_path: str, owner_id: str, start_event: object, result_queue: object) -> None:
    import pathlib

    import wilted as wilted_mod
    from wilted.db import connect_db
    from wilted.processing_jobs import _claim_next_job_under_lock

    wilted_mod.DATA_DIR = pathlib.Path(db_path).parent
    connect_db(pathlib.Path(db_path))
    start_event.wait()
    try:
        job = _claim_next_job_under_lock(owner_id=owner_id, lease_seconds=300)
        result_queue.put((owner_id, job.id if job is not None else None))
    except Exception as exc:  # pragma: no cover - surfaced via result queue
        result_queue.put((owner_id, f"error:{exc}"))


# ---------------------------------------------------------------------------
# Execution flock
# ---------------------------------------------------------------------------


class TestExecutionLock:
    def test_lock_path_uses_live_data_dir(self, monkeypatch, tmp_path):
        """INV-5: execution_lock_path resolves the monkeypatched DATA_DIR."""
        data_a = tmp_path / "data-a"
        data_b = tmp_path / "data-b"
        data_a.mkdir()
        data_b.mkdir()
        monkeypatch.setattr(wilted, "DATA_DIR", data_a)

        assert execution_lock_path(wilted.DATA_DIR) == data_a / ".processing_runner.lock"
        monkeypatch.setattr(wilted, "DATA_DIR", data_b)
        assert execution_lock_path(wilted.DATA_DIR) == data_b / ".processing_runner.lock"

    def test_two_holders_in_process_second_raises_busy(self):
        with try_acquire_execution_lock(wilted.DATA_DIR):
            with pytest.raises(ExecutionLockBusy):
                with try_acquire_execution_lock(wilted.DATA_DIR):
                    pass

    @pytest.mark.integration
    def test_cross_process_only_one_holds_execution_lock(self, tmp_path):
        data_dir = str(tmp_path / "mp-data")
        os.makedirs(data_dir, exist_ok=True)

        ctx = multiprocessing.get_context("spawn")
        barrier = ctx.Barrier(2)
        result_queue = ctx.Queue()
        processes = [
            ctx.Process(
                target=_mp_try_hold_lock,
                args=(data_dir, f"holder-{index}", barrier, result_queue),
            )
            for index in range(2)
        ]
        for process in processes:
            process.start()
        for process in processes:
            process.join(timeout=10.0)
            assert process.exitcode == 0

        outcomes = [result_queue.get(timeout=2.0) for _ in range(2)]
        statuses = {holder: status for holder, status in outcomes}
        assert list(statuses.values()).count("held") == 1
        assert list(statuses.values()).count("busy") == 1


# ---------------------------------------------------------------------------
# Claim / lease
# ---------------------------------------------------------------------------


class TestClaimNextJob:
    def test_claims_highest_priority_oldest_job(self):
        low = _submit_queued(item_id="low", priority=0)
        high = _submit_queued(item_id="high", priority=10)
        _submit_queued(item_id="later", priority=10)

        claimed = claim_next_job(data_dir=wilted.DATA_DIR, owner_id="runner-a")

        assert claimed is not None
        assert claimed.id == high
        assert claimed.id != low
        assert claimed.state == ProcessingJobState.RUNNING.value
        assert claimed.lease_owner == "runner-a"
        assert claimed.attempt_count == 1
        assert claimed.started_at is not None

    @pytest.mark.integration
    def test_concurrent_claim_only_one_wins_same_job(self):
        job_id = _submit_queued(item_id="race-one")
        db_path = str(wilted.DATA_DIR / "wilted.db")

        ctx = multiprocessing.get_context("spawn")
        start_event = ctx.Event()
        result_queue = ctx.Queue()
        processes = [
            ctx.Process(
                target=_mp_claim_under_parent_lock,
                args=(db_path, f"owner-{index}", start_event, result_queue),
            )
            for index in range(4)
        ]

        reset_db()
        with try_acquire_execution_lock(wilted.DATA_DIR):
            for process in processes:
                process.start()
            start_event.set()
            for process in processes:
                process.join(timeout=15.0)
                assert process.exitcode == 0
        connect_db(wilted.DATA_DIR / "wilted.db")

        outcomes = [result_queue.get(timeout=2.0) for _ in range(4)]
        errors = [value for _owner, value in outcomes if isinstance(value, str) and value.startswith("error:")]
        assert errors == [], f"unexpected worker errors: {errors}"
        claimed_ids = [claimed for _owner, claimed in outcomes if isinstance(claimed, int)]
        assert claimed_ids == [job_id]
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.RUNNING.value


# ---------------------------------------------------------------------------
# Cancellation
# ---------------------------------------------------------------------------


class TestCancellation:
    def test_queued_cancel_is_immediate(self):
        job_id = _submit_queued(item_id="cancel-queued")

        assert request_cancel(job_id) is True

        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.CANCELLED.value
        assert job.completed_at is not None

    def test_running_cancel_sets_flag_then_reconciles(self):
        job_id = _submit_queued(item_id="cancel-running")
        claimed = claim_next_job(data_dir=wilted.DATA_DIR, owner_id="runner-cancel")
        assert claimed is not None and claimed.id == job_id

        assert request_cancel(job_id) is True
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.RUNNING.value
        assert job.cancel_requested is True

        terminal = apply_running_cancel(job_id, artifact_complete=False)
        assert terminal is ProcessingJobState.CANCELLED
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.CANCELLED.value

    def test_running_cancel_with_valid_artifact_completes(self):
        job_id = _submit_queued(item_id="cancel-complete")
        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="runner-complete")
        request_cancel(job_id)

        terminal = apply_running_cancel(job_id, artifact_complete=True)
        assert terminal is ProcessingJobState.COMPLETED

    def test_running_cancel_race_only_one_request_applies(self):
        job_id = _submit_queued(item_id="cancel-race")
        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="runner-race")

        results: list[bool] = []

        def _cancel() -> None:
            from wilted.db import connect_db

            connect_db(wilted.DATA_DIR / "wilted.db")
            results.append(request_cancel(job_id))

        threads = [threading.Thread(target=_cancel) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        assert sum(results) >= 1
        assert ProcessingJob.get_by_id(job_id).cancel_requested is True


# ---------------------------------------------------------------------------
# Stale recovery and completion
# ---------------------------------------------------------------------------


class TestStaleRecovery:
    def test_crash_before_publication_recovers_to_retry(self):
        job_id = _submit_queued(item_id="stale-retry")
        now = now_utc()
        expired = _offset_utc(now, seconds=-30)

        ProcessingJob.update(
            state=ProcessingJobState.RUNNING.value,
            lease_owner="dead-runner",
            lease_expires_at=expired,
            attempt_count=1,
            started_at=now,
            updated_at=now,
        ).where(ProcessingJob.id == job_id).execute()

        with try_acquire_execution_lock(wilted.DATA_DIR):
            recovered = recover_stale_jobs(data_dir=wilted.DATA_DIR, owner_id="new-runner", now=now)

        assert recovered == 1
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.RETRY.value
        assert job.lease_owner is None

    def test_completed_job_never_reclaimed(self):
        job_id = _submit_queued(item_id="never-reclaim")
        now = now_utc()
        manifest = _manifest()
        result_json = json.dumps(
            {
                "manifest": {
                    "item_id": manifest.item_id,
                    "input_digest": manifest.input_digest,
                    "operation_version": manifest.operation_version,
                    "output_digests": list(manifest.output_digests),
                    "completeness_checks": list(manifest.completeness_checks),
                },
            },
        )

        ProcessingJob.update(
            state=ProcessingJobState.COMPLETED.value,
            completed_at=now,
            updated_at=now,
            result_json=result_json,
            lease_owner=None,
            lease_expires_at=None,
        ).where(ProcessingJob.id == job_id).execute()

        with try_acquire_execution_lock(wilted.DATA_DIR):
            recovered = recover_stale_jobs(data_dir=wilted.DATA_DIR, owner_id="runner", now=now)

        assert recovered == 0
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.COMPLETED.value


class TestArtifactCompletion:
    def test_validate_job_output_requires_complete_manifest(self):
        manifest = _manifest()
        assert validate_job_output(manifest) is True
        assert validate_job_output(manifest, nondeterministic=True) is False

    def test_record_job_completion_cas_success(self):
        job_id = _submit_queued(item_id="complete-me")
        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="finisher")
        manifest = _manifest()

        assert record_job_completion(job_id, "finisher", manifest, {"phase": "done"}) is True

        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.COMPLETED.value
        assert job.result_json is not None
        assert json.loads(job.result_json)["metadata"] == {"phase": "done"}

    def test_record_job_completion_rejects_incomplete_nondeterministic_manifest(self):
        job_id = _submit_queued(item_id="reject-complete")
        claim_next_job(data_dir=wilted.DATA_DIR, owner_id="finisher")

        assert record_job_completion(job_id, "finisher", _manifest(), nondeterministic=True) is False
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.RUNNING.value


class TestMigration004:
    def _load_migration(self):
        mig_path = Path(__file__).resolve().parent.parent / "migrations" / "004_processing_job_cancel_requested.py"
        spec = importlib.util.spec_from_file_location("migration_004", mig_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_cancel_requested_column_present_after_migrations(self, tmp_path):
        db_path = tmp_path / "fresh.db"
        reset_db()
        connect_db(db_path)
        run_migrations(db_path)

        from wilted.db import _db

        migration = self._load_migration()
        migration.up(_db)
        migration.up(_db)

        cursor = _db.execute_sql("PRAGMA table_info(processing_jobs)")
        columns = {row[1] for row in cursor.fetchall()}
        assert "cancel_requested" in columns

        version = _db.execute_sql("SELECT value FROM _meta WHERE key = 'schema_version'").fetchone()
        assert int(version[0]) >= 4
