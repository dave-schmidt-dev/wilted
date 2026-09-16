"""Pipeline handler for report assembly jobs."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from wilted.handlers._common import handler_options
from wilted.handlers.manifests import build_report_manifest
from wilted.processing_jobs import record_job_completion
from wilted.report import assemble_report

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel
    from wilted.station_runtime.coordinator import ModelCoordinator

logger = logging.getLogger(__name__)


def handle_report(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Assemble one dated morning report snapshot.

    Report assembly is instant and does not load models.

    Args:
        job: Running processing job with ``report_date`` in checkpoint metadata.
        coordinator: Runner-owned coordinator (unused for report assembly).
    """
    del coordinator
    options = handler_options(job)
    report_date = options.get("report_date")
    if not report_date:
        raise ValueError(f"report job {job.id} requires report_date in checkpoint metadata")

    operation_version = int(options.get("operation_version", 1))
    result = assemble_report(str(report_date))
    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"report job {job.id} has no lease_owner")

    manifest = build_report_manifest(
        report_id=result["report_id"],
        report_date=str(report_date),
        operation_version=operation_version,
        item_count=result["items"],
    )
    result_metadata = {
        "report_id": result["report_id"],
        "report_date": str(report_date),
        "items": result["items"],
        "playlists": result["playlists"],
    }
    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for report job {job.id}")
