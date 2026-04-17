"""Tests for Phase 2 — Feed CRUD operations (feeds.py)."""

from __future__ import annotations

import pytest

from wilted.db import Feed
from wilted.feeds import add_feed, get_feed, list_feeds, remove_feed, update_feed


class TestAddFeed:
    def test_basic_add(self):
        feed = add_feed("https://example.com/feed.xml", feed_type="article")
        assert feed.id is not None
        assert feed.feed_url == "https://example.com/feed.xml"
        assert feed.feed_type == "article"
        assert feed.enabled is True
        assert feed.created_at.endswith("Z")

    def test_add_with_all_fields(self):
        feed = add_feed(
            "https://example.com/podcast.xml",
            feed_type="podcast",
            title="My Podcast",
            site_url="https://example.com",
            default_playlist="Fun",
        )
        assert feed.title == "My Podcast"
        assert feed.site_url == "https://example.com"
        assert feed.default_playlist == "Fun"
        assert feed.feed_type == "podcast"

    def test_title_defaults_to_url(self):
        feed = add_feed("https://example.com/rss")
        assert feed.title == "https://example.com/rss"

    def test_duplicate_url_raises(self):
        add_feed("https://example.com/feed.xml")
        with pytest.raises(ValueError, match="already exists"):
            add_feed("https://example.com/feed.xml")

    def test_invalid_feed_type_raises(self):
        with pytest.raises(ValueError, match="feed_type"):
            add_feed("https://example.com/feed.xml", feed_type="video")


class TestListFeeds:
    def test_empty(self):
        assert list_feeds() == []

    def test_returns_all(self):
        add_feed("https://a.com/feed.xml", title="Alpha")
        add_feed("https://b.com/feed.xml", title="Beta")
        feeds = list_feeds()
        assert len(feeds) == 2
        # Ordered by title
        assert feeds[0].title == "Alpha"
        assert feeds[1].title == "Beta"

    def test_enabled_only_filter(self):
        f1 = add_feed("https://a.com/feed.xml", title="Active")
        f2 = add_feed("https://b.com/feed.xml", title="Disabled")
        update_feed(f2.id, enabled=False)

        all_feeds = list_feeds()
        assert len(all_feeds) == 2

        enabled = list_feeds(enabled_only=True)
        assert len(enabled) == 1
        assert enabled[0].id == f1.id


class TestRemoveFeed:
    def test_remove_existing(self):
        feed = add_feed("https://example.com/feed.xml")
        removed = remove_feed(feed.id)
        assert removed.feed_url == "https://example.com/feed.xml"
        assert list_feeds() == []

    def test_remove_nonexistent_raises(self):
        with pytest.raises(ValueError, match="No feed"):
            remove_feed(999)


class TestUpdateFeed:
    def test_update_title(self):
        feed = add_feed("https://example.com/feed.xml", title="Old Title")
        updated = update_feed(feed.id, title="New Title")
        assert updated.title == "New Title"
        assert Feed.get_by_id(feed.id).title == "New Title"

    def test_update_sets_updated_at(self):
        feed = add_feed("https://example.com/feed.xml")
        original_updated = feed.updated_at
        updated = update_feed(feed.id, title="Changed")
        assert updated.updated_at >= original_updated

    def test_update_invalid_field_raises(self):
        feed = add_feed("https://example.com/feed.xml")
        with pytest.raises(ValueError, match="Invalid feed fields"):
            update_feed(feed.id, nonexistent_field="value")

    def test_update_nonexistent_raises(self):
        with pytest.raises(ValueError, match="No feed"):
            update_feed(999, title="X")

    def test_update_etag_and_last_modified(self):
        feed = add_feed("https://example.com/feed.xml")
        updated = update_feed(
            feed.id,
            etag='"abc123"',
            last_modified="Thu, 17 Apr 2026 00:00:00 GMT",
        )
        assert updated.etag == '"abc123"'
        assert updated.last_modified == "Thu, 17 Apr 2026 00:00:00 GMT"


class TestGetFeed:
    def test_get_existing(self):
        feed = add_feed("https://example.com/feed.xml", title="Test")
        fetched = get_feed(feed.id)
        assert fetched.title == "Test"

    def test_get_nonexistent_raises(self):
        with pytest.raises(ValueError, match="No feed"):
            get_feed(999)
