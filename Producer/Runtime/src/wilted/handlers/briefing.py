"""Pipeline handler for compact briefing generation jobs."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from wilted.briefing_artifacts import persist_briefing_artifact
from wilted.handlers._common import handler_options
from wilted.handlers.manifests import build_briefing_manifest
from wilted.processing_jobs import record_job_completion
from wilted.station_runtime.briefing import BriefingGenerator

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel
    from wilted.station_runtime.coordinator import ModelCoordinator

logger = logging.getLogger(__name__)


def handle_briefing(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Generate and persist one compact briefing artifact.

    Synthesis uses the resident speech daemon via :class:`BriefingGenerator`;
    the coordinator is unused but accepted for the shared handler signature.

    Args:
        job: Running processing job with briefing window metadata.
        coordinator: Runner-owned coordinator (unused for briefing synthesis).
    """
    del coordinator
    options = handler_options(job)
    window_start = options.get("window_start")
    window_end = options.get("window_end")
    if not window_start or not window_end:
        raise ValueError(f"briefing job {job.id} requires window_start and window_end")

    operation_version = int(options.get("operation_version", 1))
    generator = BriefingGenerator.from_config()
    briefing = generator.generate(now=datetime.now(UTC))
    artifact_id = persist_briefing_artifact(
        briefing,
        window_start=str(window_start),
        window_end=str(window_end),
    )

    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"briefing job {job.id} has no lease_owner")

    manifest = build_briefing_manifest(
        artifact_id=artifact_id,
        operation_version=operation_version,
        word_count=briefing.word_count,
    )
    result_metadata = {
        "artifact_id": artifact_id,
        "window_start": str(window_start),
        "window_end": str(window_end),
        "word_count": briefing.word_count,
    }
    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for briefing job {job.id}")
