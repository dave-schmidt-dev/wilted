"""Tests for ProcessingJob admission repository (Task 3.1)."""

from __future__ import annotations

import importlib.util
import json
import threading
from pathlib import Path

import pytest
from peewee import IntegrityError

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState, SubmissionOutcome
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.db import Item, ProcessingJob, connect_db, now_utc, reset_db, run_migrations
from wilted.processing_jobs import (
    MAX_METADATA_BYTES,
    MetadataForbiddenError,
    MetadataTooLargeError,
    get_job,
    get_job_by_key,
    redact_metadata,
    submit_job,
    transition_job_state,
)


def _make_item(**kwargs) -> Item:
    defaults = dict(
        feed=None,
        guid=f"guid-{kwargs.get('title', 'test')}",
        title="Test Article",
        discovered_at=now_utc(),
        item_type="article",
        status="ready",
        status_changed_at=now_utc(),
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


def _classify_key(*, item_id: str, operation_version: int = 1) -> object:
    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=item_id)
    return build_idempotency_key(JobKind.CLASSIFY, operation_version=operation_version, logical_identity=identity)


class TestSubmitJobAdmission:
    def test_first_submission_creates_row(self):
        item = _make_item(title="classify-me")
        key = _classify_key(item_id=str(item.id))

        result = submit_job(key, item_id=item.id)

        assert result.outcome is SubmissionOutcome.SUBMITTED
        assert result.created is True
        job = get_job(result.job_id)
        assert job is not None
        assert job.state == ProcessingJobState.QUEUED.value
        assert job.idempotency_key == key.canonical

    def test_repeated_submission_dedupes_non_terminal(self):
        key = _classify_key(item_id="42")

        first = submit_job(key)
        second = submit_job(key)

        assert first.created is True
        assert second.outcome is SubmissionOutcome.BUSY
        assert second.created is False
        assert second.job_id == first.job_id
        assert ProcessingJob.select().count() == 1

    def test_concurrent_submissions_create_one_row(self):
        key = _classify_key(item_id="concurrent")
        results: list = []
        errors: list[Exception] = []

        def worker() -> None:
            try:
                from wilted.db import connect_db

                connect_db(wilted.DATA_DIR / "wilted.db")
                results.append(submit_job(key))
            except Exception as exc:  # pragma: no cover - surfaced via errors list
                errors.append(exc)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        assert errors == []
        assert len(results) == 8
        assert len({result.job_id for result in results}) == 1
        assert sum(1 for result in results if result.created) == 1
        assert all(result.outcome in (SubmissionOutcome.SUBMITTED, SubmissionOutcome.BUSY) for result in results)
        assert ProcessingJob.select().count() == 1

    def test_operation_version_bump_admits_new_generation(self):
        identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id="item-1")
        key_v1 = build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)
        key_v2 = build_idempotency_key(JobKind.CLASSIFY, operation_version=2, logical_identity=identity)

        first = submit_job(key_v1)
        second = submit_job(key_v2)

        assert first.created is True
        assert second.created is True
        assert second.outcome is SubmissionOutcome.SUBMITTED
        assert first.job_id != second.job_id
        assert ProcessingJob.select().count() == 2

    def test_failed_job_retries_in_place(self):
        key = _classify_key(item_id="retry-failed")
        first = submit_job(key)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(first.job_id, ProcessingJobState.RUNNING, ProcessingJobState.FAILED)

        retry = submit_job(key)

        assert retry.outcome is SubmissionOutcome.SUBMITTED
        assert retry.created is False
        assert retry.job_id == first.job_id
        refreshed = get_job(first.job_id)
        assert refreshed is not None
        assert refreshed.state == ProcessingJobState.QUEUED.value
        assert refreshed.completed_at is None

    def test_cancelled_job_retries_in_place(self):
        key = _classify_key(item_id="retry-cancelled")
        first = submit_job(key)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.CANCELLED)

        retry = submit_job(key)

        assert retry.outcome is SubmissionOutcome.SUBMITTED
        assert retry.created is False
        assert get_job(first.job_id).state == ProcessingJobState.QUEUED.value

    def test_completed_job_returns_completed_without_new_row(self):
        key = _classify_key(item_id="done")
        first = submit_job(key)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(first.job_id, ProcessingJobState.RUNNING, ProcessingJobState.COMPLETED)

        again = submit_job(key)

        assert again.outcome is SubmissionOutcome.COMPLETED
        assert again.created is False
        assert again.job_id == first.job_id
        assert ProcessingJob.select().count() == 1

    def test_completed_same_key_requires_version_bump_for_new_generation(self):
        identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id="completed-block")
        key_v1 = build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)
        first = submit_job(key_v1)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(first.job_id, ProcessingJobState.RUNNING, ProcessingJobState.COMPLETED)

        key_v2 = build_idempotency_key(JobKind.CLASSIFY, operation_version=2, logical_identity=identity)
        second = submit_job(key_v2)

        assert second.created is True
        assert second.outcome is SubmissionOutcome.SUBMITTED
        assert second.job_id != first.job_id


class TestMetadataSafety:
    def test_redact_metadata_rejects_urls(self):
        with pytest.raises(MetadataForbiddenError, match="URL"):
            redact_metadata({"source": "http://example.com/article"})

    def test_redact_metadata_rejects_secret_keys(self):
        with pytest.raises(MetadataForbiddenError, match="forbidden metadata key"):
            redact_metadata({"api_key": "value"})

    def test_redact_metadata_rejects_tracebacks(self):
        with pytest.raises(MetadataForbiddenError, match="traceback"):
            redact_metadata({"detail": "Traceback (most recent call last):\n  File ..."})

    def test_submit_job_rejects_oversized_metadata(self):
        key = _classify_key(item_id="big-meta")
        payload = {"blob": "x" * (MAX_METADATA_BYTES + 64)}

        with pytest.raises(MetadataTooLargeError):
            submit_job(key, metadata=payload)

    def test_submit_job_persists_safe_metadata(self):
        key = _classify_key(item_id="safe-meta")
        result = submit_job(key, metadata={"phase": "admission", "count": 2})

        job = get_job(result.job_id)
        assert job is not None
        assert json.loads(job.checkpoint_json) == {"count": 2, "phase": "admission"}


class TestRepositoryHelpers:
    def test_get_job_by_key(self):
        key = _classify_key(item_id="lookup")
        submitted = submit_job(key)

        job = get_job_by_key(key.canonical)

        assert job is not None
        assert job.id == submitted.job_id

    def test_transition_job_state_cas_success_and_miss(self):
        key = _classify_key(item_id="cas")
        submitted = submit_job(key)

        assert transition_job_state(submitted.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING) is True
        assert transition_job_state(submitted.job_id, ProcessingJobState.QUEUED, ProcessingJobState.CANCELLED) is False
        assert get_job(submitted.job_id).state == ProcessingJobState.RUNNING.value

    def test_invalid_state_rejected_by_check_constraint(self):
        key = _classify_key(item_id="constraint")
        submitted = submit_job(key)
        job = get_job(submitted.job_id)

        with pytest.raises(IntegrityError):
            job.state = "not-a-state"
            job.save()


class TestMigration003:
    def _load_migration(self):
        mig_path = Path(__file__).resolve().parent.parent / "migrations" / "003_processing_jobs.py"
        spec = importlib.util.spec_from_file_location("migration_003", mig_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_idempotent_on_fresh_database(self, tmp_path):
        db_path = tmp_path / "fresh.db"
        reset_db()
        connect_db(db_path)
        run_migrations(db_path)

        from wilted.db import _db

        migration = self._load_migration()
        migration.up(_db)
        migration.up(_db)

        assert _table_exists(_db, "processing_jobs")
        assert _index_exists(_db, "processingjob_state_priority_not_before")
        assert _index_exists(_db, "processingjob_item_id")

    def test_auto_applies_through_run_migrations(self, tmp_path):
        db_path = tmp_path / "auto.db"
        reset_db()
        connect_db(db_path)
        run_migrations(db_path)

        from wilted.db import _Meta

        version = _Meta.get_by_id("schema_version").value
        assert int(version) >= 3
        assert _table_exists(ProcessingJob._meta.database, "processing_jobs")


def _table_exists(db, table_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    )
    return cursor.fetchone() is not None


def _index_exists(db, index_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
        (index_name,),
    )
    return cursor.fetchone() is not None
