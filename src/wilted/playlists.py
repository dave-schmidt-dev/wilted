"""Playlist management for wilted — CRUD, queries, and expiry.

Playlists are either dynamic (items matched by metadata fields) or static
(items manually ordered via playlist_items rows).

Built-in dynamic playlists created by ensure_default_playlists():
  - All        (expiry_days=None): every ready/selected item, oldest first
  - Work       (expiry_days=7):   items where effective playlist = 'Work'
  - Fun        (expiry_days=7):   items where effective playlist = 'Fun'
  - Education  (expiry_days=7):   items where effective playlist = 'Education'

Public API:
    ensure_default_playlists()
    list_playlists() -> list[Playlist]
    create_playlist(name) -> Playlist
    delete_playlist(name)
    add_to_playlist(playlist_name, item_id, position=None)
    remove_from_playlist(playlist_name, item_id)
    get_playlist_items(playlist_name) -> list[dict]
    run_expiry() -> int
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from pathlib import Path

from wilted.db import ensure_db as _ensure_db
from wilted.db import now_utc as _now_utc

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Built-in dynamic playlists
# ---------------------------------------------------------------------------

_DEFAULT_PLAYLISTS: list[dict] = [
    {"name": "All", "expiry_days": None},
    {"name": "Work", "expiry_days": 7},
    {"name": "Fun", "expiry_days": 7},
    {"name": "Education", "expiry_days": 7},
]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _item_to_dict(item) -> dict:
    """Convert a Peewee Item model instance to a playlist entry dict.

    Includes all fields needed by downstream consumers plus a ``file`` key
    derived from ``transcript_file`` for backward compatibility with the TUI.

    Args:
        item: A Peewee Item model instance.

    Returns:
        Dict with keys: id, title, words, source_url, canonical_url, file,
        added, audio_file, status, playlist_assigned, playlist_override,
        relevance_score, summary, item_type, keep.
    """
    from wilted import ARTICLES_DIR

    if item.transcript_file:
        tf = Path(item.transcript_file)
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
        "added": item.discovered_at or _now_utc(),
        "audio_file": item.audio_file,
        "status": item.status,
        "playlist_assigned": item.playlist_assigned,
        "playlist_override": item.playlist_override,
        "relevance_score": item.relevance_score,
        "summary": item.summary,
        "item_type": item.item_type,
        "keep": item.keep,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def ensure_default_playlists() -> None:
    """Create the four built-in dynamic playlists if they do not yet exist.

    Idempotent — safe to call on every startup.  Existing rows are left
    unchanged so user edits to expiry_days persist across restarts.
    """
    from wilted.db import Playlist

    _ensure_db()
    now = _now_utc()
    for spec in _DEFAULT_PLAYLISTS:
        Playlist.get_or_create(
            name=spec["name"],
            defaults={
                "playlist_type": "dynamic",
                "expiry_days": spec["expiry_days"],
                "created_at": now,
            },
        )
    logger.debug("ensure_default_playlists: defaults present")


def list_playlists() -> list:
    """Return all playlists sorted by type then name.

    Returns:
        List of Playlist model instances, dynamic playlists first then static,
        each group sorted alphabetically by name.
    """
    from wilted.db import Playlist

    _ensure_db()
    return list(Playlist.select().order_by(Playlist.playlist_type, Playlist.name))


def create_playlist(name: str):
    """Create a static playlist with the given name.

    Args:
        name: Playlist name. Must be unique.

    Returns:
        The newly created Playlist model instance.

    Raises:
        ValueError: If a playlist with *name* already exists.
    """
    from wilted.db import Playlist

    _ensure_db()
    if Playlist.select().where(Playlist.name == name).exists():
        raise ValueError(f"Playlist '{name}' already exists")

    now = _now_utc()
    playlist = Playlist.create(
        name=name,
        playlist_type="static",
        expiry_days=None,
        created_at=now,
    )
    logger.info("Created static playlist: %s", name)
    return playlist


def delete_playlist(name: str) -> None:
    """Delete a static playlist by name.

    Args:
        name: Name of the playlist to delete.

    Raises:
        ValueError: If the playlist does not exist or is a dynamic playlist.
    """
    from wilted.db import Playlist

    _ensure_db()
    try:
        playlist = Playlist.get(Playlist.name == name)
    except Playlist.DoesNotExist:
        raise ValueError(f"Playlist '{name}' not found")

    if playlist.playlist_type == "dynamic":
        raise ValueError(f"Cannot delete dynamic playlist '{name}'")

    playlist.delete_instance()
    logger.info("Deleted static playlist: %s", name)


def add_to_playlist(playlist_name: str, item_id: int, position: int | None = None) -> None:
    """Add an item to a static playlist.

    Args:
        playlist_name: Name of the target playlist (must be static).
        item_id:       Primary key of the item to add.
        position:      Optional sort position within the playlist. If None,
                       the item is appended (highest existing position + 1).

    Raises:
        ValueError: If the playlist does not exist or is dynamic.
    """
    from wilted.db import Item, Playlist, PlaylistItem

    _ensure_db()
    try:
        playlist = Playlist.get(Playlist.name == playlist_name)
    except Playlist.DoesNotExist:
        raise ValueError(f"Playlist '{playlist_name}' not found")

    if playlist.playlist_type == "dynamic":
        raise ValueError(f"Cannot manually add items to dynamic playlist '{playlist_name}'")

    item = Item.get_by_id(item_id)

    if position is None:
        existing = (
            PlaylistItem.select(PlaylistItem.position)
            .where(PlaylistItem.playlist == playlist)
            .order_by(PlaylistItem.position.desc())
            .first()
        )
        position = (existing.position or 0) + 1 if existing else 1

    PlaylistItem.create(
        playlist=playlist,
        item=item,
        added_at=_now_utc(),
        position=position,
    )
    logger.debug("Added item #%d to playlist '%s' at position %d", item_id, playlist_name, position)


def remove_from_playlist(playlist_name: str, item_id: int) -> None:
    """Remove an item from a playlist.

    Args:
        playlist_name: Name of the playlist.
        item_id:       Primary key of the item to remove.

    Raises:
        ValueError: If the playlist does not exist.
    """
    from wilted.db import Playlist, PlaylistItem

    _ensure_db()
    try:
        playlist = Playlist.get(Playlist.name == playlist_name)
    except Playlist.DoesNotExist:
        raise ValueError(f"Playlist '{playlist_name}' not found")

    PlaylistItem.delete().where((PlaylistItem.playlist == playlist) & (PlaylistItem.item_id == item_id)).execute()
    logger.debug("Removed item #%d from playlist '%s'", item_id, playlist_name)


def get_playlist_items(playlist_name: str) -> list[dict]:
    """Return items for a playlist as a list of dicts.

    Behaviour varies by playlist type / name:
    - "All": all items with status in (ready, selected), sorted by
      discovered_at ASC (oldest first).
    - Named dynamic (Work/Fun/Education): items where
      COALESCE(playlist_override, playlist_assigned) = playlist_name and
      status in (ready, selected), sorted by relevance_score DESC.
    - Static: items joined through playlist_items, sorted by position ASC.

    Args:
        playlist_name: Name of the playlist to query.

    Returns:
        List of item dicts (see _item_to_dict for keys).

    Raises:
        ValueError: If no playlist with *playlist_name* exists.
    """
    from peewee import fn

    from wilted.db import Item, Playlist, PlaylistItem

    _ensure_db()
    try:
        playlist = Playlist.get(Playlist.name == playlist_name)
    except Playlist.DoesNotExist:
        raise ValueError(f"Playlist '{playlist_name}' not found")

    ready_statuses = ("ready", "selected")

    if playlist_name == "All":
        items = list(Item.select().where(Item.status.in_(ready_statuses)).order_by(Item.discovered_at.asc()))

    elif playlist.playlist_type == "dynamic":
        # COALESCE(playlist_override, playlist_assigned) = name
        effective = fn.COALESCE(Item.playlist_override, Item.playlist_assigned)
        items = list(
            Item.select()
            .where(Item.status.in_(ready_statuses) & (effective == playlist_name))
            .order_by(Item.relevance_score.desc())
        )

    else:
        # Static: join through playlist_items, order by position
        items = list(
            Item.select()
            .join(PlaylistItem)
            .where(PlaylistItem.playlist == playlist)
            .order_by(PlaylistItem.position.asc())
        )

    return [_item_to_dict(it) for it in items]


def run_expiry() -> int:
    """Expire items that have exceeded their playlist's expiry_days threshold.

    Only applies to dynamic playlists that have expiry_days set (i.e. not
    "All", which has expiry_days=None).  Items with ``keep=True`` are exempt.

    An item is expired when its ``discovered_at`` timestamp is older than
    ``expiry_days`` days.  Expiry sets ``status='expired'`` and ``keep=False``.

    Returns:
        Number of items expired.
    """
    from wilted.db import Item, Playlist

    _ensure_db()
    now = datetime.now(UTC)
    expired_count = 0

    dynamic_playlists = list(
        Playlist.select().where((Playlist.playlist_type == "dynamic") & (Playlist.expiry_days.is_null(False)))
    )

    for playlist in dynamic_playlists:
        # Collect names that map to this playlist (via assigned or override)
        from peewee import fn

        effective = fn.COALESCE(Item.playlist_override, Item.playlist_assigned)
        candidates = list(
            Item.select().where(
                Item.status.in_(("ready", "selected"))
                & Item.keep.is_null(False)
                & (Item.keep == False)  # noqa: E712
                & (effective == playlist.name)
            )
        )

        cutoff_days = playlist.expiry_days
        status_now = _now_utc()

        for item in candidates:
            if not item.discovered_at:
                continue
            try:
                discovered = datetime.fromisoformat(item.discovered_at.replace("Z", "+00:00"))
            except ValueError:
                continue

            age_days = (now - discovered).days
            if age_days >= cutoff_days:
                item.status = "expired"
                item.status_changed_at = status_now
                item.save()
                expired_count += 1
                logger.info(
                    "Expired item #%d '%s' (age=%d days, playlist=%s)",
                    item.id,
                    item.title,
                    age_days,
                    playlist.name,
                )

    return expired_count


# ---------------------------------------------------------------------------
# Resume position
# ---------------------------------------------------------------------------


def get_resume_position(item_id: int) -> dict | None:
    """Get resume position for an item, or None if not saved.

    Args:
        item_id: Primary key of the item.

    Returns:
        Dict with keys ``paragraph_idx`` and ``segment_in_paragraph``, or
        ``None`` if no resume position has been saved for this item.
    """
    from wilted.db import Item

    _ensure_db()
    try:
        item = Item.get_by_id(item_id)
    except Item.DoesNotExist:
        return None

    if not item.metadata:
        return None

    try:
        meta = json.loads(item.metadata)
    except (ValueError, TypeError):
        return None

    resume = meta.get("resume")
    if resume is None:
        return None

    return {
        "paragraph_idx": resume["paragraph_idx"],
        "segment_in_paragraph": resume.get("segment_in_paragraph", 0),
    }


def set_resume_position(item_id: int, paragraph_idx: int, segment_in_paragraph: int = 0) -> None:
    """Save resume position in item metadata JSON field.

    Reads existing metadata, merges the ``resume`` key, and writes back.
    Other metadata keys are preserved.

    Args:
        item_id:              Primary key of the item.
        paragraph_idx:        Index of the paragraph to resume from.
        segment_in_paragraph: Index of the segment within the paragraph
                              (default 0).
    """
    from wilted.db import Item

    _ensure_db()
    item = Item.get_by_id(item_id)

    if item.metadata:
        try:
            meta = json.loads(item.metadata)
        except (ValueError, TypeError):
            meta = {}
    else:
        meta = {}

    meta["resume"] = {
        "paragraph_idx": paragraph_idx,
        "segment_in_paragraph": segment_in_paragraph,
        "updated": _now_utc(),
    }

    item.metadata = json.dumps(meta)
    item.save()
    logger.debug(
        "set_resume_position: item #%d → paragraph=%d segment=%d",
        item_id,
        paragraph_idx,
        segment_in_paragraph,
    )


def clear_resume_position(item_id: int) -> None:
    """Remove the ``resume`` key from item metadata.

    Preserves all other metadata keys.  No-op if the item does not exist or
    has no resume position saved.

    Args:
        item_id: Primary key of the item.
    """
    from wilted.db import Item

    _ensure_db()
    try:
        item = Item.get_by_id(item_id)
    except Item.DoesNotExist:
        return

    if not item.metadata:
        return

    try:
        meta = json.loads(item.metadata)
    except (ValueError, TypeError):
        return

    if "resume" not in meta:
        return

    del meta["resume"]
    item.metadata = json.dumps(meta) if meta else None
    item.save()
    logger.debug("clear_resume_position: item #%d resume cleared", item_id)
