"""Tests for ProcessingJob admission repository (Task 3.1)."""

from __future__ import annotations

import importlib.util
import json
import logging
import multiprocessing
import sqlite3
import threading
from datetime import UTC, datetime
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
    claim_next_job,
    get_job,
    get_job_by_key,
    prune_terminal_jobs,
    read_deferral_summary,
    redact_metadata,
    submit_job,
    transition_job_state,
    try_acquire_execution_lock,
)
from wilted.scheduling_policy import DeferralReason, PolicyThresholds
from wilted.station_runtime.machine_availability import MachineAvailability


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


# ---------------------------------------------------------------------------
# Claim-seam policy helpers (M3 / INV-12)
# ---------------------------------------------------------------------------
# A daytime instant inside the default busy window [08:00, 20:00).
_DAYTIME_NOW = datetime(2026, 7, 25, 10, 0, tzinfo=UTC)


def _fixed_now():
    return _DAYTIME_NOW


def _busy_available() -> MachineAvailability:
    """A healthy sample of a BUSY machine (high load, not idle) -> defers."""
    return MachineAvailability(
        load_per_core=2.0, on_ac_power=True, user_idle_seconds=5.0, sampled_at="2026-07-25T10:00:00Z", ok=True
    )


def _unavailable() -> MachineAvailability:
    """A failed sample (sensor unavailable) -> fail-open."""
    return MachineAvailability(
        load_per_core=0.0, on_ac_power=False, user_idle_seconds=None, sampled_at="2026-07-25T10:00:00Z", ok=False
    )


class _FakeAvailabilityBackend:
    """Injectable ``AvailabilityBackend`` returning a fixed, pre-built sample."""

    def __init__(self, availability: MachineAvailability) -> None:
        self._availability = availability
        self.sample_calls = 0

    def sample(self) -> MachineAvailability:
        self.sample_calls += 1
        return self._availability


def _submit_expensive(*, item_id: str = "cache-me", priority: int = 0) -> int:
    """Submit an ARTICLE_CACHE job (always EXPENSIVE, no item_type dependency)."""
    identity = logical_identity_for_kind(JobKind.ARTICLE_CACHE, item_id=item_id)
    key = build_idempotency_key(JobKind.ARTICLE_CACHE, operation_version=1, logical_identity=identity)
    return submit_job(key, priority=priority).job_id


def _submit_cheap(*, report_date: str = "2026-07-25", priority: int = 0) -> int:
    """Submit a REPORT_ASSEMBLY job (always CHEAP)."""
    identity = logical_identity_for_kind(JobKind.REPORT_ASSEMBLY, report_date=report_date)
    key = build_idempotency_key(JobKind.REPORT_ASSEMBLY, operation_version=1, logical_identity=identity)
    return submit_job(key, priority=priority).job_id


def _set_created_at(job_id: int, created_at: str) -> None:
    ProcessingJob.update(created_at=created_at).where(ProcessingJob.id == job_id).execute()


def _mp_claim_with_policy(db_path: str, owner_id: str, start_event: object, result_queue: object) -> None:
    """Spawn-safe worker: claim under the policy with an injected fail-open sensor.

    Runs the FULL policy path (expensive job, busy daytime, enough inventory)
    but with an unavailable sensor so the job is claimable via fail-open — the
    point is that the added filter must not weaken single-flight, so exactly one
    of several racing workers may win.
    """
    import pathlib
    from datetime import UTC as _UTC
    from datetime import datetime as _datetime

    import wilted as wilted_mod
    from wilted.db import connect_db as _connect_db
    from wilted.processing_jobs import _claim_next_job_under_lock
    from wilted.scheduling_policy import PolicyThresholds as _PolicyThresholds
    from wilted.station_runtime.machine_availability import MachineAvailability as _MachineAvailability

    wilted_mod.DATA_DIR = pathlib.Path(db_path).parent
    _connect_db(pathlib.Path(db_path))

    unavailable = _MachineAvailability(
        load_per_core=0.0, on_ac_power=False, user_idle_seconds=None, sampled_at="2026-07-25T10:00:00Z", ok=False
    )

    class _Backend:
        def sample(self):
            return unavailable

    start_event.wait()
    try:
        job = _claim_next_job_under_lock(
            owner_id=owner_id,
            lease_seconds=300,
            now=lambda: _datetime(2026, 7, 25, 10, 0, tzinfo=_UTC),
            availability_backend=_Backend(),
            inventory_probe=lambda: 5,
            thresholds=_PolicyThresholds(),
        )
        result_queue.put((owner_id, job.id if job is not None else None))
    except Exception as exc:  # pragma: no cover - surfaced via result queue
        result_queue.put((owner_id, f"error:{exc}"))


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


class TestClaimSeamDeferralPolicy:
    """M3 / INV-12: the claim seam applies the resource-aware deferral filter.

    These exercise the impure seam end-to-end with injected collaborators
    (fake sensor, fixed clock, controllable inventory) — the pure rule matrix
    lives in tests/test_scheduling_policy.py.
    """

    def test_expensive_job_defers_in_busy_daytime_and_stays_queued(self):
        job_id = _submit_expensive(item_id="defer-me")
        _set_created_at(job_id, "2026-07-25T09:00:00Z")  # 1h old, under the ceiling

        claimed = claim_next_job(
            data_dir=wilted.DATA_DIR,
            owner_id="runner",
            now=_fixed_now,
            availability_backend=_FakeAvailabilityBackend(_busy_available()),
            inventory_probe=lambda: 5,
            thresholds=PolicyThresholds(),
        )

        assert claimed is None  # deferred -> nothing claimed
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.QUEUED.value  # left untouched

    def test_cheap_job_behind_deferred_expensive_is_still_claimed(self):
        expensive = _submit_expensive(item_id="expensive-first")
        cheap = _submit_cheap(report_date="2026-07-25")
        # Same priority; expensive ordered first (older created_at). The policy
        # must SKIP the deferred expensive job and claim the cheap one behind it.
        _set_created_at(expensive, "2026-07-25T09:00:00Z")
        _set_created_at(cheap, "2026-07-25T09:30:00Z")

        claimed = claim_next_job(
            data_dir=wilted.DATA_DIR,
            owner_id="runner",
            now=_fixed_now,
            availability_backend=_FakeAvailabilityBackend(_busy_available()),
            inventory_probe=lambda: 5,
            thresholds=PolicyThresholds(),
        )

        assert claimed is not None
        assert claimed.id == cheap
        assert claimed.state == ProcessingJobState.RUNNING.value
        # The skipped expensive job is left QUEUED (no DEFERRED state, no churn).
        assert ProcessingJob.get_by_id(expensive).state == ProcessingJobState.QUEUED.value

    def test_availability_and_inventory_sampled_once_per_attempt(self):
        _submit_expensive(item_id="a")
        _submit_expensive(item_id="b")
        backend = _FakeAvailabilityBackend(_busy_available())
        probe_calls = {"n": 0}

        def _probe() -> int:
            probe_calls["n"] += 1
            return 5

        claim_next_job(
            data_dir=wilted.DATA_DIR,
            owner_id="runner",
            now=_fixed_now,
            availability_backend=backend,
            inventory_probe=_probe,
            thresholds=PolicyThresholds(),
        )

        # Two candidates, but the sensor and inventory are each sampled once.
        assert backend.sample_calls == 1
        assert probe_calls["n"] == 1

    def test_fail_open_runs_expensive_and_logs_one_warning(self, caplog):
        job_id = _submit_expensive(item_id="fail-open")
        _set_created_at(job_id, "2026-07-25T09:00:00Z")

        with caplog.at_level(logging.WARNING, logger="wilted.processing_jobs"):
            claimed = claim_next_job(
                data_dir=wilted.DATA_DIR,
                owner_id="runner",
                now=_fixed_now,
                availability_backend=_FakeAvailabilityBackend(_unavailable()),
                inventory_probe=lambda: 5,
                thresholds=PolicyThresholds(),
            )

        assert claimed is not None
        assert claimed.id == job_id
        assert claimed.state == ProcessingJobState.RUNNING.value
        warnings = [
            r for r in caplog.records if r.levelno == logging.WARNING and "sensor unavailable" in r.message.lower()
        ]
        assert len(warnings) == 1
        assert str(job_id) in warnings[0].message

    def test_fail_open_emits_no_warning_when_job_runs_for_another_reason(self, caplog):
        # Sensor down, but the job runs because it is OUTSIDE the window at
        # 22:00 — the fail-open branch is never reached, so no warning fires.
        job_id = _submit_expensive(item_id="night")
        _set_created_at(job_id, "2026-07-25T21:00:00Z")

        with caplog.at_level(logging.WARNING, logger="wilted.processing_jobs"):
            claimed = claim_next_job(
                data_dir=wilted.DATA_DIR,
                owner_id="runner",
                now=lambda: datetime(2026, 7, 25, 22, 0, tzinfo=UTC),
                availability_backend=_FakeAvailabilityBackend(_unavailable()),
                inventory_probe=lambda: 5,
                thresholds=PolicyThresholds(),
            )

        assert claimed is not None
        assert claimed.id == job_id
        warnings = [r for r in caplog.records if "sensor unavailable" in r.message.lower()]
        assert warnings == []

    @pytest.mark.integration
    def test_single_flight_holds_with_policy_in_force(self):
        """INV-1/2/10: concurrent claims still yield at most one winner with the
        deferral policy active. Four spawned workers race on the same claimable
        (fail-open) expensive job; exactly one CAS-wins."""
        job_id = _submit_expensive(item_id="race-policy")
        _set_created_at(job_id, "2026-07-25T09:00:00Z")
        db_path = str(wilted.DATA_DIR / "wilted.db")

        ctx = multiprocessing.get_context("spawn")
        start_event = ctx.Event()
        result_queue = ctx.Queue()
        processes = [
            ctx.Process(target=_mp_claim_with_policy, args=(db_path, f"owner-{i}", start_event, result_queue))
            for i in range(4)
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
        assert claimed_ids == [job_id]  # exactly one winner, and it is our job
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.RUNNING.value


class TestReadDeferralSummary:
    """M5 (read-only deferral observability): the gatherer mirrors the claim
    seam's READ pattern exactly but claims/locks/mutates nothing.
    """

    def test_summary_reflects_seeded_queue_via_seam_read_pattern(self):
        held = _submit_expensive(item_id="held-1")
        _set_created_at(held, "2026-07-25T09:00:00Z")
        bypassed = _submit_expensive(item_id="bypassed-1", priority=5)
        _set_created_at(bypassed, "2026-07-25T09:00:00Z")
        _submit_cheap(report_date="2026-07-25")

        summary = read_deferral_summary(
            now=_fixed_now,
            availability_backend=_FakeAvailabilityBackend(_busy_available()),
            inventory_probe=lambda: 5,
            thresholds=PolicyThresholds(),
        )

        assert summary.deferred_count == 1
        assert summary.claimable_now_count == 2
        assert summary.by_reason[DeferralReason.DAYTIME_BUSY] == 1
        assert summary.by_reason[DeferralReason.PRIORITY_BYPASS] == 1
        assert summary.by_reason[DeferralReason.NOT_EXPENSIVE] == 1
        assert summary.next_window_open_hour == PolicyThresholds().daytime_end_hour

    def test_availability_and_inventory_sampled_once(self):
        _submit_expensive(item_id="a")
        _submit_expensive(item_id="b")
        backend = _FakeAvailabilityBackend(_busy_available())
        probe_calls = {"n": 0}

        def _probe() -> int:
            probe_calls["n"] += 1
            return 5

        read_deferral_summary(
            now=_fixed_now,
            availability_backend=backend,
            inventory_probe=_probe,
            thresholds=PolicyThresholds(),
        )

        assert backend.sample_calls == 1
        assert probe_calls["n"] == 1

    def test_never_claims_locks_or_mutates_anything(self):
        job_id = _submit_expensive(item_id="untouched")
        _set_created_at(job_id, "2026-07-25T09:00:00Z")

        read_deferral_summary(
            now=_fixed_now,
            availability_backend=_FakeAvailabilityBackend(_busy_available()),
            inventory_probe=lambda: 5,
            thresholds=PolicyThresholds(),
        )

        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.QUEUED.value
        assert job.lease_owner is None
        assert job.attempt_count == 0
        # The execution flock is still free -- a real claim would have to
        # acquire it first; read_deferral_summary never touches it.
        with try_acquire_execution_lock(wilted.DATA_DIR):
            pass

    def test_no_claimable_rows_returns_all_zero_summary(self):
        summary = read_deferral_summary(
            now=_fixed_now,
            availability_backend=_FakeAvailabilityBackend(_busy_available()),
            inventory_probe=lambda: 5,
            thresholds=PolicyThresholds(),
        )
        assert summary.deferred_count == 0
        assert summary.claimable_now_count == 0
        assert dict(summary.by_reason) == {}
