"""Test-only helpers for orthogonal content state (not used in production)."""

from __future__ import annotations

from typing import TYPE_CHECKING

from wilted.background_work.legacy_mapping import (
    ArtifactCohort,
    ItemType,
    LegacyCohort,
    LegacyStatus,
    map_legacy_cohort,
)
from wilted.content_state import apply_mapped_content_state
from wilted.db import Item

if TYPE_CHECKING:
    from pathlib import Path


def finalize_post_cutover_db(db_path: Path | str) -> None:
    """Reconnect and sync ``Item`` model fields after destructive cutover."""
    from wilted.db import connect_db

    connect_db(db_path)


def ensure_test_orthogonal_state(item: Item) -> Item:
    """Map legacy ``status`` to orthogonal columns using a COMPLETE artifact cohort.

    Production backfill inspects real artifacts and may quarantine rows; tests
    assume complete artifacts so cohort predicates can be exercised without
    seeding transcript/audio files on disk.
    """
    if item.fetch_state is not None:
        return item

    cohort = LegacyCohort(
        status=LegacyStatus(item.status),
        item_type=ItemType(item.item_type),
        artifacts=ArtifactCohort.COMPLETE,
        keep_override=bool(item.keep) and item.status == LegacyStatus.EXPIRED.value,
    )
    outcome = map_legacy_cohort(cohort)
    if outcome.quarantine or outcome.content is None:
        raise AssertionError(f"Test fixture cohort quarantined: {cohort} -> {outcome.quarantine_reason}")
    apply_mapped_content_state(item, outcome.content)
    return Item.get_by_id(item.id)
