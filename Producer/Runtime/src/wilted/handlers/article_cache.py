"""Pipeline handler for per-article audio cache generation jobs."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from wilted.cache import generate_article_cache, is_cache_valid
from wilted.db import Item, ensure_db
from wilted.engine import AudioEngine
from wilted.handlers._common import handler_options
from wilted.handlers.manifests import build_article_cache_manifest
from wilted.processing_jobs import record_job_completion
from wilted.queue import get_article_text

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel
    from wilted.station_runtime.coordinator import ModelCoordinator

logger = logging.getLogger(__name__)


def handle_article_cache(job: ProcessingJobModel, coordinator: ModelCoordinator) -> None:
    """Generate per-paragraph audio cache for one queue item.

    Synthesis uses the resident speech daemon via :class:`AudioEngine`; the
    coordinator is unused but accepted for the shared handler signature.

    Args:
        job: Running processing job with ``item_id`` set.
        coordinator: Runner-owned coordinator (unused for TTS cache synthesis).
    """
    del coordinator
    ensure_db()
    if job.item_id is None:
        raise ValueError(f"article_cache job {job.id} requires item_id")

    item = Item.get_or_none(Item.id == job.item_id)
    if item is None:
        raise ValueError(f"article_cache job {job.id} references missing item {job.item_id}")

    options = handler_options(job)
    operation_version = int(options.get("operation_version", 1))
    voice = str(options.get("voice", "af_heart"))
    lang = str(options.get("lang", "a"))
    speed = float(options.get("speed", 1.0))
    added = str(options.get("added", item.discovered_at or ""))

    entry = {"id": item.id, "added": added}
    text = get_article_text(entry)
    if not text:
        raise ValueError(f"article_cache job {job.id} has no article text for item {item.id}")

    if is_cache_valid(item.id, voice, lang, speed, added):
        logger.info("Article cache already valid for item %s — reconciling completion", item.id)
    else:
        engine = AudioEngine(voice=voice, lang=lang, speed=speed)
        success = generate_article_cache(
            engine,
            text,
            item.id,
            voice,
            lang,
            speed,
            added,
        )
        if not success:
            raise RuntimeError(f"article cache generation cancelled for item {item.id}")
        if not is_cache_valid(item.id, voice, lang, speed, added):
            raise RuntimeError(f"article cache incomplete after generation for item {item.id}")

    manifest = build_article_cache_manifest(
        item_id=item.id,
        voice=voice,
        lang=lang,
        speed=speed,
        added=added,
        text=text,
        operation_version=operation_version,
    )
    owner_id = job.lease_owner
    if not owner_id:
        raise ValueError(f"article_cache job {job.id} has no lease_owner")

    result_metadata = {
        "cached": 1,
        "errors": 0,
        "item_id": item.id,
    }
    if not record_job_completion(job.id, owner_id, manifest, result_metadata):
        raise RuntimeError(f"failed to record completion for article_cache job {job.id}")
