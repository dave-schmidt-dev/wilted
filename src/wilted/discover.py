"""Discovery stage — poll RSS/Atom feeds, dedup, and ingest new items.

Stage 1 of the nightly pipeline. Network-bound, no models loaded.

Workflow:
  1. Poll all enabled feeds via feedparser (conditional GET with ETag/Last-Modified)
  2. Dedup entries against existing items (GUID, canonical URL, content hash)
  3. Articles: fetch full text via trafilatura, store transcript, status -> 'fetched'
  4. Podcasts: metadata from RSS only, status -> 'fetched'

Partial failures (single feed errors) are logged and skipped; the stage
returns 0 if at least one item was successfully processed.

Usage:
    from wilted.discover import run_discover
    stats = run_discover()  # {'discovered': 5, 'feeds_polled': 3, 'errors': 1}
"""

from __future__ import annotations

import hashlib
import logging
import re
import unicodedata
import uuid
from datetime import UTC, datetime
from time import struct_time

import feedparser

from wilted.db import Feed, Item, _db
from wilted.feeds import _ensure_db, update_feed

logger = logging.getLogger(__name__)

# User-Agent for feed requests
_USER_AGENT = "Wilted/0.3 (+https://github.com/zerodel/wilted)"


def _now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _struct_time_to_utc(st: struct_time | None) -> str | None:
    """Convert feedparser's struct_time to UTC ISO 8601 string."""
    if st is None:
        return None
    try:
        from calendar import timegm

        ts = timegm(st)
        return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return None


def _normalize_text(text: str) -> str:
    """NFKD-normalize and lowercase text for dedup hashing."""
    return unicodedata.normalize("NFKD", text).lower().strip()


def _dedup_hash(title: str, pub_date: str | None, link: str | None) -> str:
    """Compute SHA-256 hash for dedup fallback.

    Hash of: NFKD-lowercase title | UTC-minute pubDate | link
    """
    parts = [
        _normalize_text(title),
        (pub_date or "")[:16],  # Truncate to minute precision
        (link or "").strip(),
    ]
    content = "|".join(parts)
    return hashlib.sha256(content.encode()).hexdigest()


def _entry_guid(entry) -> str | None:
    """Extract GUID from a feedparser entry."""
    guid = getattr(entry, "id", None) or entry.get("id")
    if guid:
        return str(guid).strip()
    return None


def _entry_link(entry) -> str | None:
    """Extract the primary link from a feedparser entry."""
    link = getattr(entry, "link", None) or entry.get("link")
    if link:
        return str(link).strip()
    return None


def _entry_enclosure(entry) -> tuple[str | None, str | None]:
    """Extract podcast enclosure URL and type from a feedparser entry."""
    enclosures = entry.get("enclosures", [])
    for enc in enclosures:
        href = enc.get("href") or enc.get("url")
        enc_type = enc.get("type", "")
        if href and ("audio" in enc_type or href.endswith((".mp3", ".m4a", ".ogg", ".wav"))):
            return href, enc_type
    # Fallback: check links for audio
    for link in entry.get("links", []):
        if link.get("type", "").startswith("audio/"):
            return link.get("href"), link.get("type")
    return None, None


def _is_duplicate(feed: Feed, guid: str | None, canonical_url: str | None, content_hash: str) -> bool:
    """Check if an item already exists using the three-tier dedup strategy.

    Order: GUID -> canonical URL -> content hash (stored in metadata).
    """
    # Tier 1: GUID match within the same feed
    if guid and feed:
        exists = Item.select().where(Item.feed == feed, Item.guid == guid).exists()
        if exists:
            return True

    # Tier 2: Canonical URL match (any feed)
    if canonical_url:
        exists = Item.select().where(Item.canonical_url == canonical_url).exists()
        if exists:
            return True

    # Tier 3: Content hash in metadata (any feed)
    # We store the hash in the item's metadata JSON
    import json

    for item in Item.select(Item.metadata).where(Item.metadata.is_null(False)):
        try:
            meta = json.loads(item.metadata)
            if meta.get("content_hash") == content_hash:
                return True
        except (json.JSONDecodeError, TypeError):
            continue

    return False


def _fetch_article_text(url: str) -> tuple[str | None, str | None]:
    """Fetch article full text via trafilatura.

    Returns:
        Tuple of (text, title) or (None, None) on failure.
    """
    try:
        from wilted.fetch import suppress_subprocess_output

        with suppress_subprocess_output():
            import trafilatura

            html = trafilatura.fetch_url(url)

        if not html:
            return None, None

        doc = trafilatura.bare_extraction(html, include_comments=False, include_tables=False)
        doc_text = getattr(doc, "text", None) if doc else None
        if not doc_text:
            return None, None

        from wilted.text import clean_text

        text = clean_text(doc_text)
        title = getattr(doc, "title", None)
        return text, title

    except Exception as e:
        logger.warning("Failed to fetch article text from %s: %s", url, e)
        return None, None


def _save_transcript(item_id: int, title: str, text: str) -> str:
    """Save article transcript text to disk. Returns the file path."""
    from wilted import ARTICLES_DIR, ensure_data_dirs

    ensure_data_dirs()

    slug = re.sub(r"[^\w\s-]", "", title.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")[:50]
    filename = f"{item_id}_{slug}.txt"
    path = ARTICLES_DIR / filename
    path.write_text(text, encoding="utf-8")
    return str(path)


def _poll_feed(feed: Feed) -> dict:
    """Poll a single feed and process new entries.

    Returns:
        Dict with counts: {'new': int, 'skipped': int, 'errors': int}
    """
    stats = {"new": 0, "skipped": 0, "errors": 0}

    logger.info("Polling feed #%d: %s", feed.id, feed.feed_url)

    # feedparser handles conditional GET via etag and modified
    kwargs = {"agent": _USER_AGENT}
    if feed.etag:
        kwargs["etag"] = feed.etag
    if feed.last_modified:
        kwargs["modified"] = feed.last_modified

    parsed = feedparser.parse(feed.feed_url, **kwargs)

    # Check for HTTP status
    http_status = getattr(parsed, "status", 200)

    if http_status == 304:
        logger.info("Feed #%d: not modified (304)", feed.id)
        update_feed(feed.id, last_checked_at=_now_utc())
        return stats

    if http_status >= 400:
        logger.warning("Feed #%d: HTTP %d", feed.id, http_status)
        stats["errors"] = 1
        return stats

    # Update ETag/Last-Modified for next poll
    new_etag = getattr(parsed, "etag", None)
    new_modified = getattr(parsed, "modified", None)
    # feedparser stores modified as a string
    if isinstance(new_modified, struct_time):
        new_modified = _struct_time_to_utc(new_modified)

    update_fields = {"last_checked_at": _now_utc()}
    if new_etag:
        update_fields["etag"] = new_etag
    if new_modified:
        update_fields["last_modified"] = str(new_modified)

    # Update feed title from parsed feed if we used the URL as title
    feed_title = getattr(parsed.feed, "title", None)
    if feed_title and feed.title == feed.feed_url:
        update_fields["title"] = feed_title

    update_feed(feed.id, **update_fields)

    # For podcast feeds, limit to the most recent episodes on initial discovery.
    # RSS feeds list entries newest-first; cap at 5 to avoid ingesting a backlog
    # of hundreds of episodes from long-running shows.
    entries = parsed.entries
    if feed.feed_type == "podcast":
        existing_count = Item.select().where(Item.feed == feed).count()
        if existing_count == 0:
            entries = entries[:5]

    # Process entries
    for entry in entries:
        try:
            _process_entry(feed, entry, stats)
        except Exception as e:
            logger.warning("Error processing entry in feed #%d: %s", feed.id, e)
            stats["errors"] += 1

    logger.info(
        "Feed #%d: %d new, %d skipped, %d errors",
        feed.id,
        stats["new"],
        stats["skipped"],
        stats["errors"],
    )
    return stats


def _process_entry(feed: Feed, entry, stats: dict) -> None:
    """Process a single feed entry — dedup and insert if new."""
    import json

    title = getattr(entry, "title", None) or entry.get("title", "Untitled")
    guid = _entry_guid(entry)
    link = _entry_link(entry)
    published = _struct_time_to_utc(entry.get("published_parsed"))
    author = getattr(entry, "author", None) or entry.get("author")

    # Compute dedup hash
    content_hash = _dedup_hash(title, published, link)

    if _is_duplicate(feed, guid, link, content_hash):
        stats["skipped"] += 1
        return

    now = _now_utc()

    if feed.feed_type == "podcast":
        enclosure_url, enclosure_type = _entry_enclosure(entry)
        if not enclosure_url:
            logger.debug("Skipping podcast entry without audio enclosure: %s", title)
            stats["skipped"] += 1
            return

        item = Item.create(
            feed=feed,
            guid=guid or str(uuid.uuid4()),
            title=title,
            author=author,
            source_name=feed.title,
            source_url=link,
            canonical_url=link,
            published_at=published,
            discovered_at=now,
            item_type="podcast_episode",
            status="fetched",
            status_changed_at=now,
            enclosure_url=enclosure_url,
            enclosure_type=enclosure_type,
            playlist_assigned=feed.default_playlist,
            metadata=json.dumps({"content_hash": content_hash}),
        )
        logger.debug("Discovered podcast episode #%d: %s", item.id, title)
        stats["new"] += 1

    else:
        # Article: fetch full text
        article_text = None
        article_title = title

        if link:
            article_text, fetched_title = _fetch_article_text(link)
            if fetched_title:
                article_title = fetched_title

        # Fallback: use RSS summary/content
        if not article_text:
            summary = entry.get("summary", "")
            content_entries = entry.get("content", [])
            if content_entries:
                # Prefer the first content entry's value
                summary = content_entries[0].get("value", summary)
            if summary:
                from wilted.text import clean_text

                article_text = clean_text(summary)

        if not article_text:
            logger.warning("Could not fetch text for article: %s", title)
            stats["errors"] += 1
            return

        word_count = len(article_text.split())

        # Wrap create + transcript save in a transaction so a failed
        # write_text() doesn't leave an orphaned DB record.
        with _db.atomic():
            item = Item.create(
                feed=feed,
                guid=guid or str(uuid.uuid4()),
                title=article_title,
                author=author,
                source_name=feed.title,
                source_url=link,
                canonical_url=link,
                published_at=published,
                discovered_at=now,
                item_type="article",
                status="fetched",
                status_changed_at=now,
                word_count=word_count,
                playlist_assigned=feed.default_playlist,
                metadata=json.dumps({"content_hash": content_hash}),
            )

            # Save transcript to disk
            transcript_path = _save_transcript(item.id, article_title, article_text)
            item.transcript_file = transcript_path
            item.save()

        logger.debug("Discovered article #%d: %s (%d words)", item.id, article_title, word_count)
        stats["new"] += 1


def run_discover() -> dict:
    """Run the full discovery stage across all enabled feeds.

    Returns:
        Dict with aggregate stats: {'discovered': int, 'feeds_polled': int, 'errors': int}
    """
    _ensure_db()

    feeds = list(Feed.select().where(Feed.enabled == True))  # noqa: E712
    if not feeds:
        logger.info("No enabled feeds to poll")
        return {"discovered": 0, "feeds_polled": 0, "errors": 0}

    total_new = 0
    total_errors = 0

    for feed in feeds:
        try:
            stats = _poll_feed(feed)
            total_new += stats["new"]
            total_errors += stats["errors"]
        except Exception as e:
            logger.error("Failed to poll feed #%d (%s): %s", feed.id, feed.feed_url, e)
            total_errors += 1

    result = {
        "discovered": total_new,
        "feeds_polled": len(feeds),
        "errors": total_errors,
    }
    logger.info("Discovery stage complete: %s", result)
    return result
