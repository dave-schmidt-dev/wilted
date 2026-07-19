"""ProcessingJob admission repository and metadata safety helpers."""

from __future__ import annotations

import errno
import fcntl
import json
import logging
import os
import re
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING, Any

from peewee import IntegrityError, OperationalError

import wilted
from wilted.background_work.contracts import ArtifactManifest, JobKind, ProcessingJobState, SubmissionOutcome
from wilted.background_work.idempotency import (
    IdempotencyKey,
    ReAdmissionPolicy,
    resolve_recurring_admission,
)
from wilted.background_work.transitions import (
    CancellationOutcome,
    ProcessingJobTransitionError,
    cancel_job,
    reconcile_running_cancel,
    transition_processing_job,
)
from wilted.db import ProcessingJob, ensure_db, now_utc

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path

logger = logging.getLogger(__name__)

MAX_METADATA_BYTES = 4096

_CLAIMABLE_STATES = frozenset(
    {
        ProcessingJobState.QUEUED,
        ProcessingJobState.RETRY,
    }
)

_UNCLAIMED_CANCEL_STATES = frozenset(
    {
        ProcessingJobState.QUEUED,
        ProcessingJobState.RETRY,
        ProcessingJobState.DEFERRED,
    }
)

_TERMINAL_STATES = frozenset(
    {
        ProcessingJobState.COMPLETED,
        ProcessingJobState.FAILED,
        ProcessingJobState.CANCELLED,
    }
)

_LOCKFILE_NAME = ".processing_runner.lock"
_CLAIM_DB_RETRY_ATTEMPTS = 6
_CLAIM_DB_RETRY_DELAY_S = 0.02


class ExecutionLockBusy(OSError):
    """Raised when the per-``DATA_DIR`` execution flock is already held."""


def execution_lock_path(data_dir: Path) -> Path:
    """Return the runner execution lock path beside call-time ``wilted.DATA_DIR``.

    INV-5: ``data_dir`` is supplied by callers; when omitted elsewhere in this
    module, ``wilted.DATA_DIR`` is read at call time rather than import time.
    """
    return data_dir / _LOCKFILE_NAME


@contextmanager
def try_acquire_execution_lock(data_dir: Path) -> Iterator[Path]:
    """Acquire the per-``DATA_DIR`` exclusive non-blocking ``fcntl`` flock.

    Args:
        data_dir: Root data directory that owns the lock file.

    Yields:
        Resolved lock file path.

    Raises:
        ExecutionLockBusy: When another live holder already owns the flock.
    """
    path = execution_lock_path(data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            raise ExecutionLockBusy(
                f"Processing runner execution lock at {path} is held by a live process",
            ) from exc
        raise
    try:
        yield path
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _resolve_data_dir(data_dir: Path | None) -> Path:
    return data_dir if data_dir is not None else wilted.DATA_DIR


def _lease_expires_at(now: str, lease_seconds: int) -> str:
    if lease_seconds <= 0:
        raise ValueError(f"lease_seconds must be > 0, got {lease_seconds}")
    dt = datetime.fromisoformat(now.replace("Z", "+00:00"))
    return (dt.astimezone(UTC) + timedelta(seconds=lease_seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _encode_result_metadata(
    manifest: ArtifactManifest,
    result_metadata: dict[str, Any] | None,
) -> str:
    payload: dict[str, Any] = {
        "manifest": {
            "item_id": manifest.item_id,
            "source_id": manifest.source_id,
            "input_digest": manifest.input_digest,
            "operation_version": manifest.operation_version,
            "model_identity": manifest.model_identity,
            "prompt_identity": manifest.prompt_identity,
            "output_digests": list(manifest.output_digests),
            "completeness_checks": list(manifest.completeness_checks),
        },
    }
    if result_metadata is not None:
        payload["metadata"] = redact_metadata(result_metadata)
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_METADATA_BYTES:
        raise MetadataTooLargeError(
            f"result metadata exceeds {MAX_METADATA_BYTES} bytes after serialization",
        )
    return encoded


def _manifest_from_result_json(result_json: str | None) -> ArtifactManifest | None:
    if not result_json:
        return None
    try:
        doc = json.loads(result_json)
        raw = doc.get("manifest")
        if not isinstance(raw, dict):
            return None
        return ArtifactManifest(
            item_id=raw.get("item_id"),
            source_id=raw.get("source_id"),
            input_digest=raw.get("input_digest", ""),
            operation_version=int(raw.get("operation_version", 1)),
            model_identity=raw.get("model_identity"),
            prompt_identity=raw.get("prompt_identity"),
            output_digests=tuple(raw.get("output_digests") or ()),
            completeness_checks=tuple(raw.get("completeness_checks") or ()),
        )
    except (TypeError, ValueError, json.JSONDecodeError):
        return None


def validate_job_output(manifest: ArtifactManifest, *, nondeterministic: bool = False) -> bool:
    """Return True when ``manifest`` satisfies publication completeness rules.

    Non-deterministic handlers additionally require model and prompt identity so
    output is never accepted solely from digests on disk.
    """
    if not manifest.is_complete:
        return False
    if nondeterministic and (not manifest.model_identity or not manifest.prompt_identity):
        return False
    return True


def _claim_next_job_under_lock(
    *,
    owner_id: str,
    lease_seconds: int,
) -> ProcessingJob | None:
    """Claim the next eligible job assuming the execution flock is already held."""
    last_error: OperationalError | None = None
    for attempt in range(_CLAIM_DB_RETRY_ATTEMPTS):
        try:
            return _claim_next_job_under_lock_once(owner_id=owner_id, lease_seconds=lease_seconds)
        except OperationalError as exc:
            if "locked" not in str(exc).lower():
                raise
            last_error = exc
            time.sleep(_CLAIM_DB_RETRY_DELAY_S * (attempt + 1))
    if last_error is not None:
        raise last_error
    return None


def _claim_next_job_under_lock_once(
    *,
    owner_id: str,
    lease_seconds: int,
) -> ProcessingJob | None:
    ensure_db()
    now = now_utc()
    expires_at = _lease_expires_at(now, lease_seconds)

    with ProcessingJob._meta.database.atomic():
        candidate = (
            ProcessingJob.select()
            .where(
                (ProcessingJob.state.in_([state.value for state in _CLAIMABLE_STATES]))
                & ((ProcessingJob.not_before.is_null()) | (ProcessingJob.not_before <= now))
            )
            .order_by(ProcessingJob.priority.desc(), ProcessingJob.created_at.asc())
            .first()
        )
        if candidate is None:
            return None

        expected_state = candidate.state
        updated = (
            ProcessingJob.update(
                state=ProcessingJobState.RUNNING.value,
                lease_owner=owner_id,
                lease_expires_at=expires_at,
                attempt_count=ProcessingJob.attempt_count + 1,
                started_at=now,
                updated_at=now,
                cancel_requested=False,
            )
            .where(
                (ProcessingJob.id == candidate.id) & (ProcessingJob.state == expected_state),
            )
            .execute()
        )
        if updated != 1:
            return None

        return ProcessingJob.get_by_id(candidate.id)


def count_due_jobs(*, now: str | None = None) -> int:
    """Return persisted queued/retry jobs whose ``not_before`` has elapsed."""
    from wilted.background_work.contracts import ProcessingJobState

    ensure_db()
    resolved_now = now or now_utc()
    return (
        ProcessingJob.select()
        .where(
            (ProcessingJob.state.in_([ProcessingJobState.QUEUED.value, ProcessingJobState.RETRY.value]))
            & ((ProcessingJob.not_before.is_null()) | (ProcessingJob.not_before <= resolved_now))
        )
        .count()
    )


def claim_next_job(
    *,
    data_dir: Path | None = None,
    owner_id: str,
    lease_seconds: int = 300,
) -> ProcessingJob | None:
    """Claim the next eligible queued/retry job under the execution flock.

    Selects the highest-priority oldest eligible row, then CAS-advances it to
    ``running`` with lease evidence and an incremented attempt count.

    Args:
        data_dir: Data directory for the execution flock (defaults to live
            ``wilted.DATA_DIR`` at call time).
        owner_id: Opaque runner identity recorded as ``lease_owner``.
        lease_seconds: Lease duration from claim time.

    Returns:
        The claimed :class:`~wilted.db.ProcessingJob`, or ``None`` when no
        eligible work exists or the CAS loses a race.
    """
    if not owner_id:
        raise ValueError("owner_id must be non-empty")

    resolved_dir = _resolve_data_dir(data_dir)
    with try_acquire_execution_lock(resolved_dir):
        return _claim_next_job_under_lock(owner_id=owner_id, lease_seconds=lease_seconds)


def renew_lease(job_id: int, owner_id: str, lease_seconds: int) -> bool:
    """Extend a running job lease when ``owner_id`` still matches.

    Returns:
        True when exactly one row was updated.
    """
    if not owner_id:
        raise ValueError("owner_id must be non-empty")
    ensure_db()
    now = now_utc()
    expires_at = _lease_expires_at(now, lease_seconds)
    updated = (
        ProcessingJob.update(lease_expires_at=expires_at, updated_at=now)
        .where(
            (ProcessingJob.id == job_id)
            & (ProcessingJob.state == ProcessingJobState.RUNNING.value)
            & (ProcessingJob.lease_owner == owner_id),
        )
        .execute()
    )
    return updated == 1


def request_cancel(job_id: int) -> bool:
    """Cancel an unclaimed job immediately or flag a running job for cooperative stop.

    Returns:
        True when the cancel request was applied.
    """
    ensure_db()
    job = ProcessingJob.get_or_none(ProcessingJob.id == job_id)
    if job is None:
        return False

    state = ProcessingJobState(job.state)
    now = now_utc()

    if state in _UNCLAIMED_CANCEL_STATES:
        try:
            target = cancel_job(state)
        except ProcessingJobTransitionError:
            return False
        updated = (
            ProcessingJob.update(
                state=target.value,
                updated_at=now,
                completed_at=now,
                lease_owner=None,
                lease_expires_at=None,
            )
            .where((ProcessingJob.id == job_id) & (ProcessingJob.state == state.value))
            .execute()
        )
        return updated == 1

    if state is ProcessingJobState.RUNNING:
        updated = (
            ProcessingJob.update(cancel_requested=True, updated_at=now)
            .where(
                (ProcessingJob.id == job_id)
                & (ProcessingJob.state == ProcessingJobState.RUNNING.value)
                & (ProcessingJob.cancel_requested == False),  # noqa: E712
            )
            .execute()
        )
        return updated == 1

    return False


def apply_running_cancel(job_id: int, *, artifact_complete: bool) -> ProcessingJobState:
    """Resolve a running cancel request using published-artifact reconciliation.

    Args:
        job_id: Processing job identifier.
        artifact_complete: Whether a published artifact passed validation.

    Returns:
        Terminal state applied to the job (``completed`` or ``cancelled``).

    Raises:
        ValueError: When the job is missing, not running, or not cancel-requested.
    """
    ensure_db()
    job = ProcessingJob.get_or_none(ProcessingJob.id == job_id)
    if job is None or job.state != ProcessingJobState.RUNNING.value or not job.cancel_requested:
        raise ValueError(f"job {job_id} is not a running cancel-requested job")

    outcome = reconcile_running_cancel(
        cancel_requested=True,
        artifact_published=artifact_complete,
        artifact_valid=artifact_complete,
    )
    target = ProcessingJobState.COMPLETED if outcome is CancellationOutcome.COMPLETED else ProcessingJobState.CANCELLED
    now = now_utc()
    updates: dict[str, Any] = {
        "state": target.value,
        "updated_at": now,
        "completed_at": now,
        "lease_owner": None,
        "lease_expires_at": None,
    }
    updated = (
        ProcessingJob.update(**updates)
        .where(
            (ProcessingJob.id == job_id)
            & (ProcessingJob.state == ProcessingJobState.RUNNING.value)
            & (ProcessingJob.cancel_requested == True),  # noqa: E712
        )
        .execute()
    )
    if updated != 1:
        raise ValueError(f"failed to apply running cancel for job {job_id}")
    return target


def recover_stale_jobs(*, data_dir: Path | None, owner_id: str, now: str) -> int:
    """Reconcile running jobs whose lease expired while the execution flock was free.

    The caller must already hold the execution flock — a free lock proves the
    prior runner is dead. Completed jobs are never modified. When a stored
    result manifest validates, the job is acknowledged as completed instead of
    retried.

    Args:
        data_dir: Reserved for future path-scoped artifact checks (INV-5).
        owner_id: Runner identity recorded on recovered retries.
        now: Current UTC ISO-8601 ``Z`` timestamp.

    Returns:
        Count of jobs transitioned out of stale ``running``.
    """
    _ = _resolve_data_dir(data_dir)
    if not owner_id:
        raise ValueError("owner_id must be non-empty")
    if not now:
        raise ValueError("now must be non-empty")

    ensure_db()
    recovered = 0

    stale_jobs = list(
        ProcessingJob.select().where(
            (ProcessingJob.state == ProcessingJobState.RUNNING.value)
            & (ProcessingJob.lease_expires_at.is_null(False))
            & (ProcessingJob.lease_expires_at < now),
        ),
    )

    for job in stale_jobs:
        if job.state == ProcessingJobState.COMPLETED.value:
            continue

        manifest = _manifest_from_result_json(job.result_json)
        if manifest is not None and validate_job_output(manifest):
            updated = (
                ProcessingJob.update(
                    state=ProcessingJobState.COMPLETED.value,
                    completed_at=now,
                    updated_at=now,
                    lease_owner=None,
                    lease_expires_at=None,
                )
                .where(
                    (ProcessingJob.id == job.id) & (ProcessingJob.state == ProcessingJobState.RUNNING.value),
                )
                .execute()
            )
            if updated == 1:
                recovered += 1
            continue

        if job.attempt_count >= job.max_attempts:
            target = ProcessingJobState.FAILED
        else:
            target = ProcessingJobState.RETRY

        transition_processing_job(ProcessingJobState.RUNNING, target)
        updated = (
            ProcessingJob.update(
                state=target.value,
                updated_at=now,
                started_at=None,
                lease_owner=None,
                lease_expires_at=None,
            )
            .where(
                (ProcessingJob.id == job.id) & (ProcessingJob.state == ProcessingJobState.RUNNING.value),
            )
            .execute()
        )
        if updated == 1:
            recovered += 1
            logger.info(
                "Recovered stale processing job %s -> %s (attempt %s/%s)",
                job.id,
                target.value,
                job.attempt_count,
                job.max_attempts,
            )

    return recovered


def record_job_completion(
    job_id: int,
    owner_id: str,
    manifest: ArtifactManifest,
    result_metadata: dict[str, Any] | None = None,
    *,
    nondeterministic: bool = False,
) -> bool:
    """CAS-advance a running job to ``completed`` after manifest validation.

    Rejects completion when the manifest is incomplete or a cancel request
    reconciles to ``cancelled`` despite published bytes.

    Returns:
        True when exactly one row was updated to ``completed``.
    """
    if not owner_id:
        raise ValueError("owner_id must be non-empty")
    if not validate_job_output(manifest, nondeterministic=nondeterministic):
        return False

    ensure_db()
    job = ProcessingJob.get_or_none(ProcessingJob.id == job_id)
    if job is None:
        return False
    if job.state != ProcessingJobState.RUNNING.value or job.lease_owner != owner_id:
        return False

    if job.cancel_requested:
        outcome = reconcile_running_cancel(
            cancel_requested=True,
            artifact_published=True,
            artifact_valid=True,
        )
        if outcome is CancellationOutcome.CANCELLED:
            return False

    now = now_utc()
    result_json = _encode_result_metadata(manifest, result_metadata)
    updated = (
        ProcessingJob.update(
            state=ProcessingJobState.COMPLETED.value,
            completed_at=now,
            updated_at=now,
            result_json=result_json,
            lease_owner=None,
            lease_expires_at=None,
            cancel_requested=False,
        )
        .where(
            (ProcessingJob.id == job_id)
            & (ProcessingJob.state == ProcessingJobState.RUNNING.value)
            & (ProcessingJob.lease_owner == owner_id),
        )
        .execute()
    )
    return updated == 1


_FORBIDDEN_KEY_PATTERN = re.compile(
    r"(?i)(api[_-]?key|secret|token|password|authorization|credential|bearer)",
)
_URL_PATTERN = re.compile(r"https?://", re.IGNORECASE)
_TRACEBACK_PATTERN = re.compile(r"Traceback \(most recent call last\)", re.IGNORECASE)
_CAUSE_CHAIN_PATTERN = re.compile(r"(?:\s__cause__|\sraise\s+.+\s+from\s+)", re.IGNORECASE)


class MetadataForbiddenError(ValueError):
    """Raised when job metadata contains forbidden content."""


class MetadataTooLargeError(ValueError):
    """Raised when serialized job metadata exceeds the byte bound."""


@dataclass(frozen=True, slots=True)
class SubmitResult:
    """Outcome of one idempotent job submission attempt.

    Attributes:
        outcome: Truthful submission vocabulary for callers.
        job_id: Durable processing job identifier.
        idempotency_key: Canonical idempotency key string.
        created: True when a new row was inserted.
    """

    outcome: SubmissionOutcome
    job_id: int
    idempotency_key: str
    created: bool


def redact_metadata(data: dict[str, Any]) -> dict[str, Any]:
    """Validate metadata and return a JSON-safe copy without forbidden content.

    Rejects values containing URLs, traceback/cause-chain text, and keys or
    string values that resemble secrets or credentials.

    Args:
        data: Candidate metadata dictionary.

    Returns:
        A shallow-validated copy safe to persist in checkpoint/result/error JSON.

    Raises:
        MetadataForbiddenError: When forbidden content is present.
        TypeError: When ``data`` is not a mapping or contains non-JSON types.
    """
    if not isinstance(data, dict):
        raise TypeError("metadata must be a dict")

    def _inspect(value: Any, *, path: str) -> Any:
        if isinstance(value, dict):
            cleaned: dict[str, Any] = {}
            for key, nested in value.items():
                key_text = str(key)
                if _FORBIDDEN_KEY_PATTERN.search(key_text):
                    raise MetadataForbiddenError(f"forbidden metadata key at {path}.{key_text}")
                cleaned[key_text] = _inspect(nested, path=f"{path}.{key_text}")
            return cleaned
        if isinstance(value, list):
            return [_inspect(item, path=f"{path}[{index}]") for index, item in enumerate(value)]
        if value is None or isinstance(value, bool | int | float):
            return value
        if not isinstance(value, str):
            raise TypeError(f"metadata value at {path} must be JSON-serializable")
        if _URL_PATTERN.search(value):
            raise MetadataForbiddenError(f"forbidden URL in metadata at {path}")
        if _TRACEBACK_PATTERN.search(value):
            raise MetadataForbiddenError(f"forbidden traceback in metadata at {path}")
        if _CAUSE_CHAIN_PATTERN.search(value):
            raise MetadataForbiddenError(f"forbidden exception chain in metadata at {path}")
        if _FORBIDDEN_KEY_PATTERN.search(value):
            raise MetadataForbiddenError(f"forbidden secret-like value at {path}")
        return value

    return _inspect(data, path="metadata")


def _encode_metadata(data: dict[str, Any] | None) -> str | None:
    if data is None:
        return None
    cleaned = redact_metadata(data)
    encoded = json.dumps(cleaned, separators=(",", ":"), sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_METADATA_BYTES:
        raise MetadataTooLargeError(
            f"metadata exceeds {MAX_METADATA_BYTES} bytes after serialization ({len(encoded.encode('utf-8'))} bytes)",
        )
    return encoded


def _parse_stored_key(kind_value: str, canonical: str) -> IdempotencyKey:
    kind = JobKind(kind_value)
    prefix = f"{kind.value}:v"
    if not canonical.startswith(prefix):
        raise ValueError(f"Stored idempotency_key does not match kind {kind.value!r}")
    rest = canonical[len(prefix) :]
    version_str, sep, logical_identity = rest.partition(":")
    if not sep or not logical_identity:
        raise ValueError(f"Invalid stored idempotency_key: {canonical!r}")
    return IdempotencyKey(kind=kind, operation_version=int(version_str), logical_identity=logical_identity)


def _state_enum(value: str) -> ProcessingJobState:
    return ProcessingJobState(value)


def _terminal_state(job: ProcessingJob) -> ProcessingJobState | None:
    state = _state_enum(job.state)
    if state in _TERMINAL_STATES:
        return state
    return None


def _outcome_for_existing(
    *,
    existing: ProcessingJob,
    proposed_key: IdempotencyKey,
    now: str,
) -> SubmitResult:
    terminal = _terminal_state(existing)
    if terminal is None:
        return SubmitResult(
            outcome=SubmissionOutcome.BUSY,
            job_id=existing.id,
            idempotency_key=existing.idempotency_key,
            created=False,
        )

    if terminal is ProcessingJobState.COMPLETED:
        return SubmitResult(
            outcome=SubmissionOutcome.COMPLETED,
            job_id=existing.id,
            idempotency_key=existing.idempotency_key,
            created=False,
        )

    prior_key = _parse_stored_key(existing.kind, existing.idempotency_key)
    policy = resolve_recurring_admission(
        prior_key=prior_key,
        proposed_key=proposed_key,
        prior_terminal_state=terminal,
    )

    if policy is ReAdmissionPolicy.RETRY_IN_PLACE:
        _requeue_job(existing.id, now=now)
        logger.info("Re-queued processing job %s after terminal state %s", existing.id, terminal.value)
        return SubmitResult(
            outcome=SubmissionOutcome.SUBMITTED,
            job_id=existing.id,
            idempotency_key=existing.idempotency_key,
            created=False,
        )

    raise ValueError(f"Unexpected re-admission policy {policy!s} for job {existing.id}")


def _requeue_job(job_id: int, *, now: str) -> None:
    """Reset a terminal failed/cancelled job back to ``queued`` for retry-in-place.

    Clears ``attempt_count`` and ``result_json`` in addition to the existing
    lease/timestamp/error resets — a retry-in-place generation starts with a
    clean attempt budget and never carries forward a prior generation's result.
    """
    ProcessingJob.update(
        state=ProcessingJobState.QUEUED.value,
        updated_at=now,
        started_at=None,
        completed_at=None,
        lease_owner=None,
        lease_expires_at=None,
        error_json=None,
        attempt_count=0,
        result_json=None,
    ).where(ProcessingJob.id == job_id).execute()


def _create_job_row(
    *,
    key: IdempotencyKey,
    item_id: int | None,
    priority: int,
    not_before: str | None,
    max_attempts: int,
    checkpoint_json: str | None,
    now: str,
) -> ProcessingJob:
    return ProcessingJob.create(
        idempotency_key=key.canonical,
        kind=key.kind.value,
        item_id=item_id,
        state=ProcessingJobState.QUEUED.value,
        priority=priority,
        not_before=not_before,
        attempt_count=0,
        max_attempts=max_attempts,
        created_at=now,
        updated_at=now,
        checkpoint_json=checkpoint_json,
    )


def submit_job(
    key: IdempotencyKey,
    *,
    item_id: int | None = None,
    priority: int = 0,
    not_before: str | None = None,
    max_attempts: int = 3,
    metadata: dict[str, Any] | None = None,
) -> SubmitResult:
    """Submit one processing job with transactional idempotent admission.

    Concurrent identical submissions converge on one durable row via the
    unique ``idempotency_key`` constraint. Terminal failed/cancelled jobs may
    retry in place; completed jobs with the same key return ``COMPLETED``.

    Args:
        key: Canonical idempotency identity for the work unit.
        item_id: Optional owning item foreign key.
        priority: Scheduler priority (lower runs sooner when tied).
        not_before: Optional UTC ISO-8601 ``Z`` deferral timestamp.
        max_attempts: Maximum execution attempts before terminal failure.
        metadata: Optional checkpoint metadata (validated and size-bounded).

    Returns:
        :class:`SubmitResult` describing the admission outcome.
    """
    ensure_db()
    checkpoint_json = _encode_metadata(metadata)
    now = now_utc()

    existing = ProcessingJob.get_or_none(ProcessingJob.idempotency_key == key.canonical)
    if existing is not None:
        return _outcome_for_existing(existing=existing, proposed_key=key, now=now)

    try:
        with ProcessingJob._meta.database.atomic():
            job = _create_job_row(
                key=key,
                item_id=item_id,
                priority=priority,
                not_before=not_before,
                max_attempts=max_attempts,
                checkpoint_json=checkpoint_json,
                now=now,
            )
    except IntegrityError:
        existing = ProcessingJob.get(ProcessingJob.idempotency_key == key.canonical)
        return _outcome_for_existing(existing=existing, proposed_key=key, now=now)

    logger.info("Submitted processing job %s (%s)", job.id, key.canonical)
    return SubmitResult(
        outcome=SubmissionOutcome.SUBMITTED,
        job_id=job.id,
        idempotency_key=job.idempotency_key,
        created=True,
    )


def get_job(job_id: int) -> ProcessingJob | None:
    """Return one processing job by primary key, or None."""
    ensure_db()
    return ProcessingJob.get_or_none(ProcessingJob.id == job_id)


def get_job_by_key(idempotency_key: str) -> ProcessingJob | None:
    """Return one processing job by canonical idempotency key, or None."""
    ensure_db()
    return ProcessingJob.get_or_none(ProcessingJob.idempotency_key == idempotency_key)


def prune_terminal_jobs(*, older_than_days: int = 14, now: str | None = None) -> int:
    """Delete terminal-state :class:`ProcessingJob` rows older than a cutoff.

    Only rows whose state is a terminal state (``completed``, ``failed``,
    ``cancelled``) with a ``completed_at`` older than ``older_than_days`` are
    removed. Non-terminal rows (``queued``/``running``/``retry``/``deferred``)
    are never candidates regardless of age.

    The removal is a single atomic ``DELETE`` whose ``WHERE`` clause carries
    the full terminal + age predicate. SQLite re-evaluates that predicate at
    delete time, so a row a concurrent writer requeues (``_requeue_job`` sets
    ``state`` back to ``queued`` and clears ``completed_at``) after we decide
    to prune but before the delete lands no longer matches and is left
    untouched — a prune can never remove in-flight work. Filtering inside the
    ``DELETE`` (rather than selecting ids and deleting by ``id.in_(...)``) also
    binds only the constant predicate values, so a large candidate set cannot
    trip SQLite's bound-variable limit and silently no-op the retention sweep.

    Args:
        older_than_days: Age threshold in days from ``now``.
        now: Current UTC ISO-8601 ``Z`` timestamp (defaults to live ``now_utc()``).

    Returns:
        Count of deleted rows.

    Raises:
        ValueError: When ``older_than_days`` is negative.
    """
    if older_than_days < 0:
        raise ValueError(f"older_than_days must be >= 0, got {older_than_days}")

    ensure_db()
    resolved_now = now or now_utc()
    cutoff_dt = datetime.fromisoformat(resolved_now.replace("Z", "+00:00")).astimezone(UTC) - timedelta(
        days=older_than_days,
    )
    cutoff = cutoff_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    terminal_values = [state.value for state in _TERMINAL_STATES]

    deleted = (
        ProcessingJob.delete()
        .where(
            (ProcessingJob.state.in_(terminal_values))
            & (ProcessingJob.completed_at.is_null(False))
            & (ProcessingJob.completed_at < cutoff),
        )
        .execute()
    )
    if deleted:
        logger.info("Pruned %d terminal processing job(s) completed before %s", deleted, cutoff)
    return deleted


def transition_job_state(
    job_id: int,
    expected_state: ProcessingJobState,
    target_state: ProcessingJobState,
) -> bool:
    """CAS-advance one job state when the stored state matches ``expected_state``.

    Args:
        job_id: Processing job identifier.
        expected_state: Required current state for the update to succeed.
        target_state: Desired next state (must be a valid contract edge).

    Returns:
        True when exactly one row was updated, False when the CAS missed.
    """
    ensure_db()
    try:
        transition_processing_job(expected_state, target_state)
    except ProcessingJobTransitionError:
        logger.warning(
            "Rejected invalid processing job transition for job %s: %s -> %s",
            job_id,
            expected_state.value,
            target_state.value,
        )
        raise

    now = now_utc()
    updates: dict[str, Any] = {
        "state": target_state.value,
        "updated_at": now,
    }
    if target_state is ProcessingJobState.RUNNING:
        updates["started_at"] = now
    if target_state in _TERMINAL_STATES:
        updates["completed_at"] = now

    updated = (
        ProcessingJob.update(**updates)
        .where(
            (ProcessingJob.id == job_id) & (ProcessingJob.state == expected_state.value),
        )
        .execute()
    )
    return updated == 1
