"""Pipeline handler for classification jobs."""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any

from wilted.background_work.contracts import AnalysisState
from wilted.classify import _DEFAULT_BACKEND, _DEFAULT_MODEL, classify_item
from wilted.content_state import read_content_state
from wilted.db import Item, ensure_db
from wilted.handlers.manifests import build_classify_manifest
from wilted.llm import create_backend
from wilted.preferences import get_keywords_for_prompt
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
        logger.warning("Ignoring invalid checkpoint_json on classify job %s", job.id)
        return {}
    return payload if isinstance(payload, dict) else {}


def handle_classify(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Classify one item claimed by the processing runner.

    Args:
        job: Running processing job with ``item_id`` set.
        coordinator: Runner-owned model coordinator for LLM leasing.
    """
    ensure_db()
    if job.item_id is None:
        raise ValueError(f"classify job {job.id} requires item_id")

    item = Item.get_or_none(Item.id == job.item_id)
    if item is None:
        raise ValueError(f"classify job {job.id} references missing item {job.item_id}")

    options = _handler_options(job)
    model = options.get("model") or _DEFAULT_MODEL
    backend_type = options.get("backend_type") or _DEFAULT_BACKEND
    operation_version = int(options.get("operation_version", 1))
    keywords_section = get_keywords_for_prompt()

    backend = create_backend(backend_type, model=model)
    classified = False

    def _classify_loaded(loaded_backend) -> None:
        nonlocal classified
        classified = classify_item(loaded_backend, item, keywords_section)

    coordinator.run_llm(backend, _classify_loaded)

    item = Item.get_by_id(item.id)
    manifest = build_classify_manifest(item, operation_version=operation_version)
    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"classify job {job.id} has no lease_owner")

    state = read_content_state(item)
    result_metadata = {
        "classified": 1 if classified else 0,
        "errors": 0 if classified else 1,
        "analysis_state": state.analysis.value if state else None,
    }
    if state and state.analysis is AnalysisState.ERROR:
        result_metadata["errors"] = 1
        result_metadata["classified"] = 0

    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for classify job {job.id}")
