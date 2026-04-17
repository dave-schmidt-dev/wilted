"""Reading list queue — SQLite-backed article management.

Public interface is unchanged from the legacy JSON version so all existing
call sites in cli.py and tui/__init__.py continue to work without modification.

Item lifecycle (status transitions):
  add_article()    → status='ready'
  mark_completed() → status='completed'  (files retained; cleanup by retention policy)
  remove_article() → row deleted + transcript file deleted
  clear_queue()    → all 'ready' rows deleted + files deleted
"""

from __future__ import annotations

import logging
import re
import uuid
from datetime import UTC, datetime
from pathlib import Path

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_to_local_date(ts: str) -> str:
    """Convert a UTC ISO 8601 timestamp to a local-timezone date string (YYYY-MM-DD).

    Used for display only — all stored timestamps remain UTC.
    Falls back to the first 10 characters of *ts* on parse error.
    """
    if not ts:
        return ""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
        return dt.strftime("%Y-%m-%d")
    except (ValueError, TypeError):
        return ts[:10]


def _slugify(text: str, max_len: int = 50) -> str:
    slug = re.sub(r"[^\w\s-]", "", text.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug[:max_len]


def _item_to_dict(item) -> dict:
    """Convert a Peewee Item model instance to the legacy queue entry dict."""
    from wilted import ARTICLES_DIR

    # Derive the filename from the full transcript_file path (for backward compat)
    if item.transcript_file:
        tf = Path(item.transcript_file)
        # Use just the filename relative to ARTICLES_DIR for legacy compat
        try:
            rel = tf.relative_to(ARTICLES_DIR)
            file_field = str(rel)
        except ValueError:
            file_field = tf.name
    else:
        file_field = ""

    return {
        "id": item.id,
        "title": item.title,
        "words": item.word_count or 0,
        "source_url": item.source_url,
        "canonical_url": item.canonical_url,
        "file": file_field,
        # Legacy TUI/CLI code reads 'added' for display; use discovered_at
        "added": item.discovered_at or _now_utc(),
        # Extra fields available via SQLite (ignored by legacy code)
        "audio_file": item.audio_file,
        "status": item.status,
    }


def _ensure_db() -> None:
    """Ensure DB is connected (safe to call multiple times)."""
    from wilted import DATA_DIR
    from wilted.db import connect_db

    connect_db(DATA_DIR / "wilted.db")


# ---------------------------------------------------------------------------
# Public API — same signatures as before
# ---------------------------------------------------------------------------


def load_queue() -> list[dict]:
    """Return all 'ready' articles as a list of legacy-format dicts."""
    from wilted.db import Item

    _ensure_db()
    items = list(Item.select().where(Item.status == "ready").order_by(Item.discovered_at))
    return [_item_to_dict(it) for it in items]


def add_article(
    text: str,
    title: str | None = None,
    source_url: str | None = None,
    canonical_url: str | None = None,
) -> dict:
    """Save article text and add to the reading list. Returns the new entry dict."""
    from wilted import ARTICLES_DIR, ensure_data_dirs
    from wilted.db import Item

    _ensure_db()
    ensure_data_dirs()

    if not title:
        title = text.split("\n")[0][:80]

    word_count = len(text.split())
    slug = _slugify(title)
    now = _now_utc()

    # Determine next numeric ID by inserting and getting the auto-id
    item = Item.create(
        feed=None,
        guid=str(uuid.uuid4()),
        title=title,
        source_url=source_url or None,
        canonical_url=canonical_url or None,
        discovered_at=now,
        item_type="article",
        status="ready",
        status_changed_at=now,
        word_count=word_count,
    )

    # Write transcript file using the SQLite-assigned ID
    filename = f"{item.id}_{slug}.txt"
    article_path = ARTICLES_DIR / filename
    article_path.write_text(text)

    item.transcript_file = str(article_path)
    item.save()

    logger.info("Added article #%d: %s", item.id, title)
    return _item_to_dict(item)


def remove_article(index: int) -> dict:
    """Remove article at 0-based index from the ready queue. Returns removed entry.

    Raises IndexError if index is out of range.
    """
    from wilted.db import Item

    _ensure_db()
    items = list(Item.select().where(Item.status == "ready").order_by(Item.discovered_at))
    if index < 0 or index >= len(items):
        raise IndexError(f"Invalid index {index}. Queue has {len(items)} article(s).")

    item = items[index]
    entry = _item_to_dict(item)

    if item.transcript_file:
        tf = Path(item.transcript_file)
        if tf.exists():
            tf.unlink()

    from wilted.cache import clear_cache

    clear_cache(item.id)
    item.delete_instance()
    return entry


def clear_queue() -> int:
    """Remove all 'ready' articles. Returns count removed."""
    from wilted.db import Item

    _ensure_db()
    items = list(Item.select().where(Item.status == "ready"))
    if not items:
        return 0

    from wilted.cache import clear_cache

    for item in items:
        if item.transcript_file:
            tf = Path(item.transcript_file)
            if tf.exists():
                tf.unlink()
        clear_cache(item.id)
        item.delete_instance()

    return len(items)


def get_article_text(entry: dict) -> str | None:
    """Read cached article text for a queue entry dict."""
    from wilted import ARTICLES_DIR
    from wilted.db import Item

    _ensure_db()

    # Prefer transcript_file from the dict (set by _item_to_dict for SQLite items)
    # Fall back to looking up the item by ID
    try:
        item = Item.get_by_id(entry["id"])
        if item.transcript_file:
            tf = Path(item.transcript_file)
            if tf.exists():
                return tf.read_text()
    except Exception:
        pass

    # Legacy fallback: try ARTICLES_DIR / entry["file"]
    filename = entry.get("file", "")
    if filename:
        article_path = ARTICLES_DIR / filename
        if article_path.exists():
            return article_path.read_text()

    return None


def mark_completed(entry: dict) -> None:
    """Mark article as completed. Files are retained (cleaned up by retention policy)."""
    from wilted.db import Item

    _ensure_db()
    now = _now_utc()
    try:
        item = Item.get_by_id(entry["id"])
        item.status = "completed"
        item.status_changed_at = now
        item.save()
        logger.info("Marked completed: #%d %s", item.id, item.title)
    except Item.DoesNotExist:
        logger.warning("mark_completed: item #%d not found", entry.get("id"))


# ---------------------------------------------------------------------------
# Retention policy (Task 1.10)
# ---------------------------------------------------------------------------


def run_retention(retention_days: int = 30) -> int:
    """Delete files for completed items older than retention_days.

    Items with ``keep=True`` are exempt.  Returns number of items cleaned up.
    """
    from wilted.db import Item

    _ensure_db()
    cutoff = datetime.now(UTC)

    cleaned = 0
    for item in Item.select().where(Item.status == "completed", Item.keep == False):  # noqa: E712
        if not item.status_changed_at:
            continue
        try:
            changed = datetime.fromisoformat(item.status_changed_at.replace("Z", "+00:00"))
        except ValueError:
            continue

        age_days = (cutoff - changed).days
        if age_days >= retention_days:
            if item.transcript_file:
                tf = Path(item.transcript_file)
                if tf.exists():
                    tf.unlink()
                    item.transcript_file = None
            if item.audio_file:
                af = Path(item.audio_file)
                if af.exists():
                    af.unlink()
                    item.audio_file = None
            item.save()
            cleaned += 1
            logger.info("Retention cleanup: #%d %s (%d days old)", item.id, item.title, age_days)

    return cleaned


# ---------------------------------------------------------------------------
# Legacy save_queue — kept for backward compat but now a no-op
# (state lives in SQLite; the old JSON file is superseded)
# ---------------------------------------------------------------------------


def save_queue(queue: list[dict]) -> None:
    """No-op: queue is now persisted via SQLite.  Kept for import compatibility."""
    logger.debug("save_queue() called — no-op in SQLite-backed mode")
