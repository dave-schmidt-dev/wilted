"""Tests for Phase 2 — Feed CRUD operations (feeds.py)."""

from __future__ import annotations

import pytest

from wilted.db import Feed
from wilted.feed_refs import FeedReferenceError, resolve_enclosure_url, resolve_feed_url
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

    def test_add_bws_reference(self):
        feed = add_feed("bws:WILTED_FEED_PRIVATE", feed_type="podcast")
        assert feed.feed_url == "bws:WILTED_FEED_PRIVATE"

    def test_bws_reference_requires_podcast_type(self):
        with pytest.raises(ValueError, match="only for podcast"):
            add_feed("bws:WILTED_FEED_PRIVATE")

    @pytest.mark.parametrize("value", ["ftp://example.com/feed.xml", "bws:lowercase", "not-a-url"])
    def test_rejects_invalid_feed_reference(self, value):
        with pytest.raises(FeedReferenceError, match="http\\(s\\)"):
            add_feed(value)

    def test_rejects_feed_url_with_userinfo(self):
        with pytest.raises(FeedReferenceError):
            add_feed("https://username:password@example.com/feed.xml")


class TestListFeeds:
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

    def test_bws_reference_updates_use_combined_feed_state(self):
        podcast = add_feed("bws:WILTED_FEED_PRIVATE", feed_type="podcast")
        with pytest.raises(ValueError, match="only for podcast"):
            update_feed(podcast.id, feed_type="article")

        article = add_feed("https://example.com/article.xml", feed_type="article")
        with pytest.raises(ValueError, match="only for podcast"):
            update_feed(article.id, feed_url="bws:WILTED_FEED_OTHER")


class TestFeedReferences:
    def test_resolves_bws_reference_from_environment(self, monkeypatch):
        monkeypatch.setenv("WILTED_FEED_PRIVATE", "https://private.example/feed.xml")
        assert resolve_feed_url("bws:WILTED_FEED_PRIVATE") == "https://private.example/feed.xml"

    def test_invalid_resolved_bws_value_never_exposes_value(self, monkeypatch):
        private_value = "not-a-public-url-with-private-material"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", private_value)
        with pytest.raises(FeedReferenceError) as exc_info:
            resolve_feed_url("bws:WILTED_FEED_PRIVATE")
        assert private_value not in str(exc_info.value)

    def test_enclosure_reference_re_resolves_without_persisting_url(self, monkeypatch):
        from wilted.feed_refs import make_bws_enclosure_reference

        private_url = "https://private.example/credential-material.mp3"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", "https://private.example/feed.xml")
        private_guid = "episode-guid-with-private-material"
        reference = make_bws_enclosure_reference("bws:WILTED_FEED_PRIVATE", private_guid)
        entry = {"id": private_guid, "enclosures": [{"href": private_url, "type": "audio/mpeg"}]}
        parsed = type("Parsed", (), {"entries": [entry]})
        monkeypatch.setattr("wilted.feed_refs.feedparser.parse", lambda _: parsed)

        assert private_url not in reference
        assert private_guid not in reference
        assert resolve_enclosure_url(reference, "bws:WILTED_FEED_PRIVATE") == private_url

    def test_enclosure_refresh_exception_drops_secret_bearing_cause(self, monkeypatch):
        from wilted.feed_refs import make_bws_enclosure_reference

        private_url = "https://private.example/feed.xml?credential=hidden"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", private_url)
        reference = make_bws_enclosure_reference("bws:WILTED_FEED_PRIVATE", "episode-guid")

        def fail_parse(_url):
            raise RuntimeError(private_url)

        monkeypatch.setattr("wilted.feed_refs.feedparser.parse", fail_parse)
        with pytest.raises(FeedReferenceError) as exc_info:
            resolve_enclosure_url(reference, "bws:WILTED_FEED_PRIVATE")

        assert private_url not in str(exc_info.value)
        assert exc_info.value.__cause__ is None


class TestGetFeed:
    def test_get_existing(self):
        feed = add_feed("https://example.com/feed.xml", title="Test")
        fetched = get_feed(feed.id)
        assert fetched.title == "Test"

    def test_get_nonexistent_raises(self):
        with pytest.raises(ValueError, match="No feed"):
            get_feed(999)
