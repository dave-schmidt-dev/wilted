"""Explicit maintenance-only legacy content-state cutover.

Maps monolithic ``Item.status`` rows to orthogonal content facts, backfills
``report_items`` from ``selection_history``, replaces indexes, and drops
legacy columns. This module is the only place destructive cutover logic runs;
ordinary startup migrations stop at version 003.
"""

from __future__ import annotations

import json
import logging
import shutil
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

from wilted.background_work.contracts import ReportDecision
from wilted.background_work.legacy_mapping import (
    ArtifactCohort,
    ItemType,
    LegacyCohort,
    LegacyStatus,
    MappingOutcome,
    map_legacy_cohort,
)
from wilted.content_state import apply_mapped_content_state
from wilted.db import Item, ReportItem, SelectionHistory, _Meta, connect_db, now_utc

if TYPE_CHECKING:
    from peewee import SqliteDatabase

logger = logging.getLogger(__name__)

META_CUTOVER_COMPLETE = "legacy_cutover_complete"
META_CUTOVER_AT = "legacy_cutover_at"
META_CUTOVER_IN_PROGRESS = "legacy_cutover_in_progress"
META_CUTOVER_BACKUP = "legacy_cutover_backup_path"
META_QUARANTINE_JSON = "legacy_cutover_quarantine"

_MAX_AUTO_MIGRATION_VERSION = 4

_ITEM_COLUMNS_WITHOUT_STATUS: tuple[str, ...] = (
    "id",
    "feed_id",
    "guid",
    "title",
    "author",
    "source_name",
    "source_url",
    "canonical_url",
    "published_at",
    "discovered_at",
    "item_type",
    "fetch_state",
    "analysis_state",
    "preparation_state",
    "playback_state",
    "retention_state",
    "retention_expires_at",
    "error_message",
    "word_count",
    "duration_seconds",
    "transcript_file",
    "audio_file",
    "enclosure_url",
    "enclosure_type",
    "playlist_assigned",
    "playlist_override",
    "relevance_score",
    "summary",
    "tags",
    "keep",
    "metadata",
)

_NEW_ITEM_INDEXES: tuple[tuple[str, str], ...] = (
    ("idx_items_fetch_discovered", "fetch_state, discovered_at"),
    ("idx_items_analysis_discovered", "analysis_state, discovered_at"),
    ("idx_items_preparation_discovered", "preparation_state, discovered_at"),
    ("idx_items_playback_discovered", "playback_state, discovered_at"),
    ("idx_items_retention_discovered", "retention_state, discovered_at"),
)

_LEGACY_STATUS_INDEX_NAMES: tuple[str, ...] = (
    "item_status_discovered_at",
    "idx_items_status",
)


@dataclass(frozen=True, slots=True)
class PlannedItem:
    """One item row in the cutover plan."""

    item_id: int
    legacy_status: str
    item_type: str
    artifact_cohort: ArtifactCohort
    keep_override: bool
    outcome: MappingOutcome


@dataclass(frozen=True, slots=True)
class SelectionBackfillRow:
    """One SelectionHistory row mapped to report_items."""

    selection_id: int
    report_id: int
    item_id: int
    rank: int
    decision: ReportDecision
    created_at: str


@dataclass(frozen=True, slots=True)
class CohortReconciliation:
    """Old vs new membership for one legacy cohort key."""

    legacy_status: str
    item_type: str
    artifact_cohort: str
    legacy_ids: tuple[int, ...]
    new_ids: tuple[int, ...]
    quarantined_ids: tuple[int, ...] = ()

    @property
    def matches(self) -> bool:
        expected = set(self.legacy_ids) - set(self.quarantined_ids)
        return set(self.new_ids) == expected


@dataclass
class CutoverPlan:
    """Dry-run plan for the legacy cutover."""

    items: list[PlannedItem] = field(default_factory=list)
    quarantined: list[PlannedItem] = field(default_factory=list)
    cohort_counts: dict[str, int] = field(default_factory=dict)
    selection_backfill: list[SelectionBackfillRow] = field(default_factory=list)


@dataclass
class CutoverReport:
    """Result of applying (or dry-running) the legacy cutover."""

    dry_run: bool
    items_mapped: int = 0
    items_quarantined: int = 0
    report_items_created: int = 0
    cohort_reconciliation: list[CohortReconciliation] = field(default_factory=list)
    quarantine_rows: list[dict[str, Any]] = field(default_factory=list)
    backup_path: Path | None = None
    completed_at: str | None = None
    message: str = ""


class CutoverError(Exception):
    """Raised when cutover preconditions fail or reconciliation does not pass."""


def max_auto_migration_version() -> int:
    """Return the highest migration version applied during ordinary startup."""
    return _MAX_AUTO_MIGRATION_VERSION


def _artifact_path_exists(path_value: str | None, data_dir: Path) -> bool:
    if not path_value:
        return False
    path = Path(path_value)
    if not path.is_absolute():
        path = data_dir / path
    return path.is_file()


def classify_artifact_cohort(item: Item, data_dir: Path) -> ArtifactCohort:
    """Inspect transcript/audio artifacts on disk for one item.

    Args:
        item: Item row with optional ``transcript_file`` / ``audio_file``.
        data_dir: Project data directory for resolving relative paths.

    Returns:
        Artifact-presence cohort used by the legacy mapping table.
    """
    has_transcript = _artifact_path_exists(item.transcript_file, data_dir)
    has_audio = _artifact_path_exists(item.audio_file, data_dir)
    if has_transcript and has_audio:
        return ArtifactCohort.COMPLETE
    if has_transcript or has_audio:
        return ArtifactCohort.PARTIAL
    return ArtifactCohort.NONE


def map_item_row(item: Item, data_dir: Path) -> MappingOutcome:
    """Map one legacy item row through the authoritative cohort table.

    Args:
        item: Legacy item row still carrying ``status``.
        data_dir: Project data directory for artifact inspection.

    Returns:
        :class:`MappingOutcome` with orthogonal states or quarantine.
    """
    cohort = LegacyCohort(
        status=LegacyStatus(item.status),
        item_type=ItemType(item.item_type),
        artifacts=classify_artifact_cohort(item, data_dir),
        keep_override=bool(item.keep) and item.status == LegacyStatus.EXPIRED.value,
    )
    return map_legacy_cohort(cohort)


def _cohort_key(status: str, item_type: str, artifacts: ArtifactCohort) -> str:
    return f"{status}:{item_type}:{artifacts.value}"


def _plan_selection_backfill() -> list[SelectionBackfillRow]:
    rows: list[SelectionBackfillRow] = []
    by_report: dict[int, list[SelectionHistory]] = {}
    for selection in SelectionHistory.select().order_by(SelectionHistory.selected_at, SelectionHistory.id):
        if selection.report_id is None:
            logger.warning(
                "Skipping selection_history id=%s without report_id during backfill",
                selection.id,
            )
            continue
        by_report.setdefault(selection.report_id, []).append(selection)

    for report_id, selections in sorted(by_report.items()):
        for rank, selection in enumerate(selections):
            decision = ReportDecision.ACCEPTED if selection.selected else ReportDecision.DISMISSED
            rows.append(
                SelectionBackfillRow(
                    selection_id=selection.id,
                    report_id=report_id,
                    item_id=selection.item_id,
                    rank=rank,
                    decision=decision,
                    created_at=selection.selected_at or now_utc(),
                )
            )
    return rows


def build_cutover_plan(db: SqliteDatabase, *, data_dir: Path) -> CutoverPlan:
    """Build a full cutover plan for every item and selection row.

    Args:
        db: Connected SQLite database (unused; kept for symmetry with callers).
        data_dir: Project data directory for artifact inspection.

    Returns:
        :class:`CutoverPlan` with mapped/quarantined items and backfill rows.
    """
    _ = db
    plan = CutoverPlan()
    for item in Item.select().order_by(Item.id):
        outcome = map_item_row(item, data_dir)
        artifacts = classify_artifact_cohort(item, data_dir)
        planned = PlannedItem(
            item_id=item.id,
            legacy_status=item.status,
            item_type=item.item_type,
            artifact_cohort=artifacts,
            keep_override=bool(item.keep),
            outcome=outcome,
        )
        key = _cohort_key(item.status, item.item_type, artifacts)
        plan.cohort_counts[key] = plan.cohort_counts.get(key, 0) + 1
        if outcome.quarantine:
            plan.quarantined.append(planned)
        else:
            plan.items.append(planned)
    plan.selection_backfill = _plan_selection_backfill()
    return plan


def verify_backup(backup_path: Path) -> bool:
    """Return True when *backup_path* is a readable SQLite database file."""
    if not backup_path.is_file():
        return False
    try:
        conn = sqlite3.connect(f"file:{backup_path}?mode=ro", uri=True)
        try:
            conn.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        finally:
            conn.close()
    except sqlite3.Error:
        return False
    return True


def create_backup(db_path: Path, backup_dir: Path) -> Path:
    """Copy *db_path* into *backup_dir* with a UTC timestamp suffix.

    Args:
        db_path: Live wilted.db path.
        backup_dir: Directory that will receive the backup copy.

    Returns:
        Path to the created backup file.
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = now_utc().replace(":", "").replace("-", "")
    destination = backup_dir / f"wilted-{stamp}.db"
    shutil.copy2(db_path, destination)
    logger.info("Created cutover backup at %s", destination)
    return destination


def _meta_get(key: str) -> str | None:
    try:
        return _Meta.get_by_id(key).value
    except _Meta.DoesNotExist:
        return None


def _meta_set(key: str, value: str) -> None:
    _Meta.replace(key=key, value=value).execute()


def _meta_delete(key: str) -> None:
    _Meta.delete().where(_Meta.key == key).execute()


def items_table_has_status_column(db: SqliteDatabase) -> bool:
    """Return True when the legacy ``status`` column still exists on ``items``."""
    cursor = db.execute_sql("PRAGMA table_info(items)")
    return any(row[1] == "status" for row in cursor.fetchall())


def cutover_required(db: SqliteDatabase) -> bool:
    """Return True when the destructive legacy cutover has not completed."""
    if _meta_get(META_CUTOVER_COMPLETE) == "1":
        return False
    return items_table_has_status_column(db)


def cutover_in_progress(db: SqliteDatabase) -> bool:
    """Return True when a previous cutover attempt was interrupted."""
    _ = db
    return _meta_get(META_CUTOVER_IN_PROGRESS) == "1"


def cutover_complete() -> bool:
    """Return True when cutover finished successfully."""
    return _meta_get(META_CUTOVER_COMPLETE) == "1"


def restore_instructions() -> str:
    """Return runbook text for restoring a pre-cutover database backup."""
    return (
        "Legacy cutover restore runbook\n"
        "------------------------------\n"
        "1. Stop all Wilted writers: quit the TUI, stop launchd jobs, and ensure no\n"
        "   `wilted` CLI process is running.\n"
        "2. Locate the verified backup recorded in `_meta.legacy_cutover_backup_path`\n"
        "   or the timestamped copy under your `--backup-dir`.\n"
        "3. Replace `data/wilted.db` with the backup copy:\n"
        "     cp <backup-path> data/wilted.db\n"
        "4. Clear any interrupted cutover marker if present:\n"
        "     sqlite3 data/wilted.db \"DELETE FROM _meta WHERE key='legacy_cutover_in_progress'\"\n"
        "5. Restart Wilted only after verifying `PRAGMA table_info(items)` still lists\n"
        "   the `status` column and `legacy_cutover_complete` is absent.\n"
    )


def _content_state_matches(item: Item, outcome: MappingOutcome) -> bool:
    if outcome.content is None:
        return False
    expected = outcome.content
    return (
        item.fetch_state == expected.fetch.value
        and item.analysis_state == expected.analysis.value
        and item.preparation_state == expected.preparation.value
        and item.playback_state == expected.playback.value
        and item.retention_state == expected.retention.state.value
        and bool(item.keep) == expected.retention.keep_override
    )


def _legacy_cohort_member_ids(
    snapshot: dict[int, tuple[str, str, ArtifactCohort]],
    *,
    legacy_status: str,
    item_type: str,
    artifact_cohort: ArtifactCohort,
) -> tuple[int, ...]:
    return tuple(
        sorted(
            item_id
            for item_id, (status, itype, artifacts) in snapshot.items()
            if status == legacy_status and itype == item_type and artifacts is artifact_cohort
        )
    )


def _new_cohort_member_ids(
    snapshot: dict[int, tuple[str, str, ArtifactCohort]],
    *,
    legacy_status: str,
    item_type: str,
    artifact_cohort: ArtifactCohort,
) -> tuple[int, ...]:
    members: list[int] = []
    for item_id, (status, itype, artifacts) in snapshot.items():
        if status != legacy_status or itype != item_type or artifacts is not artifact_cohort:
            continue
        item_row = Item.get_by_id(item_id)
        cohort = LegacyCohort(
            status=LegacyStatus(status),
            item_type=ItemType(itype),
            artifacts=artifacts,
            keep_override=bool(item_row.keep) and status == LegacyStatus.EXPIRED.value,
        )
        outcome = map_legacy_cohort(cohort)
        if outcome.quarantine:
            continue
        if _content_state_matches(Item.get_by_id(item_id), outcome):
            members.append(item_id)
    return tuple(sorted(members))


def _planned_cohort_reconciliation(
    snapshot: dict[int, tuple[str, str, ArtifactCohort]],
    plan: CutoverPlan,
) -> list[CohortReconciliation]:
    """Build reconciliation rows from a dry-run plan without mutating items."""
    planned_ids = {row.item_id for row in plan.items}
    results: list[CohortReconciliation] = []
    seen: set[tuple[str, str, str]] = set()
    for status, item_type, artifacts in {entry for entry in snapshot.values()}:
        key = (status, item_type, artifacts.value)
        if key in seen:
            continue
        seen.add(key)
        legacy_ids = _legacy_cohort_member_ids(
            snapshot,
            legacy_status=status,
            item_type=item_type,
            artifact_cohort=artifacts,
        )
        new_ids = tuple(sorted(item_id for item_id in legacy_ids if item_id in planned_ids))
        quarantined_ids = tuple(item_id for item_id in legacy_ids if item_id not in planned_ids)
        results.append(
            CohortReconciliation(
                legacy_status=status,
                item_type=item_type,
                artifact_cohort=artifacts.value,
                legacy_ids=legacy_ids,
                new_ids=new_ids,
                quarantined_ids=quarantined_ids,
            )
        )
    return sorted(results, key=lambda row: (row.legacy_status, row.item_type, row.artifact_cohort))


def reconcile_cohorts(
    snapshot: dict[int, tuple[str, str, ArtifactCohort]],
    *,
    quarantined_ids: set[int] | None = None,
) -> list[CohortReconciliation]:
    """Compare legacy vs orthogonal membership for every observed cohort."""
    quarantined = quarantined_ids or set()
    seen: set[tuple[str, str, str]] = set()
    results: list[CohortReconciliation] = []
    for status, item_type, artifacts in {(entry[0], entry[1], entry[2]) for entry in snapshot.values()}:
        key = (status, item_type, artifacts.value)
        if key in seen:
            continue
        seen.add(key)
        legacy_ids = _legacy_cohort_member_ids(
            snapshot,
            legacy_status=status,
            item_type=item_type,
            artifact_cohort=artifacts,
        )
        cohort_quarantined = tuple(item_id for item_id in legacy_ids if item_id in quarantined)
        results.append(
            CohortReconciliation(
                legacy_status=status,
                item_type=item_type,
                artifact_cohort=artifacts.value,
                legacy_ids=legacy_ids,
                new_ids=_new_cohort_member_ids(
                    snapshot,
                    legacy_status=status,
                    item_type=item_type,
                    artifact_cohort=artifacts,
                ),
                quarantined_ids=cohort_quarantined,
            )
        )
    return sorted(results, key=lambda row: (row.legacy_status, row.item_type, row.artifact_cohort))


def _ensure_quarantine_table(db: SqliteDatabase) -> None:
    db.execute_sql(
        """
        CREATE TABLE IF NOT EXISTS migration_quarantine (
            item_id INTEGER PRIMARY KEY,
            legacy_status TEXT NOT NULL,
            item_type TEXT NOT NULL,
            artifact_cohort TEXT NOT NULL,
            reason TEXT NOT NULL,
            quarantined_at TEXT NOT NULL
        )
        """
    )


def _record_quarantine(db: SqliteDatabase, planned: PlannedItem) -> None:
    _ensure_quarantine_table(db)
    db.execute_sql(
        """
        INSERT OR REPLACE INTO migration_quarantine
            (item_id, legacy_status, item_type, artifact_cohort, reason, quarantined_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            planned.item_id,
            planned.legacy_status,
            planned.item_type,
            planned.artifact_cohort.value,
            planned.outcome.quarantine_reason,
            now_utc(),
        ),
    )


def _drop_legacy_status_index(db: SqliteDatabase) -> None:
    for index_name in _LEGACY_STATUS_INDEX_NAMES:
        db.execute_sql(f"DROP INDEX IF EXISTS {index_name}")


def _create_orthogonal_indexes(db: SqliteDatabase) -> None:
    for index_name, columns in _NEW_ITEM_INDEXES:
        db.execute_sql(f"CREATE INDEX IF NOT EXISTS {index_name} ON items ({columns})")


def _rebuild_items_without_status(db: SqliteDatabase) -> None:
    checks = (
        "fetch_state VARCHAR NULL CHECK(fetch_state IS NULL OR fetch_state IN ('metadata', 'content_ready', 'error'))",
        "analysis_state VARCHAR NULL CHECK(analysis_state IS NULL OR analysis_state IN ('pending', 'ready', 'error'))",
        "preparation_state VARCHAR NULL CHECK(preparation_state IS NULL OR preparation_state IN "
        "('not_queued', 'queued', 'ready', 'error'))",
        "playback_state VARCHAR NULL CHECK(playback_state IS NULL OR playback_state IN "
        "('unplayed', 'playing', 'paused', 'completed'))",
        "retention_state VARCHAR NULL CHECK(retention_state IS NULL OR retention_state IN ('active', 'expired'))",
    )
    column_defs = ", ".join(
        [
            "id INTEGER PRIMARY KEY",
            "feed_id INTEGER NULL",
            "guid VARCHAR NULL",
            "title VARCHAR NOT NULL",
            "author VARCHAR NULL",
            "source_name VARCHAR NULL",
            "source_url VARCHAR NULL",
            "canonical_url VARCHAR NULL",
            "published_at VARCHAR NULL",
            "discovered_at VARCHAR NOT NULL",
            "item_type VARCHAR NOT NULL CHECK(item_type IN ('article', 'podcast_episode'))",
            *checks,
            "retention_expires_at VARCHAR NULL",
            "error_message TEXT NULL",
            "word_count INTEGER NULL",
            "duration_seconds REAL NULL",
            "transcript_file VARCHAR NULL",
            "audio_file VARCHAR NULL",
            "enclosure_url VARCHAR NULL",
            "enclosure_type VARCHAR NULL",
            "playlist_assigned VARCHAR NULL",
            "playlist_override VARCHAR NULL",
            "relevance_score REAL NULL",
            "summary TEXT NULL",
            "tags TEXT NULL",
            "keep BOOLEAN NOT NULL DEFAULT 0",
            "metadata TEXT NULL CHECK(metadata IS NULL OR json_valid(metadata))",
            "UNIQUE(feed_id, guid)",
        ]
    )
    select_columns = ", ".join(_ITEM_COLUMNS_WITHOUT_STATUS)
    db.execute_sql("PRAGMA foreign_keys=OFF")
    try:
        db.execute_sql(f"CREATE TABLE items_new ({column_defs})")
        db.execute_sql(f"INSERT INTO items_new ({select_columns}) SELECT {select_columns} FROM items")
        db.execute_sql("DROP TABLE items")
        db.execute_sql("ALTER TABLE items_new RENAME TO items")
        db.execute_sql("CREATE INDEX IF NOT EXISTS item_feed_id ON items (feed_id)")
        for index_name, columns in _NEW_ITEM_INDEXES:
            db.execute_sql(f"CREATE INDEX IF NOT EXISTS {index_name} ON items ({columns})")
    finally:
        db.execute_sql("PRAGMA foreign_keys=ON")


def _drop_selection_history(db: SqliteDatabase) -> None:
    db.execute_sql("DROP TABLE IF EXISTS selection_history")


def _snapshot_legacy_cohorts() -> dict[int, tuple[str, str, ArtifactCohort]]:
    from wilted import DATA_DIR

    snapshot: dict[int, tuple[str, str, ArtifactCohort]] = {}
    for item in Item.select():
        snapshot[item.id] = (
            item.status,
            item.item_type,
            classify_artifact_cohort(item, DATA_DIR),
        )
    return snapshot


def apply_legacy_cutover(
    db_path: Path | str,
    *,
    dry_run: bool = False,
    backup_dir: Path | None = None,
) -> CutoverReport:
    """Apply the destructive legacy content-state cutover.

    Args:
        db_path: Path to wilted.db.
        dry_run: When True, compute the plan/report without mutating schema/data.
        backup_dir: Directory for verified backups. Required for live cutover.

    Returns:
        :class:`CutoverReport` with mapping, quarantine, and reconciliation stats.

    Raises:
        CutoverError: When preconditions fail or reconciliation does not pass.
    """
    db_path = Path(db_path)
    from wilted.db import _db, reset_db

    if _db.database is not None and str(_db.database) != str(db_path):
        reset_db()
    connect_db(db_path)
    db = Item._meta.database

    if cutover_complete() and not items_table_has_status_column(db):
        return CutoverReport(
            dry_run=dry_run,
            message="Legacy cutover already complete; no work performed.",
        )

    if cutover_in_progress(db):
        raise CutoverError(
            "Legacy cutover is marked in progress from an interrupted attempt. Restore from backup before retrying."
        )

    from wilted import DATA_DIR

    plan = build_cutover_plan(db, data_dir=DATA_DIR)
    snapshot = _snapshot_legacy_cohorts()
    report = CutoverReport(
        dry_run=dry_run,
        items_quarantined=len(plan.quarantined),
        quarantine_rows=[
            {
                "item_id": row.item_id,
                "legacy_status": row.legacy_status,
                "item_type": row.item_type,
                "artifact_cohort": row.artifact_cohort.value,
                "reason": row.outcome.quarantine_reason,
            }
            for row in plan.quarantined
        ],
    )

    if dry_run:
        for planned in plan.items:
            report.items_mapped += 1
        report.cohort_reconciliation = _planned_cohort_reconciliation(snapshot, plan)
        report.message = "Dry run complete; no database changes applied."
        return report

    if backup_dir is None:
        raise CutoverError("backup_dir is required for live cutover")

    backup_path = create_backup(db_path, backup_dir)
    if not verify_backup(backup_path):
        raise CutoverError(f"Backup verification failed for {backup_path}")

    _meta_set(META_CUTOVER_IN_PROGRESS, "1")
    _meta_set(META_CUTOVER_BACKUP, str(backup_path))

    completed_at: str | None = None
    try:
        with db.atomic():
            for planned in plan.items:
                item = Item.get_by_id(planned.item_id)
                apply_mapped_content_state(item, planned.outcome.content)  # type: ignore[arg-type]
                report.items_mapped += 1

            for planned in plan.quarantined:
                _record_quarantine(db, planned)

            report.cohort_reconciliation = reconcile_cohorts(
                snapshot,
                quarantined_ids={row.item_id for row in plan.quarantined},
            )
            mismatches = [row for row in report.cohort_reconciliation if not row.matches]
            if mismatches:
                details = ", ".join(
                    f"{row.legacy_status}/{row.item_type}/{row.artifact_cohort}" for row in mismatches[:5]
                )
                raise CutoverError(f"Cohort reconciliation failed for: {details}")

            _drop_legacy_status_index(db)
            _create_orthogonal_indexes(db)
            _rebuild_items_without_status(db)
            _drop_selection_history(db)

            for row in plan.selection_backfill:
                _, created = ReportItem.get_or_create(
                    report=row.report_id,
                    item=row.item_id,
                    defaults={
                        "rank": row.rank,
                        "decision": row.decision.value,
                        "defer_until": None,
                        "created_at": row.created_at,
                    },
                )
                if created:
                    report.report_items_created += 1

            completed_at = now_utc()
            _meta_set(META_CUTOVER_COMPLETE, "1")
            _meta_set(META_CUTOVER_AT, completed_at)
            _meta_set(META_QUARANTINE_JSON, json.dumps(report.quarantine_rows))
            _meta_delete(META_CUTOVER_IN_PROGRESS)

        report.backup_path = backup_path
        report.completed_at = completed_at
        report.message = "Legacy cutover completed successfully."
        logger.info(
            "Legacy cutover complete: mapped=%d quarantined=%d report_items=%d",
            report.items_mapped,
            report.items_quarantined,
            report.report_items_created,
        )
        return report
    except Exception:
        logger.exception("Legacy cutover failed")
        raise


__all__ = [
    "CutoverError",
    "CutoverPlan",
    "CutoverReport",
    "CohortReconciliation",
    "PlannedItem",
    "SelectionBackfillRow",
    "apply_legacy_cutover",
    "build_cutover_plan",
    "classify_artifact_cohort",
    "create_backup",
    "cutover_complete",
    "cutover_in_progress",
    "cutover_required",
    "items_table_has_status_column",
    "map_item_row",
    "max_auto_migration_version",
    "reconcile_cohorts",
    "restore_instructions",
    "verify_backup",
]
