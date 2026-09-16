"""Pipeline handler for per-feed discovery jobs."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from wilted.db import Feed, ensure_db
from wilted.discover import _poll_feed
from wilted.feed_refs import display_feed_reference
from wilted.handlers._common import handler_options
from wilted.handlers.manifests import build_discover_manifest
from wilted.processing_jobs import record_job_completion

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel
    from wilted.station_runtime.coordinator import ModelCoordinator

logger = logging.getLogger(__name__)


def handle_discover(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Poll one feed and ingest new metadata-only candidates.

    Discovery is network-bound and does not load models. The coordinator is
    unused but accepted for the shared handler signature.

    Args:
        job: Running processing job with ``feed_id`` in checkpoint metadata.
        coordinator: Runner-owned coordinator (unused for discovery).
    """
    del coordinator
    ensure_db()
    options = handler_options(job)
    feed_id = options.get("feed_id")
    if feed_id is None:
        raise ValueError(f"discover job {job.id} requires feed_id in checkpoint metadata")

    operation_version = int(options.get("operation_version", 1))
    feed = Feed.get_or_none(Feed.id == int(feed_id))
    if feed is None:
        raise ValueError(f"discover job {job.id} references missing feed {feed_id}")

    try:
        stats = _poll_feed(feed)
    except Exception:
        logger.error("Failed to poll feed #%d (%s)", feed.id, display_feed_reference(feed.feed_url))
        stats = {"new": 0, "skipped": 0, "errors": 1}
    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"discover job {job.id} has no lease_owner")

    manifest = build_discover_manifest(
        feed_id=feed.id,
        operation_version=operation_version,
        stats=stats,
    )
    result_metadata = {
        "feed_id": feed.id,
        "discovered": stats.get("new", 0),
        "skipped": stats.get("skipped", 0),
        "errors": stats.get("errors", 0),
    }
    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for discover job {job.id}")
