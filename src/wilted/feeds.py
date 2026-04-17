"""Feed management — CRUD operations for RSS/Atom feed subscriptions.

Usage:
    from wilted.feeds import add_feed, list_feeds, remove_feed

    feed = add_feed("https://example.com/feed.xml", feed_type="article")
    feeds = list_feeds()
    remove_feed(feed_id=3)
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

from peewee import IntegrityError

from wilted.db import Feed

logger = logging.getLogger(__name__)


def _now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_db() -> None:
    """Ensure DB is connected (safe to call multiple times)."""
    from wilted import DATA_DIR
    from wilted.db import connect_db

    connect_db(DATA_DIR / "wilted.db")


def add_feed(
    feed_url: str,
    *,
    feed_type: str = "article",
    title: str | None = None,
    site_url: str | None = None,
    default_playlist: str | None = None,
) -> Feed:
    """Add a new feed subscription.

    Args:
        feed_url: URL of the RSS/Atom feed.
        feed_type: 'article' or 'podcast'.
        title: Human-readable feed title. Defaults to feed_url if not provided.
        site_url: URL of the website (not the feed).
        default_playlist: Playlist to assign discovered items to.

    Returns:
        The created Feed model instance.

    Raises:
        ValueError: If feed_type is invalid or feed_url already exists.
    """
    _ensure_db()

    if feed_type not in ("article", "podcast"):
        raise ValueError(f"feed_type must be 'article' or 'podcast', got '{feed_type}'")

    now = _now_utc()

    try:
        feed = Feed.create(
            title=title or feed_url,
            feed_url=feed_url,
            site_url=site_url,
            feed_type=feed_type,
            default_playlist=default_playlist,
            enabled=True,
            created_at=now,
            updated_at=now,
        )
    except IntegrityError as e:
        raise ValueError(f"Feed URL already exists: {feed_url}") from e

    logger.info("Added feed #%d: %s (%s)", feed.id, feed.title, feed_type)
    return feed


def list_feeds(*, enabled_only: bool = False) -> list[Feed]:
    """Return all feeds, optionally filtered to enabled only.

    Args:
        enabled_only: If True, only return enabled feeds.

    Returns:
        List of Feed model instances ordered by title.
    """
    _ensure_db()
    query = Feed.select().order_by(Feed.title)
    if enabled_only:
        query = query.where(Feed.enabled == True)  # noqa: E712
    return list(query)


def remove_feed(feed_id: int) -> Feed:
    """Remove a feed by ID. Items from this feed are NOT deleted.

    Args:
        feed_id: The database ID of the feed to remove.

    Returns:
        The removed Feed instance (for display purposes).

    Raises:
        ValueError: If no feed exists with the given ID.
    """
    _ensure_db()
    try:
        feed = Feed.get_by_id(feed_id)
    except Feed.DoesNotExist:
        raise ValueError(f"No feed with ID {feed_id}") from None

    title = feed.title
    feed.delete_instance()
    logger.info("Removed feed #%d: %s", feed_id, title)
    return feed


def update_feed(feed_id: int, **kwargs) -> Feed:
    """Update feed fields by ID.

    Accepted keyword arguments: title, feed_url, site_url, feed_type,
    default_playlist, enabled, etag, last_modified, last_checked_at.

    Args:
        feed_id: The database ID of the feed to update.
        **kwargs: Fields to update.

    Returns:
        The updated Feed instance.

    Raises:
        ValueError: If no feed exists with the given ID or invalid fields.
    """
    _ensure_db()

    allowed = {
        "title",
        "feed_url",
        "site_url",
        "feed_type",
        "default_playlist",
        "enabled",
        "etag",
        "last_modified",
        "last_checked_at",
    }
    invalid = set(kwargs) - allowed
    if invalid:
        raise ValueError(f"Invalid feed fields: {invalid}")

    try:
        feed = Feed.get_by_id(feed_id)
    except Feed.DoesNotExist:
        raise ValueError(f"No feed with ID {feed_id}") from None

    for key, value in kwargs.items():
        setattr(feed, key, value)

    feed.updated_at = _now_utc()
    feed.save()

    logger.info("Updated feed #%d: %s", feed_id, feed.title)
    return feed


def get_feed(feed_id: int) -> Feed:
    """Get a single feed by ID.

    Raises:
        ValueError: If no feed exists with the given ID.
    """
    _ensure_db()
    try:
        return Feed.get_by_id(feed_id)
    except Feed.DoesNotExist:
        raise ValueError(f"No feed with ID {feed_id}") from None
