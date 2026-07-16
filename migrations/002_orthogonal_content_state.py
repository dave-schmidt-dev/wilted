"""Migration 002 — orthogonal content-state columns and report_items table.

Additive only: extends ``items`` with nullable orthogonal state columns and
creates ``report_items``. Legacy ``status`` and ``selection_history`` are
unchanged.
"""

from __future__ import annotations

from wilted.db import ReportItem

_ITEM_STATE_COLUMNS: tuple[tuple[str, str], ...] = (
    (
        "fetch_state",
        "VARCHAR NULL CHECK(fetch_state IS NULL OR fetch_state IN ('metadata', 'content_ready', 'error'))",
    ),
    (
        "analysis_state",
        "VARCHAR NULL CHECK(analysis_state IS NULL OR analysis_state IN ('pending', 'ready', 'error'))",
    ),
    (
        "preparation_state",
        "VARCHAR NULL CHECK(preparation_state IS NULL OR preparation_state IN "
        "('not_queued', 'queued', 'ready', 'error'))",
    ),
    (
        "playback_state",
        "VARCHAR NULL CHECK(playback_state IS NULL OR playback_state IN "
        "('unplayed', 'playing', 'paused', 'completed'))",
    ),
    (
        "retention_state",
        "VARCHAR NULL CHECK(retention_state IS NULL OR retention_state IN ('active', 'expired'))",
    ),
    ("retention_expires_at", "VARCHAR NULL"),
)


def _table_exists(db, table_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    )
    return cursor.fetchone() is not None


def _column_exists(db, table_name: str, column_name: str) -> bool:
    cursor = db.execute_sql(f"PRAGMA table_info({table_name})")
    return any(row[1] == column_name for row in cursor.fetchall())


def _add_item_columns(db) -> None:
    if not _table_exists(db, "items"):
        return
    for column_name, ddl in _ITEM_STATE_COLUMNS:
        if not _column_exists(db, "items", column_name):
            db.execute_sql(f"ALTER TABLE items ADD COLUMN {column_name} {ddl}")


def _index_exists(db, index_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
        (index_name,),
    )
    return cursor.fetchone() is not None


def _add_item_indexes(db) -> None:
    if not _table_exists(db, "items"):
        return
    for index_name, columns in (
        ("idx_items_preparation_discovered", "preparation_state, discovered_at"),
        ("idx_items_analysis_relevance", "analysis_state, relevance_score"),
    ):
        if not _index_exists(db, index_name):
            db.execute_sql(f"CREATE INDEX IF NOT EXISTS {index_name} ON items ({columns})")


def up(db) -> None:
    """Add orthogonal Item columns and create report_items when missing."""
    _add_item_columns(db)
    _add_item_indexes(db)
    db.create_tables([ReportItem], safe=True)
