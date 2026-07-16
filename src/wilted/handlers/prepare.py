"""Pipeline handler for preparation jobs."""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any

from wilted.db import Item, ensure_db
from wilted.handlers.manifests import build_prepare_manifest
from wilted.prepare import prepare_item
from wilted.processing_jobs import record_job_completion

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel
    from wilted.station_runtime.coordinator import ModelCoordinator

logger = logging.getLogger(__name__)


def _handler_options(job: ProcessingJobModel) -> dict[str, Any]:
    if not job.checkpoint_json:
        return {}
    try:
        payload = json.loads(job.checkpoint_json)
    except json.JSONDecodeError:
        logger.warning("Ignoring invalid checkpoint_json on prepare job %s", job.id)
        return {}
    return payload if isinstance(payload, dict) else {}


def handle_prepare(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Prepare one item claimed by the processing runner.

    Args:
        job: Running processing job with ``item_id`` set.
        coordinator: Runner-owned model coordinator for ML leasing.
    """
    ensure_db()
    if job.item_id is None:
        raise ValueError(f"prepare job {job.id} requires item_id")

    item = Item.get_or_none(Item.id == job.item_id)
    if item is None:
        raise ValueError(f"prepare job {job.id} references missing item {job.item_id}")

    options = _handler_options(job)
    operation_version = int(options.get("operation_version", 1))
    use_llm = bool(options.get("use_llm", True))
    skip_tts = bool(options.get("skip_tts", False))
    llm_model = options.get("llm_model")
    llm_backend_type = options.get("llm_backend_type") or "gguf"

    prepared = prepare_item(
        item,
        coordinator,
        use_llm=use_llm,
        llm_model=llm_model,
        llm_backend_type=llm_backend_type,
        skip_tts=skip_tts,
    )

    item = Item.get_by_id(item.id)
    manifest = build_prepare_manifest(item, operation_version=operation_version)
    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"prepare job {job.id} has no lease_owner")

    result_metadata = {
        "prepared": 1 if prepared else 0,
        "errors": 0 if prepared else 1,
    }
    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for prepare job {job.id}")
