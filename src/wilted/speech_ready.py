"""Speech daemon readiness gate and runnable-job speech policy."""

from __future__ import annotations

import json
import logging

from speech_stack import client

from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.db import Item, ProcessingJob, ensure_db, now_utc

logger = logging.getLogger(__name__)

_SPEECH_KINDS = frozenset({JobKind.ARTICLE_CACHE, JobKind.COMPACT_BRIEFING})
_NON_SPEECH_KINDS = frozenset({JobKind.DISCOVER, JobKind.CLASSIFY, JobKind.REPORT_ASSEMBLY})


def require_speech_ready() -> None:
    """Ensure the speech daemon is reachable before TTS/STT engine use."""
    client.require_daemon_ready(probe=True)


def job_requires_speech(
    *,
    kind: JobKind | str,
    checkpoint_json: str | None = None,
    item_type: str | None = None,
) -> bool:
    """Return whether one processing job can require the speech stack.

    Args:
        kind: Job kind value or enum.
        checkpoint_json: Serialized job checkpoint metadata for prepare jobs.
        item_type: Optional item type for prepare jobs (``article`` / ``podcast_episode``).

    Returns:
        True when the job may invoke TTS or tier-3 STT.
    """
    resolved_kind = JobKind(kind) if not isinstance(kind, JobKind) else kind

    if resolved_kind in _NON_SPEECH_KINDS:
        return False
    if resolved_kind in _SPEECH_KINDS:
        return True
    if resolved_kind is not JobKind.PREPARE:
        return False

    # Podcast prepare is conservatively speech-capable (tier-3 STT may be needed).
    if item_type == "podcast_episode":
        return True

    metadata: dict[str, object] = {}
    if checkpoint_json:
        try:
            payload = json.loads(checkpoint_json)
            if isinstance(payload, dict):
                metadata = payload
        except json.JSONDecodeError:
            logger.warning("Ignoring invalid checkpoint_json for speech policy")

    skip_tts = bool(metadata.get("skip_tts", False))
    if item_type == "article" and skip_tts:
        return False
    return True


def _due_runnable_jobs_query(*, kind: JobKind | None = None, now: str | None = None):
    """Build a query for jobs matching claim eligibility predicates."""
    resolved_now = now or now_utc()
    query = ProcessingJob.select().where(
        (ProcessingJob.state.in_([ProcessingJobState.QUEUED.value, ProcessingJobState.RETRY.value]))
        & ((ProcessingJob.not_before.is_null()) | (ProcessingJob.not_before <= resolved_now))
    )
    if kind is not None:
        query = query.where(ProcessingJob.kind == kind.value)
    return query


def runnable_cohort_requires_speech(*, kind: JobKind | None = None, now: str | None = None) -> bool:
    """Return whether any due runnable job in the cohort can require speech.

    Args:
        kind: Optional kind filter mirroring ``drain_runner`` scoping.
        now: Optional UTC timestamp override for tests.

    Returns:
        True when at least one claimable job in the cohort requires speech readiness.
    """
    ensure_db()
    for job in _due_runnable_jobs_query(kind=kind, now=now):
        item_type: str | None = None
        if job.item_id is not None:
            item = Item.get_or_none(Item.id == job.item_id)
            if item is not None:
                item_type = item.item_type
        if job_requires_speech(
            kind=job.kind,
            checkpoint_json=job.checkpoint_json,
            item_type=item_type,
        ):
            return True
    return False
