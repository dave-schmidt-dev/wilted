"""Unit tests for the checkpoint_json in-flight progress substrate (C-Fork S1).

Covers the namespaced envelope helpers ``read_checkpoint_progress`` and
``merge_checkpoint_progress`` (INV-6 in-flight substrate): the lease fence, the
redaction/size bound, and — critically — that the mutable ``_progress`` envelope
never collides with the flat immutable submission options that ``checkpoint_json``
is the sole carrier of. The OPTIONS-PRESERVED test drives the REAL flat-key
readers, and the retry/recovery tests lock the advisor-fix-2 contract that
``_requeue_job``/``recover_stale_jobs`` preserve the hint unchanged.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.db import ProcessingJob, now_utc
from wilted.handlers._common import handler_options
from wilted.handlers.prepare import _handler_options
from wilted.processing_jobs import (
    MAX_METADATA_BYTES,
    MetadataForbiddenError,
    MetadataTooLargeError,
    _encode_metadata,
    merge_checkpoint_progress,
    read_checkpoint_progress,
    recover_stale_jobs,
)
from wilted.processing_jobs import (
    _requeue_job as requeue_job,
)
from wilted.speech_ready import job_requires_speech

_OWNER = "owner-a"

# Realistic immutable submission options — the flat keys read by
# handlers/_common, handlers/prepare, handlers/classify, and speech_ready.
_OPTIONS = {
    "operation_version": 2,
    "use_llm": False,
    "skip_tts": True,
    "llm_model": "gemma-3",
    "llm_backend_type": "mlx",
}


def _make_job(
    *,
    state: ProcessingJobState = ProcessingJobState.RUNNING,
    lease_owner: str | None = _OWNER,
    checkpoint_json: str | None = None,
    lease_expires_at: str | None = None,
    attempt_count: int = 0,
    max_attempts: int = 3,
    key_suffix: str = "ckpt",
) -> ProcessingJob:
    now = now_utc()
    return ProcessingJob.create(
        idempotency_key=f"{JobKind.PREPARE.value}:v1:checkpoint-test:{key_suffix}",
        kind=JobKind.PREPARE.value,
        state=state.value,
        priority=0,
        attempt_count=attempt_count,
        max_attempts=max_attempts,
        created_at=now,
        updated_at=now,
        started_at=now if state is ProcessingJobState.RUNNING else None,
        lease_owner=lease_owner,
        lease_expires_at=lease_expires_at,
        checkpoint_json=checkpoint_json,
    )


def _options_checkpoint(**extra) -> str:
    payload = {**_OPTIONS, **extra}
    encoded = _encode_metadata(payload)
    assert encoded is not None
    return encoded


# ---------------------------------------------------------------------------
# merge_checkpoint_progress — happy path & merge semantics
# ---------------------------------------------------------------------------


class TestMergeHappyPath:
    def test_options_preserved_progress_merged_version_stamped(self):
        job = _make_job(checkpoint_json=_options_checkpoint())

        assert merge_checkpoint_progress(job.id, _OWNER, {"stage": "transcribed", "word_count": 100}) is True

        payload = json.loads(ProcessingJob.get_by_id(job.id).checkpoint_json)
        # Flat options survive untouched.
        for key, value in _OPTIONS.items():
            assert payload[key] == value
        # Progress landed under the reserved key with the version marker.
        assert payload["_progress"] == {"stage": "transcribed", "word_count": 100}
        assert payload["_checkpoint_v"] == 2

    def test_successive_merges_union_keys_later_wins(self):
        job = _make_job(checkpoint_json=_options_checkpoint())

        assert merge_checkpoint_progress(job.id, _OWNER, {"a": 1, "stage": "x"}) is True
        assert merge_checkpoint_progress(job.id, _OWNER, {"b": 2, "stage": "y"}) is True

        progress = read_checkpoint_progress(ProcessingJob.get_by_id(job.id))
        assert progress == {"a": 1, "b": 2, "stage": "y"}

    def test_merge_onto_legacy_options_only_record(self):
        # A v1 record (flat options, no envelope marker) gains the envelope.
        job = _make_job(checkpoint_json=json.dumps(_OPTIONS))

        assert merge_checkpoint_progress(job.id, _OWNER, {"stage": "started"}) is True

        payload = json.loads(ProcessingJob.get_by_id(job.id).checkpoint_json)
        assert payload["operation_version"] == 2
        assert payload["_progress"] == {"stage": "started"}
        assert payload["_checkpoint_v"] == 2


# ---------------------------------------------------------------------------
# merge_checkpoint_progress — lease fence & owner guard
# ---------------------------------------------------------------------------


class TestMergeFence:
    def test_wrong_owner_returns_false_and_leaves_checkpoint_unchanged(self):
        original = _options_checkpoint()
        job = _make_job(checkpoint_json=original, lease_owner="owner-a")

        assert merge_checkpoint_progress(job.id, "owner-b", {"stage": "x"}) is False
        assert ProcessingJob.get_by_id(job.id).checkpoint_json == original

    def test_non_running_state_returns_false_and_leaves_checkpoint_unchanged(self):
        original = _options_checkpoint()
        job = _make_job(state=ProcessingJobState.QUEUED, lease_owner=_OWNER, checkpoint_json=original)

        assert merge_checkpoint_progress(job.id, _OWNER, {"stage": "x"}) is False
        assert ProcessingJob.get_by_id(job.id).checkpoint_json == original

    def test_missing_job_returns_false(self):
        assert merge_checkpoint_progress(999_999, _OWNER, {"stage": "x"}) is False

    def test_falsy_owner_raises_value_error(self):
        job = _make_job(checkpoint_json=_options_checkpoint())
        with pytest.raises(ValueError, match="owner_id"):
            merge_checkpoint_progress(job.id, "", {"stage": "x"})


# ---------------------------------------------------------------------------
# merge_checkpoint_progress — redaction & size bound (via _encode_metadata)
# ---------------------------------------------------------------------------


class TestMergeRedactionAndSize:
    def test_forbidden_value_raises_metadata_forbidden(self):
        job = _make_job(checkpoint_json=_options_checkpoint())
        with pytest.raises(MetadataForbiddenError):
            merge_checkpoint_progress(job.id, _OWNER, {"source": "https://leak.example.com/path"})

    def test_oversized_progress_raises_metadata_too_large(self):
        job = _make_job(checkpoint_json=_options_checkpoint())
        with pytest.raises(MetadataTooLargeError):
            merge_checkpoint_progress(job.id, _OWNER, {"blob": "x" * (MAX_METADATA_BYTES + 64)})


# ---------------------------------------------------------------------------
# read_checkpoint_progress
# ---------------------------------------------------------------------------


class TestReadCheckpointProgress:
    def test_legacy_flat_record_returns_empty(self):
        job = _make_job(checkpoint_json=json.dumps(_OPTIONS))
        assert read_checkpoint_progress(job) == {}

    def test_envelope_record_returns_progress(self):
        job = _make_job(checkpoint_json=_options_checkpoint())
        merge_checkpoint_progress(job.id, _OWNER, {"stage": "transcribed", "coverage_ratio": 0.83})
        assert read_checkpoint_progress(ProcessingJob.get_by_id(job.id)) == {
            "stage": "transcribed",
            "coverage_ratio": 0.83,
        }

    def test_malformed_checkpoint_returns_empty(self):
        # The DB CHECK constraint (json_valid) forbids persisting malformed JSON,
        # so exercise the parser's error path with a stand-in carrying the field.
        assert read_checkpoint_progress(SimpleNamespace(checkpoint_json="{not valid json")) == {}

    def test_none_checkpoint_returns_empty(self):
        job = _make_job(checkpoint_json=None)
        assert read_checkpoint_progress(job) == {}

    def test_non_dict_progress_returns_empty(self):
        job = _make_job(checkpoint_json=json.dumps({**_OPTIONS, "_progress": ["not", "a", "dict"]}))
        assert read_checkpoint_progress(job) == {}


# ---------------------------------------------------------------------------
# OPTIONS-PRESERVED regression — the critical collision guard.
# After a progress merge, the REAL flat-key readers must still see the options.
# ---------------------------------------------------------------------------


class TestOptionsPreservedRegression:
    def test_real_readers_see_options_after_merge(self):
        job = _make_job(checkpoint_json=_options_checkpoint())

        assert merge_checkpoint_progress(job.id, _OWNER, {"stage": "transcribed", "word_count": 42}) is True
        job = ProcessingJob.get_by_id(job.id)

        # handlers/_common.handler_options — reads the whole flat payload.
        common_opts = handler_options(job)
        assert int(common_opts.get("operation_version", 1)) == 2
        assert bool(common_opts.get("use_llm", True)) is False
        assert bool(common_opts.get("skip_tts", False)) is True
        assert common_opts.get("llm_model") == "gemma-3"
        assert common_opts.get("llm_backend_type") == "mlx"

        # handlers/prepare._handler_options — same flat contract.
        prepare_opts = _handler_options(job)
        assert bool(prepare_opts.get("skip_tts", False)) is True
        assert prepare_opts.get("llm_backend_type") == "mlx"

        # speech_ready.job_requires_speech — reads skip_tts flat.
        assert (
            job_requires_speech(
                kind=JobKind.PREPARE,
                checkpoint_json=job.checkpoint_json,
                item_type="article",
            )
            is False
        )

    def test_progress_key_named_like_an_option_cannot_shadow_flat_option(self):
        # Namespacing under _progress means even a colliding key name is isolated:
        # the flat top-level option the readers consume is unchanged.
        job = _make_job(checkpoint_json=_options_checkpoint())

        assert merge_checkpoint_progress(job.id, _OWNER, {"operation_version": 999}) is True
        job = ProcessingJob.get_by_id(job.id)

        assert int(handler_options(job).get("operation_version", 1)) == 2
        assert read_checkpoint_progress(job) == {"operation_version": 999}


# ---------------------------------------------------------------------------
# Retry/recovery PRESERVE the hint (advisor fix 2). We do NOT change these
# functions — these tests lock their existing behavior: both the flat options
# and the _progress hint survive a requeue / stale-recovery unchanged.
# ---------------------------------------------------------------------------


class TestRetryRecoveryPreserveHint:
    def test_requeue_job_preserves_options_and_progress(self):
        # Write the envelope through the real writer, then drop to a terminal
        # state so _requeue_job's retry-in-place path applies.
        job = _make_job(checkpoint_json=_options_checkpoint())
        merge_checkpoint_progress(job.id, _OWNER, {"stage": "transcribed", "word_count": 7})
        before = ProcessingJob.get_by_id(job.id).checkpoint_json
        ProcessingJob.update(
            state=ProcessingJobState.FAILED.value,
            lease_owner=None,
            lease_expires_at=None,
        ).where(ProcessingJob.id == job.id).execute()

        requeue_job(job.id, now=now_utc())

        requeued = ProcessingJob.get_by_id(job.id)
        assert requeued.state == ProcessingJobState.QUEUED.value
        assert requeued.checkpoint_json == before  # byte-for-byte preserved
        assert handler_options(requeued)["operation_version"] == 2
        assert read_checkpoint_progress(requeued) == {"stage": "transcribed", "word_count": 7}

    def test_recover_stale_jobs_preserves_options_and_progress(self):
        job = _make_job(checkpoint_json=_options_checkpoint())
        merge_checkpoint_progress(job.id, _OWNER, {"stage": "transcribed", "word_count": 7})
        before = ProcessingJob.get_by_id(job.id).checkpoint_json
        # Expire the lease so recover_stale_jobs reconciles RUNNING -> RETRY.
        past = "2000-01-01T00:00:00Z"
        ProcessingJob.update(lease_expires_at=past).where(ProcessingJob.id == job.id).execute()

        recovered = recover_stale_jobs(data_dir=wilted.DATA_DIR, owner_id=_OWNER, now=now_utc())

        assert recovered == 1
        job_after = ProcessingJob.get_by_id(job.id)
        assert job_after.state == ProcessingJobState.RETRY.value
        assert job_after.checkpoint_json == before  # preserved unchanged
        assert handler_options(job_after)["operation_version"] == 2
        assert read_checkpoint_progress(job_after) == {"stage": "transcribed", "word_count": 7}
