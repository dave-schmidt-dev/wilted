"""Migration 001 — initial schema.

Creates all application tables.  Safe to call on an existing database
because create_tables uses ``safe=True`` (IF NOT EXISTS).
"""

from wilted.db import ALL_MODELS


def up(db) -> None:
    """Create all application tables."""
    db.create_tables(ALL_MODELS, safe=True)
