"""Migration 004 — processing_jobs.cancel_requested cooperative-stop flag.

Additive only: adds ``cancel_requested`` for running-job cancellation CAS.
"""

from __future__ import annotations


def _table_exists(db, table_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    )
    return cursor.fetchone() is not None


def _column_exists(db, table_name: str, column_name: str) -> bool:
    cursor = db.execute_sql(f"PRAGMA table_info({table_name})")
    return any(row[1] == column_name for row in cursor.fetchall())


def up(db) -> None:
    """Add cancel_requested when missing."""
    if not _table_exists(db, "processing_jobs"):
        return
    if not _column_exists(db, "processing_jobs", "cancel_requested"):
        db.execute_sql(
            "ALTER TABLE processing_jobs ADD COLUMN cancel_requested INTEGER NOT NULL DEFAULT 0",
        )
