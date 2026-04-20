"""Tests for Phase 2 — RSS discovery and dedup (discover.py)."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from wilted.db import Feed, Item
from wilted.discover import (
    _dedup_hash,
    _entry_enclosure,
    _entry_guid,
    _entry_link,
    _is_duplicate,
    _normalize_text,
    _process_entry,
    run_discover,
)
from wilted.feeds import add_feed

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_parsed_entry(**kwargs):
    """Create a mock feedparser entry dict."""
    defaults = {
        "title": "Test Article",
        "id": "guid-123",
        "link": "https://example.com/article-1",
        "published_parsed": None,
        "author": "Test Author",
        "summary": "Article summary text for testing.",
        "enclosures": [],
        "links": [],
        "content": [],
    }
    defaults.update(kwargs)
    return defaults


def _make_feed_result(entries=None, status=200, etag=None, modified=None):
    """Create a mock feedparser.parse() result."""
    result = MagicMock()
    result.status = status
    result.entries = entries or []
    result.etag = etag
    result.modified = modified
    result.feed = MagicMock()
    result.feed.title = "Test Feed"
    return result


# ---------------------------------------------------------------------------
# Normalization and hashing
# ---------------------------------------------------------------------------


class TestNormalizeText:
    def test_basic(self):
        assert _normalize_text("Hello World") == "hello world"

    def test_nfkd_decomposition(self):
        # fi ligature should decompose
        assert "fi" in _normalize_text("\ufb01")


class TestDedupHash:
    def test_same_input_same_hash(self):
        h1 = _dedup_hash("Title", "2026-04-17T00:00", "https://ex.com")
        h2 = _dedup_hash("Title", "2026-04-17T00:00", "https://ex.com")
        assert h1 == h2

    def test_different_title_different_hash(self):
        h1 = _dedup_hash("Title A", "2026-04-17T00:00", "https://ex.com")
        h2 = _dedup_hash("Title B", "2026-04-17T00:00", "https://ex.com")
        assert h1 != h2

    def test_none_pubdate_handled(self):
        h = _dedup_hash("Title", None, "https://ex.com")
        assert isinstance(h, str) and len(h) == 64


# ---------------------------------------------------------------------------
# Entry extractors
# ---------------------------------------------------------------------------


class TestEntryGuid:
    def test_extracts_id(self):
        entry = _make_parsed_entry(id="my-guid")
        assert _entry_guid(entry) == "my-guid"

    def test_none_when_missing(self):
        entry = _make_parsed_entry()
        del entry["id"]
        assert _entry_guid(entry) is None


class TestEntryLink:
    def test_extracts_link(self):
        entry = _make_parsed_entry(link="https://example.com")
        assert _entry_link(entry) == "https://example.com"


class TestEntryEnclosure:
    def test_audio_enclosure(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/ep.mp3", "type": "audio/mpeg"}])
        url, enc_type = _entry_enclosure(entry)
        assert url == "https://ex.com/ep.mp3"
        assert enc_type == "audio/mpeg"

    def test_no_enclosure(self):
        entry = _make_parsed_entry(enclosures=[])
        url, enc_type = _entry_enclosure(entry)
        assert url is None

    def test_non_audio_enclosure_skipped(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/img.jpg", "type": "image/jpeg"}])
        url, _ = _entry_enclosure(entry)
        assert url is None

    def test_mp3_extension_fallback(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/file.mp3", "type": ""}])
        url, _ = _entry_enclosure(entry)
        assert url == "https://ex.com/file.mp3"


# ---------------------------------------------------------------------------
# Dedup
# ---------------------------------------------------------------------------


class TestIsDuplicate:
    def test_not_duplicate_when_empty(self):
        feed = add_feed("https://ex.com/feed.xml")
        assert not _is_duplicate(feed, "new-guid", "https://new.com", "newhash")

    def test_duplicate_by_guid(self):
        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="dup-guid",
            title="Existing",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
        )
        assert _is_duplicate(feed, "dup-guid", None, "somehash")

    def test_duplicate_by_url(self):
        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="other-guid",
            title="Existing",
            canonical_url="https://ex.com/article",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
        )
        assert _is_duplicate(feed, "new-guid", "https://ex.com/article", "somehash")

    def test_duplicate_by_content_hash(self):
        import json

        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="other-guid",
            title="Existing",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
            metadata=json.dumps({"content_hash": "matchhash"}),
        )
        assert _is_duplicate(feed, "new-guid", None, "matchhash")


# ---------------------------------------------------------------------------
# Process entry — article
# ---------------------------------------------------------------------------


class TestProcessEntryArticle:
    @patch("wilted.discover._fetch_article_text")
    def test_new_article_creates_item(self, mock_fetch):
        mock_fetch.return_value = ("Article body text here.", "Fetched Title")

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(
            title="RSS Title",
            id="guid-1",
            link="https://ex.com/article-1",
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "guid-1").first()
        assert item is not None
        assert item.title == "Fetched Title"
        assert item.status == "fetched"
        assert item.item_type == "article"
        assert item.word_count == 4
        assert item.transcript_file is not None

    @patch("wilted.discover._fetch_article_text")
    def test_duplicate_skipped(self, mock_fetch):
        mock_fetch.return_value = ("Body.", "Title")

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(id="guid-dup", link="https://ex.com/dup")

        stats = {"new": 0, "skipped": 0, "errors": 0}
        _process_entry(feed, entry, stats)
        assert stats["new"] == 1

        # Process same entry again
        stats2 = {"new": 0, "skipped": 0, "errors": 0}
        _process_entry(feed, entry, stats2)
        assert stats2["skipped"] == 1
        assert stats2["new"] == 0

    @patch("wilted.discover._fetch_article_text")
    def test_falls_back_to_rss_summary(self, mock_fetch):
        mock_fetch.return_value = (None, None)

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(
            id="guid-summary",
            summary="This is the RSS summary content.",
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "guid-summary").first()
        assert item is not None


# ---------------------------------------------------------------------------
# Process entry — podcast
# ---------------------------------------------------------------------------


class TestProcessEntryPodcast:
    def test_new_podcast_episode(self):
        feed = add_feed("https://ex.com/podcast.xml", feed_type="podcast")
        entry = _make_parsed_entry(
            id="ep-1",
            title="Episode 1: Intro",
            enclosures=[{"href": "https://ex.com/ep1.mp3", "type": "audio/mpeg"}],
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "ep-1").first()
        assert item is not None
        assert item.item_type == "podcast_episode"
        assert item.enclosure_url == "https://ex.com/ep1.mp3"
        assert item.status == "fetched"

    def test_podcast_without_enclosure_skipped(self):
        feed = add_feed("https://ex.com/podcast.xml", feed_type="podcast")
        entry = _make_parsed_entry(id="ep-noaudio", enclosures=[])
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["skipped"] == 1
        assert stats["new"] == 0


# ---------------------------------------------------------------------------
# run_discover — integration
# ---------------------------------------------------------------------------


class TestRunDiscover:
    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_polls_enabled_feeds(self, mock_fetch, mock_parse):
        mock_fetch.return_value = ("Article text.", "Title")
        mock_parse.return_value = _make_feed_result(
            entries=[_make_parsed_entry(id="g1")],
            etag='"new-etag"',
        )

        add_feed("https://ex.com/feed.xml", feed_type="article")
        stats = run_discover()

        assert stats["feeds_polled"] == 1
        assert stats["discovered"] == 1
        assert stats["errors"] == 0
        mock_parse.assert_called_once()

    @patch("wilted.discover.feedparser.parse")
    def test_304_not_modified(self, mock_parse):
        mock_parse.return_value = _make_feed_result(status=304)
        add_feed("https://ex.com/feed.xml")

        stats = run_discover()
        assert stats["discovered"] == 0

    @patch("wilted.discover.feedparser.parse")
    def test_http_error_counted(self, mock_parse):
        mock_parse.return_value = _make_feed_result(status=403)
        add_feed("https://ex.com/feed.xml")

        stats = run_discover()
        assert stats["errors"] == 1

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_partial_failure_continues(self, mock_fetch, mock_parse):
        """One feed failing doesn't stop other feeds."""
        mock_fetch.return_value = ("Text.", "Title")

        add_feed("https://good.com/feed.xml", title="Good")
        add_feed("https://bad.com/feed.xml", title="Bad")

        def side_effect(url, **kwargs):
            if "bad" in url:
                return _make_feed_result(status=500)
            return _make_feed_result(
                entries=[_make_parsed_entry(id="good-item")],
            )

        mock_parse.side_effect = side_effect

        stats = run_discover()
        assert stats["feeds_polled"] == 2
        assert stats["discovered"] == 1
        assert stats["errors"] == 1

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_etag_stored_and_sent(self, mock_fetch, mock_parse):
        mock_fetch.return_value = ("Text.", "Title")
        mock_parse.return_value = _make_feed_result(
            entries=[_make_parsed_entry(id="first")],
            etag='"etag-value"',
        )

        feed = add_feed("https://ex.com/feed.xml")
        run_discover()

        # Verify etag was stored
        updated_feed = Feed.get_by_id(feed.id)
        assert updated_feed.etag == '"etag-value"'

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_feed_title_auto_updated(self, mock_fetch, mock_parse):
        """Feed title updates from RSS if it was set to the URL."""
        mock_fetch.return_value = ("Text.", "Title")
        result = _make_feed_result(
            entries=[_make_parsed_entry(id="item1")],
        )
        result.feed.title = "Real Feed Name"
        mock_parse.return_value = result

        # Feed created with URL as title
        feed = add_feed("https://ex.com/feed.xml")
        assert feed.title == "https://ex.com/feed.xml"

        run_discover()

        updated = Feed.get_by_id(feed.id)
        assert updated.title == "Real Feed Name"
