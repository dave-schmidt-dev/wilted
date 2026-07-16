"""Submit pipeline stages to the durable processing-job ledger."""

from __future__ import annotations

import logging
from typing import Any

from wilted.background_work.contracts import AnalysisState, JobKind, PreparationState, ProcessingJobState
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.content_state import items_for_prepare, items_pending_classification, read_content_state
from wilted.db import Item, ProcessingJob, ensure_db
from wilted.pipeline_runner import PipelineRunner, RunStats
from wilted.processing_jobs import SubmitResult, submit_job
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


def _has_runnable_jobs(*, kind: JobKind | None = None) -> bool:
    ensure_db()
    query = ProcessingJob.select().where(
        ProcessingJob.state.in_(
            (
                ProcessingJobState.QUEUED.value,
                ProcessingJobState.RETRY.value,
            ),
        ),
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


def drain_runner(
    *,
    kind: JobKind | None = None,
    max_jobs_per_run: int = _DEFAULT_MAX_JOBS_PER_RUN,
) -> RunStats:
    """Run the pipeline runner until no runnable jobs remain for ``kind``."""
    runner = PipelineRunner(
        bootstrap=_ready_bootstrap(),
        max_jobs_per_run=max_jobs_per_run,
    )
    accum = RunStats()
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
