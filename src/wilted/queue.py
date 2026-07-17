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

from wilted.background_work.contracts import (
    AnalysisState,
    ContentState,
    FetchState,
    PlaybackState,
    PreparationState,
    RetentionFacts,
    RetentionState,
)
from wilted.content_state import (
    items_for_retention_cleanup,
    items_playable_in_queue,
    items_playable_ready_only,
    legacy_display_status,
    read_content_state,
    transition_item,
)
from wilted.db import ensure_db as _ensure_db
from wilted.db import now_utc as _now_utc

logger = logging.getLogger(__name__)


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
        "status": legacy_display_status(item),
        # Playback routing: 'article' | 'podcast_episode'. The TUI branches on
        # this so a prepared podcast plays its finalized audio artifact rather
        # than being re-synthesized through the article/TTS path.
        "item_type": item.item_type,
    }


# ---------------------------------------------------------------------------
# Public API — same signatures as before
# ---------------------------------------------------------------------------


def load_queue() -> list[dict]:
    """Return all playable items as legacy-format dicts.

    Includes:
    - 'ready' items of any type (Phase 4 has prepared them for playback)
    - 'selected' articles (transcript file already exists; playable immediately)

    Selected podcast episodes are excluded -- they need Phase 4 (download +
    transcription) before they can be played.
    """

    _ensure_db()
    items = items_playable_in_queue()
    return [_item_to_dict(it) for it in items]


def add_article(
    text: str,
    title: str | None = None,
    source_url: str | None = None,
    canonical_url: str | None = None,
) -> dict:
    """Save article text and add to the reading list. Returns the new entry dict."""
    from wilted import ARTICLES_DIR, ensure_data_dirs
    from wilted.db import Item, legacy_status_create_fields

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
        word_count=word_count,
        **legacy_status_create_fields(status="ready", changed_at=now),
    )

    # Write transcript file using the SQLite-assigned ID
    filename = f"{item.id}_{slug}.txt"
    article_path = ARTICLES_DIR / filename
    article_path.write_text(text)

    item.transcript_file = str(article_path)
    item.save()

    transition_item(
        item,
        ContentState(
            fetch=FetchState.CONTENT_READY,
            analysis=AnalysisState.READY,
            preparation=PreparationState.READY,
            playback=PlaybackState.UNPLAYED,
            retention=RetentionFacts(state=RetentionState.ACTIVE),
        ),
        sync_legacy_status=True,
        legacy_status="ready",
    )

    logger.info("Added article #%d: %s", item.id, title)
    return _item_to_dict(item)


def remove_article(index: int) -> dict:
    """Remove article at 0-based index from the ready queue. Returns removed entry.

    Raises IndexError if index is out of range.
    """

    _ensure_db()
    items = items_playable_in_queue()
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


def remove_article_by_id(item_id: int) -> dict:
    """Remove an article by its database ID. Returns removed entry dict.

    Raises ValueError if item not found.
    """
    from wilted.db import Item

    _ensure_db()
    try:
        item = Item.get_by_id(item_id)
    except Item.DoesNotExist:
        raise ValueError(f"Item #{item_id} not found")

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

    _ensure_db()
    items = items_playable_ready_only()
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
    try:
        item = Item.get_by_id(entry["id"])
        current = read_content_state(item)
        transition_item(
            item,
            ContentState(
                fetch=current.fetch if current else FetchState.CONTENT_READY,
                analysis=current.analysis if current else AnalysisState.READY,
                preparation=current.preparation if current else PreparationState.READY,
                playback=PlaybackState.COMPLETED,
                retention=current.retention if current else RetentionFacts(state=RetentionState.ACTIVE),
            ),
        )
        logger.info("Marked completed: #%d %s", item.id, item.title)
    except Item.DoesNotExist:
        logger.warning("mark_completed: item #%d not found", entry.get("id"))


# ---------------------------------------------------------------------------
# Retention policy (Task 1.10)
# ---------------------------------------------------------------------------


def run_retention(retention_days: int = 30) -> int:
    """Remove audio/transcript files for completed items older than retention_days.

    The item record itself is preserved permanently for metrics and analysis.
    Only the on-disk files (transcript_file, audio_file) are deleted and the
    paths nulled.  Items with ``keep=True`` are exempt.

    Returns number of items whose files were cleaned up.
    """

    _ensure_db()
    from wilted.db import Item

    cutoff = datetime.now(UTC)

    cleaned = 0
    for item in items_for_retention_cleanup():
        # Prefer legacy status_changed_at when present (pre-cutover); otherwise
        # fall back to discovered_at (post-cutover has no status_changed_at).
        changed_raw = None
        if "status_changed_at" in Item._meta.fields:
            changed_raw = item.status_changed_at
        if not changed_raw:
            changed_raw = item.discovered_at
        if not changed_raw:
            continue
        try:
            changed = datetime.fromisoformat(changed_raw.replace("Z", "+00:00"))
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
