"""Shared helpers for pipeline stage handlers."""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from wilted.db import ProcessingJob as ProcessingJobModel

logger = logging.getLogger(__name__)


def handler_options(job: ProcessingJobModel) -> dict[str, Any]:
    """Parse checkpoint metadata stored on a processing job."""
    if not job.checkpoint_json:
        return {}
    try:
        payload = json.loads(job.checkpoint_json)
    except json.JSONDecodeError:
        logger.warning("Ignoring invalid checkpoint_json on job %s", job.id)
        return {}
    return payload if isinstance(payload, dict) else {}
