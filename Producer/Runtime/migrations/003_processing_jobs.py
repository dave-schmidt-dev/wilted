"""Migration 003 — processing_jobs durable work ledger.

Additive only: creates the ``processing_jobs`` table and scheduler indexes.
"""

from __future__ import annotations

from wilted.db import ProcessingJob


def _table_exists(db, table_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    )
    return cursor.fetchone() is not None


def _index_exists(db, index_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
        (index_name,),
    )
    return cursor.fetchone() is not None


def _ensure_indexes(db) -> None:
    if not _table_exists(db, "processing_jobs"):
        return
    for index_name, columns in (
        ("processingjob_state_priority_not_before", "state, priority, not_before"),
        ("processingjob_item_id", "item_id"),
    ):
        if not _index_exists(db, index_name):
            db.execute_sql(f"CREATE INDEX IF NOT EXISTS {index_name} ON processing_jobs ({columns})")


def up(db) -> None:
    """Create processing_jobs when missing."""
    db.create_tables([ProcessingJob], safe=True)
    _ensure_indexes(db)
