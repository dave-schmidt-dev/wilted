"""Tests for ProcessingJob admission repository (Task 3.1)."""

from __future__ import annotations

import importlib.util
import json
import sqlite3
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
    prune_terminal_jobs,
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

    def test_failed_job_retry_resets_attempt_count_and_result_json(self):
        """Retry-in-place must start a clean attempt budget and drop any prior result.

        Neither field was reset before this fix: a retried job could carry
        forward a stale ``attempt_count`` (exhausting ``max_attempts`` early)
        or a stale ``result_json`` from an unrelated earlier generation.
        """
        key = _classify_key(item_id="retry-reset")
        first = submit_job(key)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(first.job_id, ProcessingJobState.RUNNING, ProcessingJobState.FAILED)

        # Simulate leftover attempt/result state from the prior generation.
        (
            ProcessingJob.update(
                attempt_count=3,
                result_json='{"manifest":{},"metadata":{"stale":true}}',
            ).where(ProcessingJob.id == first.job_id)
        ).execute()

        retry = submit_job(key)

        assert retry.outcome is SubmissionOutcome.SUBMITTED
        assert retry.created is False
        assert retry.job_id == first.job_id
        refreshed = get_job(first.job_id)
        assert refreshed is not None
        assert refreshed.state == ProcessingJobState.QUEUED.value
        assert refreshed.attempt_count == 0
        assert refreshed.result_json is None

    def test_cancelled_job_retry_resets_attempt_count_and_result_json(self):
        key = _classify_key(item_id="retry-cancelled-reset")
        first = submit_job(key)
        assert transition_job_state(first.job_id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(first.job_id, ProcessingJobState.RUNNING, ProcessingJobState.CANCELLED)

        (
            ProcessingJob.update(
                attempt_count=2,
                result_json='{"manifest":{},"metadata":{}}',
            ).where(ProcessingJob.id == first.job_id)
        ).execute()

        retry = submit_job(key)

        assert retry.outcome is SubmissionOutcome.SUBMITTED
        refreshed = get_job(first.job_id)
        assert refreshed is not None
        assert refreshed.attempt_count == 0
        assert refreshed.result_json is None

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


class TestPruneTerminalJobs:
    def _make_job(
        self,
        *,
        kind: JobKind = JobKind.DISCOVER,
        state: ProcessingJobState,
        completed_at: str | None,
        key_suffix: str,
    ) -> ProcessingJob:
        now = now_utc()
        return ProcessingJob.create(
            idempotency_key=f"{kind.value}:v1:prune-test:{key_suffix}",
            kind=kind.value,
            state=state.value,
            priority=0,
            attempt_count=0,
            max_attempts=3,
            created_at=now,
            updated_at=now,
            completed_at=completed_at,
        )

    def test_deletes_terminal_rows_older_than_cutoff(self):
        job = self._make_job(
            state=ProcessingJobState.COMPLETED,
            completed_at="2020-01-01T00:00:00Z",
            key_suffix="old-completed",
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 1
        assert get_job(job.id) is None

    def test_retains_recent_terminal_rows(self):
        job = self._make_job(
            state=ProcessingJobState.FAILED,
            completed_at="2020-01-30T00:00:00Z",
            key_suffix="recent-failed",
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 0
        assert get_job(job.id) is not None

    def test_never_touches_non_terminal_rows_regardless_of_age(self):
        old = "2020-01-01T00:00:00Z"
        job = ProcessingJob.create(
            idempotency_key="classify:v1:prune-test:non-terminal",
            kind=JobKind.CLASSIFY.value,
            state=ProcessingJobState.QUEUED.value,
            priority=0,
            attempt_count=0,
            max_attempts=3,
            created_at=old,
            updated_at=old,
            completed_at=None,
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 0
        assert get_job(job.id) is not None

    def test_prunes_terminal_rows_across_every_kind(self):
        old = "2020-01-01T00:00:00Z"
        completed = self._make_job(
            kind=JobKind.DISCOVER,
            state=ProcessingJobState.COMPLETED,
            completed_at=old,
            key_suffix="discover",
        )
        failed = self._make_job(
            kind=JobKind.CLASSIFY,
            state=ProcessingJobState.FAILED,
            completed_at=old,
            key_suffix="classify",
        )
        cancelled = self._make_job(
            kind=JobKind.REPORT_ASSEMBLY,
            state=ProcessingJobState.CANCELLED,
            completed_at=old,
            key_suffix="report",
        )
        still_running = self._make_job(
            kind=JobKind.PREPARE,
            state=ProcessingJobState.RUNNING,
            completed_at=None,
            key_suffix="prepare",
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 3
        assert get_job(completed.id) is None
        assert get_job(failed.id) is None
        assert get_job(cancelled.id) is None
        assert get_job(still_running.id) is not None

    def test_queued_row_with_stale_completed_at_is_not_age_pruned(self):
        """A ``queued`` row bearing a stale old ``completed_at`` is never pruned.

        Narrow scope note: this proves only that a *currently* non-terminal row
        is excluded regardless of its timestamp — a pure age-only delete would
        wrongly remove it. It does **not** exercise the retention TOCTOU itself,
        because the row is ``queued`` from the outset: the pre-fix
        ``select(terminal ids) -> delete(id.in_(ids))`` form also excluded it
        (the terminal filter lived in its SELECT), so this assertion passes on
        the buggy implementation too. The TOCTOU — a row that is *terminal at
        select time* and requeued before the delete lands — and the
        bound-variable no-op are what actually distinguish the fix; they are
        gated by ``test_prune_delete_reevaluates_state_at_delete_time`` and
        ``test_prune_deletes_candidate_set_larger_than_sqlite_variable_limit``
        below.
        """
        old = "2020-01-01T00:00:00Z"
        job = self._make_job(
            state=ProcessingJobState.QUEUED,
            completed_at=old,
            key_suffix="requeued-stale-ts",
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 0
        assert get_job(job.id) is not None

    def test_prune_delete_reevaluates_state_at_delete_time(self):
        """The emitted ``DELETE`` carries the terminal-state predicate itself.

        This is the sensitive gate for the retention TOCTOU (the data-loss half
        of the fix). The bug was ``select(terminal ids) -> delete().where(
        id.in_(ids))``: the delete named rows purely by id, so a concurrent
        ``_requeue_job`` flipping a candidate to ``queued`` between the select
        and the delete would have it dropped anyway. The fix folds the
        terminal + age predicate into a single atomic ``DELETE`` whose ``WHERE``
        SQLite re-evaluates at delete time.

        We assert that property structurally — the DELETE statement's SQL must
        reference the ``state`` column — because it is a property of the emitted
        statement, and a deterministic interleaving test cannot distinguish the
        two implementations without hooking the buggy form's internal SELECT
        (which the fixed form does not have). Reverting to the id-list delete
        emits ``DELETE FROM ... WHERE id IN (?, ...)`` with no ``state`` clause,
        so this goes red. Verified by revert-to-red.
        """
        self._make_job(
            state=ProcessingJobState.COMPLETED,
            completed_at="2020-01-01T00:00:00Z",
            key_suffix="captured-delete",
        )
        db = ProcessingJob._meta.database
        original_execute_sql = db.execute_sql
        captured: list[str] = []

        def _capturing_execute_sql(sql, *args, **kwargs):
            captured.append(sql)
            return original_execute_sql(sql, *args, **kwargs)

        db.execute_sql = _capturing_execute_sql
        try:
            deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")
        finally:
            db.execute_sql = original_execute_sql

        assert deleted == 1
        delete_statements = [s for s in captured if s.lstrip().upper().startswith("DELETE")]
        assert delete_statements, "prune emitted no DELETE statement"
        assert all('"state"' in s or " state " in s.lower() for s in delete_statements), (
            f"DELETE must re-evaluate the state predicate at delete time; got: {delete_statements}"
        )

    def test_prune_deletes_candidate_set_larger_than_sqlite_variable_limit(self):
        """A candidate set larger than SQLite's bound-variable limit is fully
        pruned — the sweep never silently no-ops.

        This is the sensitive gate for the second half of the fix. The pre-fix
        ``delete().where(id.in_(ids))`` bound one variable per candidate, so a
        retention backlog exceeding ``SQLITE_LIMIT_VARIABLE_NUMBER`` raised
        ``OperationalError: too many SQL variables`` (or, under a chunking
        wrapper, silently swept nothing). The atomic ``DELETE`` binds only the
        constant terminal + cutoff predicate (four variables), independent of
        row count.

        We lower the connection's variable limit around the prune call so the
        assertion is deterministic and version-independent rather than depending
        on the platform's default ceiling (32766 here). The id-list form would
        bind ``candidate_count`` (200) variables against a limit of 64 and
        raise; the fix binds four and succeeds. Verified by revert-to-red.
        """
        old = "2020-01-01T00:00:00Z"
        now = now_utc()
        candidate_count = 200
        ProcessingJob.insert_many(
            [
                {
                    "idempotency_key": f"discover:v1:prune-bulk:{i}",
                    "kind": JobKind.DISCOVER.value,
                    "state": ProcessingJobState.COMPLETED.value,
                    "priority": 0,
                    "attempt_count": 0,
                    "max_attempts": 3,
                    "created_at": now,
                    "updated_at": now,
                    "completed_at": old,
                }
                for i in range(candidate_count)
            ]
        ).execute()

        connection = ProcessingJob._meta.database.connection()
        lowered_limit = 64  # comfortably above the fix's 4 constant binds, far below 200
        previous_limit = connection.getlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER)
        connection.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, lowered_limit)
        try:
            deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")
        finally:
            connection.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, previous_limit)

        assert deleted == candidate_count

    def test_rejects_negative_older_than_days(self):
        with pytest.raises(ValueError, match="older_than_days"):
            prune_terminal_jobs(older_than_days=-1)


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
