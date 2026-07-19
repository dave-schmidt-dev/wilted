"""Submit pipeline stages to the durable processing-job ledger."""

from __future__ import annotations

import json
import logging
from collections.abc import Callable  # noqa: TC003
from typing import Any

from wilted.background_work.contracts import (
    AnalysisState,
    JobKind,
    PreparationState,
    ProcessingJobState,
    SubmissionOutcome,
)
from wilted.background_work.idempotency import IdempotencyKey, build_idempotency_key, logical_identity_for_kind
from wilted.content_state import items_for_prepare, items_pending_classification, read_content_state
from wilted.db import Item, ProcessingJob, ensure_db
from wilted.pipeline_runner import PipelineRunner, RunStats
from wilted.processing_jobs import SubmitResult, get_job_by_key, submit_job
from wilted.speech_ready import require_speech_ready, runnable_cohort_requires_speech
from wilted.station_runtime.coordinator import RuntimeBootstrap

logger = logging.getLogger(__name__)

_DEFAULT_MAX_JOBS_PER_RUN = 8


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _classify_metadata(
    *,
    operation_version: int,
    model: str | None = None,
    backend_type: str | None = None,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {"operation_version": operation_version}
    if model is not None:
        metadata["model"] = model
    if backend_type is not None:
        metadata["backend_type"] = backend_type
    return metadata


def _prepare_metadata(
    *,
    operation_version: int,
    use_llm: bool = True,
    llm_model: str | None = None,
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "operation_version": operation_version,
        "use_llm": use_llm,
        "llm_backend_type": llm_backend_type,
        "skip_tts": skip_tts,
    }
    if llm_model is not None:
        metadata["llm_model"] = llm_model
    return metadata


def _has_runnable_jobs(*, kind: JobKind | None = None, now: str | None = None) -> bool:
    """Return whether any claimable (due) queued/retry job exists.

    Aligns with ``processing_jobs`` claim predicates: state in queued/retry and
    ``not_before`` null or elapsed. Matches ``speech_ready._due_runnable_jobs_query``.
    """
    from wilted.db import now_utc

    ensure_db()
    resolved_now = now or now_utc()
    query = ProcessingJob.select().where(
        (ProcessingJob.state.in_((ProcessingJobState.QUEUED.value, ProcessingJobState.RETRY.value)))
        & ((ProcessingJob.not_before.is_null()) | (ProcessingJob.not_before <= resolved_now))
    )
    if kind is not None:
        query = query.where(ProcessingJob.kind == kind.value)
    return query.exists()


def _merge_stats(accum: RunStats, batch: RunStats) -> RunStats:
    return RunStats(
        submitted_handled=accum.submitted_handled + batch.submitted_handled,
        failed=accum.failed + batch.failed,
        cancelled=accum.cancelled + batch.cancelled,
        deferred_yield=accum.deferred_yield + batch.deferred_yield,
    )


def _submit_fresh_generation(
    key_for_version: Callable[[int], IdempotencyKey],
    *,
    metadata: dict[str, Any],
    item_id: int | None = None,
) -> SubmitResult:
    """Admit a new generation, bumping ``operation_version`` past terminal completed rows."""
    for operation_version in range(1, 65):
        versioned_metadata = {**metadata, "operation_version": operation_version}
        result = submit_job(
            key_for_version(operation_version),
            item_id=item_id,
            metadata=versioned_metadata,
        )
        if result.outcome is not SubmissionOutcome.COMPLETED:
            return result
    raise RuntimeError("could not admit a fresh processing job generation")


def _article_cache_metadata(
    *,
    operation_version: int,
    voice: str,
    lang: str,
    speed: float,
    added: str,
) -> dict[str, Any]:
    return {
        "operation_version": operation_version,
        "voice": voice,
        "lang": lang,
        "speed": speed,
        "added": added,
    }


def items_needing_article_cache(
    *,
    voice: str,
    lang: str,
    speed: float,
) -> list[dict]:
    """Return queue entries that still need per-paragraph audio cache.

    Args:
        voice: TTS voice id stored on submitted jobs.
        lang: Language code stored on submitted jobs.
        speed: Playback speed stored on submitted jobs.

    Returns:
        Queue entry dicts from the All playlist lacking valid cache.
    """
    from wilted.cache import is_cache_valid
    from wilted.playlists import get_playlist_items
    from wilted.queue import get_article_text

    ensure_db()
    try:
        queue = get_playlist_items("All")
    except ValueError:
        return []

    needing: list[dict] = []
    for entry in queue:
        if entry.get("audio_file"):
            continue
        article_id = entry["id"]
        added = entry.get("added", "")
        if is_cache_valid(article_id, voice, lang, speed, added):
            continue
        if not get_article_text(entry):
            continue
        needing.append(entry)
    return needing


def drain_runner(
    *,
    kind: JobKind | None = None,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
    station_active_check: Callable[[], bool] | None = None,
) -> RunStats:
    """Run the pipeline runner until no runnable jobs remain for ``kind``."""
    accum = RunStats()
    if not _has_runnable_jobs(kind=kind):
        return accum

    station_deferred = station_active_check is not None and station_active_check()
    if not station_deferred and runnable_cohort_requires_speech(kind=kind):
        require_speech_ready()

    runner = PipelineRunner(
        bootstrap=_ready_bootstrap(),
        max_jobs_per_run=max_jobs_per_run,
        station_active_check=station_active_check,
    )
    while _has_runnable_jobs(kind=kind):
        result = runner.run()
        accum = _merge_stats(accum, result.stats)
        if result.exit_reason.value in {"lock_busy", "deferred_yield", "stopped", "error"}:
            break
        if result.stats.submitted_handled == 0 and result.stats.failed == 0 and result.stats.cancelled == 0:
            break
    return accum


def submit_classify(
    *,
    item_id: int | None = None,
    operation_version: int = 1,
    model: str | None = None,
    backend_type: str | None = None,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> SubmitResult:
    """Submit one or all pending classification jobs.

    When ``item_id`` is omitted, submits jobs for every item returned by
    :func:`~wilted.content_state.items_pending_classification`.

    Args:
        item_id: Optional single item to classify.
        operation_version: Handler/input version for idempotency.
        model: Optional LLM model override stored in job metadata.
        backend_type: Optional backend override stored in job metadata.
        sync_run: When True, drain the runner synchronously after submission.
        max_jobs_per_run: Bounded drain batch size when ``sync_run`` is True.

    Returns:
        The last :class:`~wilted.processing_jobs.SubmitResult` from admission.
    """
    ensure_db()
    metadata = _classify_metadata(
        operation_version=operation_version,
        model=model,
        backend_type=backend_type,
    )

    if item_id is not None:
        item_ids = [item_id]
    else:
        item_ids = [item.id for item in items_pending_classification()]

    if not item_ids:
        raise ValueError("no items pending classification")

    result: SubmitResult | None = None
    for resolved_item_id in item_ids:
        identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=str(resolved_item_id))
        key = build_idempotency_key(
            JobKind.CLASSIFY,
            operation_version=operation_version,
            logical_identity=identity,
        )
        result = submit_job(key, item_id=resolved_item_id, metadata=metadata)

    assert result is not None
    if sync_run:
        drain_runner(kind=JobKind.CLASSIFY, max_jobs_per_run=max_jobs_per_run)
    return result


def submit_prepare(
    item_id: int,
    *,
    operation_version: int = 1,
    use_llm: bool = True,
    llm_model: str | None = None,
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> SubmitResult:
    """Submit one preparation job for ``item_id``.

    Args:
        item_id: Item to prepare.
        operation_version: Handler/input version for idempotency.
        use_llm: Whether to load an LLM for ad/promo detection.
        llm_model: Optional LLM model override stored in job metadata.
        llm_backend_type: Backend type stored in job metadata.
        skip_tts: Skip TTS generation for articles (testing seam).
        sync_run: When True, drain the runner synchronously after submission.
        max_jobs_per_run: Bounded drain batch size when ``sync_run`` is True.

    Returns:
        :class:`~wilted.processing_jobs.SubmitResult` from admission.
    """
    ensure_db()
    metadata = _prepare_metadata(
        operation_version=operation_version,
        use_llm=use_llm,
        llm_model=llm_model,
        llm_backend_type=llm_backend_type,
        skip_tts=skip_tts,
    )
    identity = logical_identity_for_kind(JobKind.PREPARE, item_id=str(item_id))
    key = build_idempotency_key(
        JobKind.PREPARE,
        operation_version=operation_version,
        logical_identity=identity,
    )
    result = submit_job(key, item_id=item_id, metadata=metadata)
    if sync_run:
        drain_runner(kind=JobKind.PREPARE, max_jobs_per_run=max_jobs_per_run)
    return result


def _classify_stats_for_items(items: list[Item]) -> dict[str, int]:
    classified = 0
    errors = 0
    for item in items:
        item = Item.get_by_id(item.id)
        state = read_content_state(item)
        if state and state.analysis is AnalysisState.READY:
            classified += 1
        elif state and state.analysis is AnalysisState.ERROR:
            errors += 1
    return {"classified": classified, "errors": errors, "total": len(items)}


def run_classify_via_runner(
    *,
    model: str | None = None,
    backend_type: str | None = None,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> dict[str, int]:
    """Submit pending classification jobs and drain the runner synchronously.

    Returns:
        Dict with ``classified``, ``errors``, and ``total`` counts.
    """
    items = items_pending_classification()
    if not items:
        logger.info("No fetched items to classify")
        return {"classified": 0, "errors": 0, "total": 0}

    for item in items:
        submit_classify(
            item_id=item.id,
            model=model,
            backend_type=backend_type,
            sync_run=False,
        )

    drain_runner(kind=JobKind.CLASSIFY, max_jobs_per_run=max_jobs_per_run)
    return _classify_stats_for_items(items)


def _prepare_stats_for_items(items: list[Item]) -> dict[str, int]:
    prepared = 0
    errors = 0
    for item in items:
        item = Item.get_by_id(item.id)
        state = read_content_state(item)
        if state and state.preparation is PreparationState.READY:
            prepared += 1
        elif state and state.preparation is PreparationState.ERROR:
            errors += 1
    return {"prepared": prepared, "errors": errors, "skipped": 0}


def run_prepare_via_runner(
    *,
    use_llm: bool = True,
    llm_model: str | None = None,
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> dict[str, int]:
    """Submit prepare jobs for selected items and drain the runner synchronously.

    Returns:
        Dict with ``prepared``, ``errors``, and ``skipped`` counts.
    """
    items = items_for_prepare()
    if not items:
        logger.info("No selected items to prepare")
        return {"prepared": 0, "errors": 0, "skipped": 0}

    for item in items:
        submit_prepare(
            item.id,
            use_llm=use_llm,
            llm_model=llm_model,
            llm_backend_type=llm_backend_type,
            skip_tts=skip_tts,
            sync_run=False,
        )

    drain_runner(kind=JobKind.PREPARE, max_jobs_per_run=max_jobs_per_run)
    return _prepare_stats_for_items(items)


def submit_article_cache(
    item_id: int,
    *,
    voice: str,
    lang: str,
    speed: float,
    added: str,
    operation_version: int = 1,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
    station_active_check: Callable[[], bool] | None = None,
) -> SubmitResult:
    """Submit one article-cache generation job for ``item_id``.

    Args:
        item_id: Queue article id to cache.
        voice: TTS voice id for cache generation.
        lang: Language code for cache generation.
        speed: Playback speed for cache generation.
        added: Article added timestamp used for cache invalidation.
        operation_version: Handler/input version for idempotency.
        sync_run: When True, drain the runner synchronously after submission.
        max_jobs_per_run: Bounded drain batch size when ``sync_run`` is True.
        station_active_check: Optional yield seam forwarded to the runner drain.

    Returns:
        :class:`~wilted.processing_jobs.SubmitResult` from admission.
    """
    ensure_db()
    metadata = _article_cache_metadata(
        operation_version=operation_version,
        voice=voice,
        lang=lang,
        speed=speed,
        added=added,
    )
    identity = logical_identity_for_kind(JobKind.ARTICLE_CACHE, item_id=str(item_id))
    key = build_idempotency_key(
        JobKind.ARTICLE_CACHE,
        operation_version=operation_version,
        logical_identity=identity,
    )
    result = submit_job(key, item_id=item_id, metadata=metadata)
    if sync_run:
        drain_runner(
            kind=JobKind.ARTICLE_CACHE,
            max_jobs_per_run=max_jobs_per_run,
            station_active_check=station_active_check,
        )
    return result


def submit_pending_article_cache_jobs(
    *,
    voice: str,
    lang: str,
    speed: float,
    operation_version: int = 1,
) -> int:
    """Submit article-cache jobs for every queue item that still needs cache.

    Returns:
        Count of jobs submitted.
    """
    submitted = 0
    for entry in items_needing_article_cache(voice=voice, lang=lang, speed=speed):
        submit_article_cache(
            entry["id"],
            voice=voice,
            lang=lang,
            speed=speed,
            added=entry.get("added", ""),
            operation_version=operation_version,
            sync_run=False,
        )
        submitted += 1
    return submitted


def _article_cache_stats_for_entries(entries: list[dict], *, voice: str, lang: str, speed: float) -> dict[str, int]:
    from wilted.cache import is_cache_valid

    cached = 0
    errors = 0
    for entry in entries:
        article_id = entry["id"]
        added = entry.get("added", "")
        if is_cache_valid(article_id, voice, lang, speed, added):
            cached += 1
        else:
            errors += 1
    return {"cached": cached, "errors": errors, "total": len(entries)}


def run_article_cache_via_runner(
    *,
    voice: str = "af_heart",
    lang: str = "a",
    speed: float = 1.0,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
    station_active_check: Callable[[], bool] | None = None,
) -> dict[str, int]:
    """Submit article-cache jobs for queued items and drain the runner synchronously.

    Returns:
        Dict with ``cached``, ``errors``, and ``total`` counts.
    """
    entries = items_needing_article_cache(voice=voice, lang=lang, speed=speed)
    if not entries:
        logger.info("No queue items need article cache generation")
        return {"cached": 0, "errors": 0, "total": 0}

    submit_pending_article_cache_jobs(voice=voice, lang=lang, speed=speed)
    drain_runner(
        kind=JobKind.ARTICLE_CACHE,
        max_jobs_per_run=max_jobs_per_run,
        station_active_check=station_active_check,
    )
    return _article_cache_stats_for_entries(entries, voice=voice, lang=lang, speed=speed)


def _discover_metadata(*, feed_id: int, operation_version: int = 1) -> dict[str, Any]:
    return {"feed_id": feed_id, "operation_version": operation_version}


def _report_metadata(*, report_date: str, operation_version: int = 1) -> dict[str, Any]:
    return {"report_date": report_date, "operation_version": operation_version}


def _briefing_metadata(
    *,
    window_start: str,
    window_end: str,
    operation_version: int = 1,
) -> dict[str, Any]:
    return {
        "window_start": window_start,
        "window_end": window_end,
        "operation_version": operation_version,
    }


def submit_discover(
    feed_id: int,
    *,
    operation_version: int = 1,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> SubmitResult:
    """Submit one per-feed discovery job."""
    ensure_db()
    metadata = _discover_metadata(feed_id=feed_id, operation_version=operation_version)
    identity = logical_identity_for_kind(JobKind.DISCOVER, feed_id=feed_id)

    def _key_for_version(version: int) -> IdempotencyKey:
        return build_idempotency_key(
            JobKind.DISCOVER,
            operation_version=version,
            logical_identity=identity,
        )

    result = _submit_fresh_generation(_key_for_version, metadata=metadata)
    if sync_run:
        drain_runner(kind=JobKind.DISCOVER, max_jobs_per_run=max_jobs_per_run)
    return result


def submit_report(
    *,
    report_date: str | None = None,
    operation_version: int = 1,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> SubmitResult:
    """Submit one report assembly job for ``report_date`` (defaults to today)."""
    from wilted.report import _local_date_str

    ensure_db()
    resolved_date = report_date or _local_date_str()
    metadata = _report_metadata(report_date=resolved_date, operation_version=operation_version)
    identity = logical_identity_for_kind(JobKind.REPORT_ASSEMBLY, report_date=resolved_date)

    def _key_for_version(version: int) -> IdempotencyKey:
        return build_idempotency_key(
            JobKind.REPORT_ASSEMBLY,
            operation_version=version,
            logical_identity=identity,
        )

    result = _submit_fresh_generation(_key_for_version, metadata=metadata)
    if sync_run:
        drain_runner(kind=JobKind.REPORT_ASSEMBLY, max_jobs_per_run=max_jobs_per_run)
    return result


def submit_briefing(
    *,
    window_start: str,
    window_end: str,
    operation_version: int = 1,
    sync_run: bool = False,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> SubmitResult:
    """Submit one compact briefing generation job."""
    ensure_db()
    metadata = _briefing_metadata(
        window_start=window_start,
        window_end=window_end,
        operation_version=operation_version,
    )
    identity = logical_identity_for_kind(
        JobKind.COMPACT_BRIEFING,
        window_start=window_start,
        window_end=window_end,
    )
    key = build_idempotency_key(
        JobKind.COMPACT_BRIEFING,
        operation_version=operation_version,
        logical_identity=identity,
    )
    result = submit_job(key, metadata=metadata)
    if sync_run:
        drain_runner(kind=JobKind.COMPACT_BRIEFING, max_jobs_per_run=max_jobs_per_run)
    return result


def run_discover_via_runner(
    *,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> dict[str, int]:
    """Submit discovery jobs for all enabled feeds and drain the runner.

    Captures each feed's exact submitted idempotency key before the drain,
    then reads that same key back afterward — never re-derives an identity,
    which could silently pick up a different day's or a stale row. A feed
    counts toward ``discovered``/``errors`` only when its own job reached a
    terminal ``completed`` state with a non-empty result. Anything else
    (still busy, lock contention, not yet drained) is tallied under
    ``unknown`` rather than assumed to be zero, so aggregate counts never
    silently under-report.

    Returns:
        Dict with ``discovered``, ``feeds_polled``, ``errors``, and ``unknown`` counts.
    """
    from wilted.db import Feed

    ensure_db()
    feeds = list(Feed.select().where(Feed.enabled == True))  # noqa: E712
    if not feeds:
        logger.info("No enabled feeds to poll")
        return {"discovered": 0, "feeds_polled": 0, "errors": 0, "unknown": 0}

    submitted_keys: dict[int, str] = {}
    for feed in feeds:
        result = submit_discover(feed.id, sync_run=False)
        submitted_keys[feed.id] = result.idempotency_key

    drain_runner(kind=JobKind.DISCOVER, max_jobs_per_run=max_jobs_per_run)

    discovered = 0
    errors = 0
    unknown = 0
    for feed in feeds:
        job = get_job_by_key(submitted_keys[feed.id])
        if job is None or job.state != ProcessingJobState.COMPLETED.value or not job.result_json:
            unknown += 1
            continue
        try:
            payload = json.loads(job.result_json)
        except json.JSONDecodeError:
            unknown += 1
            continue
        meta = payload.get("metadata")
        if not isinstance(meta, dict):
            unknown += 1
            continue
        discovered += int(meta.get("discovered", 0))
        errors += int(meta.get("errors", 0))

    if unknown:
        logger.warning(
            "Discovery outcome unknown for %d of %d feed(s) (not drained to completion)",
            unknown,
            len(feeds),
        )

    return {"discovered": discovered, "feeds_polled": len(feeds), "errors": errors, "unknown": unknown}


def run_report_via_runner(
    *,
    report_date: str | None = None,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> dict:
    """Submit a report assembly job and drain the runner synchronously."""
    from wilted.report import _local_date_str, assemble_report

    resolved_date = report_date or _local_date_str()
    submit_report(report_date=resolved_date, sync_run=False)
    drain_runner(kind=JobKind.REPORT_ASSEMBLY, max_jobs_per_run=max_jobs_per_run)
    return assemble_report(resolved_date)


def run_briefing_via_runner(
    *,
    window_start: str | None = None,
    window_end: str | None = None,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> dict[str, str | int]:
    """Submit a compact briefing job and drain the runner synchronously."""
    from wilted.report import _local_date_str

    today = _local_date_str()
    resolved_start = window_start or today
    resolved_end = window_end or today
    submit_briefing(window_start=resolved_start, window_end=resolved_end, sync_run=False)
    drain_runner(kind=JobKind.COMPACT_BRIEFING, max_jobs_per_run=max_jobs_per_run)

    identity = logical_identity_for_kind(
        JobKind.COMPACT_BRIEFING,
        window_start=resolved_start,
        window_end=resolved_end,
    )
    key = build_idempotency_key(JobKind.COMPACT_BRIEFING, operation_version=1, logical_identity=identity)
    job = ProcessingJob.get_or_none(ProcessingJob.idempotency_key == key.canonical)
    if job and job.result_json:
        try:
            payload = json.loads(job.result_json)
            return payload.get("metadata", {})
        except json.JSONDecodeError:
            pass
    return {"window_start": resolved_start, "window_end": resolved_end}
