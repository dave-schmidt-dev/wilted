"""queue.json → SQLite data migration.

Run once to import existing articles from the legacy queue.json format into
the new SQLite items table.  Safe to re-run: duplicate items are skipped.

CLI:
    wilted migrate
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

logger = logging.getLogger(__name__)


def _to_utc(local_iso: str) -> str:
    """Convert a naïve local ISO timestamp to a UTC 'Z' timestamp.

    Legacy queue.json used ``datetime.now().isoformat()`` without timezone.
    We treat those as local time and convert to UTC on best-effort basis.
    If the string already ends in 'Z' or contains '+', return unchanged.
    """
    if not local_iso:
        return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    if local_iso.endswith("Z") or "+" in local_iso:
        return local_iso
    try:
        # Parse as naïve local time, then convert to UTC
        dt = datetime.fromisoformat(local_iso).astimezone(UTC)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve_transcript_path(articles_dir: Path, filename: str) -> str | None:
    """Return the absolute path to a transcript file if it exists."""
    if not filename:
        return None
    full = articles_dir / filename
    return str(full) if full.exists() else None


def run_migration(queue_file: Path, articles_dir: Path) -> dict[str, int]:
    """Import articles from queue.json into the SQLite items table.

    Args:
        queue_file:   Path to data/queue.json.
        articles_dir: Path to data/articles/ (transcript text files).

    Returns:
        A dict with counts: ``{"imported": N, "skipped": N, "errors": N}``.
    """
    from wilted.db import Item

    if not queue_file.exists():
        logger.info("No queue.json found at %s; nothing to migrate.", queue_file)
        return {"imported": 0, "skipped": 0, "errors": 0}

    try:
        raw = json.loads(queue_file.read_text())
    except (json.JSONDecodeError, OSError) as e:
        logger.error("Failed to read queue.json: %s", e)
        return {"imported": 0, "skipped": 0, "errors": 1}

    if not isinstance(raw, list):
        logger.error("queue.json is not a list; aborting migration.")
        return {"imported": 0, "skipped": 0, "errors": 1}

    counts = {"imported": 0, "skipped": 0, "errors": 0}
    now_utc = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    for entry in raw:
        try:
            canonical_url = entry.get("canonical_url") or None
            guid = str(uuid.uuid4())

            # Skip if already migrated.
            # Primary check: canonical_url (unique index).
            # Fallback for items without canonical_url: match by title + source_url.
            existing = None
            if canonical_url:
                try:
                    existing = Item.get(Item.canonical_url == canonical_url)
                except Item.DoesNotExist:
                    pass
            if existing is None:
                title = entry.get("title") or "Untitled"
                source_url = entry.get("source_url") or None
                q = Item.select().where(Item.title == title)
                if source_url:
                    q = q.where(Item.source_url == source_url)
                existing = q.first()

            if existing is not None:
                logger.debug("Skipping already-migrated item: %s", entry.get("title"))
                counts["skipped"] += 1
                continue

            transcript_file = _resolve_transcript_path(articles_dir, entry.get("file", ""))
            discovered_at = _to_utc(entry.get("added", ""))

            Item.create(
                feed=None,
                guid=guid,
                title=entry.get("title") or "Untitled",
                source_url=entry.get("source_url") or None,
                canonical_url=canonical_url,
                discovered_at=discovered_at,
                item_type="article",
                status="ready",
                status_changed_at=now_utc,
                word_count=entry.get("words") or None,
                transcript_file=transcript_file,
            )
            counts["imported"] += 1
            logger.info("Migrated: %s", entry.get("title"))

        except Exception as e:
            logger.error("Error migrating entry %s: %s", entry.get("title"), e)
            counts["errors"] += 1

    return counts


def cmd_migrate(argv: list[str] | None = None) -> None:
    """CLI handler: ``wilted migrate``.

    Reads queue.json from the project data directory and imports articles
    into the SQLite items table.
    """
    from wilted import ARTICLES_DIR, DATA_DIR, QUEUE_FILE
    from wilted.db import connect_db, run_migrations

    run_migrations(DATA_DIR / "wilted.db")
    connect_db(DATA_DIR / "wilted.db")

    print(f"Migrating {QUEUE_FILE} → SQLite...")
    counts = run_migration(QUEUE_FILE, ARTICLES_DIR)
    print(f"Done: {counts['imported']} imported, {counts['skipped']} skipped, {counts['errors']} errors.")
